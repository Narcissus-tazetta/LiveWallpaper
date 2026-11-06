import type { Env } from "./env";
import { errorResponse, jsonResponse } from "./http";

/// LIKEのワイルドカード(%, _)とエスケープ文字自体をリテラル扱いさせる。
/// これが無いと検索語に含まれる%/_がユーザーの意図しないマッチ範囲を作ってしまう
/// (SQLインジェクションではなく、あくまでLIKEの意味論上の問題)。
function escapeLikePattern(s: string): string {
	return s.replace(/[\\%_]/g, (ch) => `\\${ch}`);
}

export interface PublicEntryRow {
	id: string;
	title: string;
	author: string;
	description: string | null;
	sha256: string;
	size_bytes: number;
	duration_seconds: number | null;
	has_audio: number | null;
	license: string | null;
	created_at: string;
	download_count: number;
	thumbnail_key: string | null;
}

const PUBLIC_ENTRY_COLUMNS = `id, title, author, description, sha256, size_bytes,
			duration_seconds, has_audio, license, created_at, download_count, thumbnail_key`;

export type PublicEntry = ReturnType<typeof toPublicEntry>;

function toPublicEntry(r: PublicEntryRow, origin: string) {
	return {
		id: r.id,
		title: r.title,
		author: r.author,
		description: r.description,
		sha256: r.sha256,
		sizeBytes: r.size_bytes,
		durationSeconds: r.duration_seconds,
		hasAudio: r.has_audio === null ? null : r.has_audio === 1,
		license: r.license,
		createdAt: r.created_at,
		downloadCount: r.download_count,
		downloadURL: new URL(`/download/${r.id}`, origin).toString(),
		thumbnailURL: r.thumbnail_key ? new URL(`/thumbnail/${r.id}`, origin).toString() : null,
	};
}

export async function findPublishedEntry(env: Env, id: string, origin: string): Promise<PublicEntry | null> {
	const row = await env.STORE_DB.prepare(
		`SELECT ${PUBLIC_ENTRY_COLUMNS} FROM store_entries WHERE id = ? AND status = 'published'`,
	)
		.bind(id)
		.first<PublicEntryRow>();
	return row ? toPublicEntry(row, origin) : null;
}

export async function handleEntry(request: Request, env: Env, id: string): Promise<Response> {
	const entry = await findPublishedEntry(env, id, new URL(request.url).origin);
	if (!entry) {
		return errorResponse("entry not found", 404);
	}
	const response = jsonResponse(entry);
	// Kept short because a withdrawn or rejected entry must disappear from shared links quickly.
	response.headers.set("cache-control", "public, max-age=60");
	return response;
}

export async function handleCatalog(request: Request, env: Env): Promise<Response> {
	const url = new URL(request.url);
	const limit = Math.min(Math.max(Number.parseInt(url.searchParams.get("limit") ?? "20", 10) || 20, 1), 50);
	const cursor = url.searchParams.get("cursor");
	const q = url.searchParams.get("q")?.trim() || null;
	const sort = url.searchParams.get("sort") === "popular" ? "popular" : "newest";

	const conditions = ["status = 'published'"];
	const bindings: unknown[] = [];
	if (q) {
		conditions.push("title LIKE ? ESCAPE '\\'");
		bindings.push(`%${escapeLikePattern(q)}%`);
	}

	// created_atは同一ミリ秒に複数行ができるため、idを最終タイブレーカーにする。
	let orderClause: string;
	if (sort === "popular") {
		orderClause = "download_count DESC, created_at DESC, id DESC";
		if (cursor) {
			const [rawCount, createdAt, cursorID] = cursor.split("|");
			const count = Number.parseInt(rawCount, 10);
			if (Number.isFinite(count) && createdAt && cursorID) {
				conditions.push(`(download_count < ? OR
					(download_count = ? AND created_at < ?) OR
					(download_count = ? AND created_at = ? AND id < ?))`);
				bindings.push(count, count, createdAt, count, createdAt, cursorID);
			}
		}
	} else {
		orderClause = "created_at DESC, id DESC";
		if (cursor) {
			const [createdAt, cursorID] = cursor.split("|");
			if (createdAt && cursorID) {
				conditions.push("(created_at < ? OR (created_at = ? AND id < ?))");
				bindings.push(createdAt, createdAt, cursorID);
			}
		}
	}

	const query = `SELECT ${PUBLIC_ENTRY_COLUMNS}
		FROM store_entries WHERE ${conditions.join(" AND ")}
		ORDER BY ${orderClause} LIMIT ?`;
	bindings.push(limit + 1);

	const { results } = await env.STORE_DB.prepare(query)
		.bind(...bindings)
		.all<PublicEntryRow>();

	const hasMore = results.length > limit;
	const page = hasMore ? results.slice(0, limit) : results;
	const nextCursor = hasMore
		? sort === "popular"
			? `${(page[page.length - 1] as { download_count: number }).download_count}|${
					(page[page.length - 1] as { created_at: string }).created_at
				}|${(page[page.length - 1] as { id: string }).id}`
			: `${(page[page.length - 1] as { created_at: string }).created_at}|${
					(page[page.length - 1] as { id: string }).id
				}`
		: null;

	const origin = new URL(request.url).origin;
	const entries = page.map((row) => toPublicEntry(row, origin));

	return jsonResponse({ entries, nextCursor });
}

export async function handleDownload(request: Request, env: Env, id: string): Promise<Response> {
	const row = await env.STORE_DB.prepare("SELECT object_key FROM store_entries WHERE id = ? AND status = 'published'")
		.bind(id)
		.first<{ object_key: string }>();
	if (!row) {
		return errorResponse("entry not found", 404);
	}

	const object = await env.STORE_BUCKET.get(row.object_key);
	if (!object) {
		return errorResponse("object missing from storage", 404);
	}

	await env.STORE_DB.prepare("UPDATE store_entries SET download_count = download_count + 1 WHERE id = ?")
		.bind(id)
		.run();

	return new Response(object.body, {
		headers: {
			"content-type": "application/octet-stream",
			"content-length": object.size.toString(),
		},
	});
}

export async function handleThumbnail(request: Request, env: Env, id: string): Promise<Response> {
	// サムネイルは投稿後不変(content-addressed)なので、エッジにキャッシュして
	// 人気エントリでも Worker 実行/R2 読み取りを繰り返さないようにする。
	const cache = caches.default;
	const cacheKey = new Request(request.url, request);
	const cached = await cache.match(cacheKey);
	if (cached) {
		return cached;
	}

	const row = await env.STORE_DB.prepare(
		"SELECT thumbnail_key FROM store_entries WHERE id = ? AND status = 'published'",
	)
		.bind(id)
		.first<{ thumbnail_key: string | null }>();
	if (!row || !row.thumbnail_key) {
		return errorResponse("thumbnail not found", 404);
	}

	const object = await env.STORE_BUCKET.get(row.thumbnail_key);
	if (!object) {
		return errorResponse("thumbnail missing from storage", 404);
	}

	const response = new Response(object.body, {
		headers: {
			"content-type": "image/jpeg",
			"content-length": object.size.toString(),
			"cache-control": "public, max-age=604800, immutable",
		},
	});
	await cache.put(cacheKey, response.clone());
	return response;
}

/// 投稿者が自分の投稿の審査状況(requested/published/rejected)を確認するための
/// 読み取り専用エンドポイント。/download・/thumbnail と同じ信頼モデルで、認証は
/// せずid(推測不可能なUUID)を知っていること自体をアクセス権とする。status=
/// 'published'に限定しないのが/catalogとの違い(投稿者自身は非公開状態も見たい)。
export async function handleEntryStatus(request: Request, env: Env, id: string): Promise<Response> {
	const row = await env.STORE_DB.prepare("SELECT id, title, author, status, created_at FROM store_entries WHERE id = ?")
		.bind(id)
		.first<{ id: string; title: string; author: string; status: string; created_at: string }>();
	if (!row) {
		return errorResponse("entry not found", 404);
	}
	return jsonResponse({
		id: row.id,
		title: row.title,
		author: row.author,
		status: row.status,
		createdAt: row.created_at,
	});
}
