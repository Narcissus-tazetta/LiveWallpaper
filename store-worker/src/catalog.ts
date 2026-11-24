import type { Env } from "./env";
import { errorResponse, jsonResponse } from "./http";

const POPULAR_SNAPSHOT_INTERVAL_MS = 5 * 60 * 1000;
const POPULAR_SNAPSHOT_MAX_AGE = 12;

function popularSnapshot() {
	return Math.floor(Date.now() / POPULAR_SNAPSHOT_INTERVAL_MS);
}

export async function expirePopularSnapshots(env: Env): Promise<void> {
	await env.STORE_DB.prepare("DELETE FROM store_popular_order WHERE snapshot < ?")
		.bind(popularSnapshot() - POPULAR_SNAPSHOT_MAX_AGE)
		.run();
}

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
		durationSeconds:
			r.duration_seconds !== null && r.duration_seconds > 0 && Number.isSafeInteger(Math.round(r.duration_seconds))
				? r.duration_seconds
				: null,
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
	if (url.searchParams.get("sort") === "popular") {
		return handlePopularCatalog(env, url.origin, limit, cursor, q);
	}

	const conditions = ["status = 'published'"];
	const bindings: unknown[] = [];
	if (q) {
		conditions.push("title LIKE ? ESCAPE '\\'");
		bindings.push(`%${escapeLikePattern(q)}%`);
	}

	// Multiple entries can share a timestamp.
	if (cursor) {
		const [createdAt, cursorID] = cursor.split("|");
		if (createdAt && cursorID) {
			conditions.push("(created_at < ? OR (created_at = ? AND id < ?))");
			bindings.push(createdAt, createdAt, cursorID);
		}
	}

	const query = `SELECT ${PUBLIC_ENTRY_COLUMNS}
		FROM store_entries WHERE ${conditions.join(" AND ")}
		ORDER BY created_at DESC, id DESC LIMIT ?`;
	bindings.push(limit + 1);

	const { results } = await env.STORE_DB.prepare(query)
		.bind(...bindings)
		.all<PublicEntryRow>();

	const hasMore = results.length > limit;
	const page = hasMore ? results.slice(0, limit) : results;
	const last = page.at(-1);
	const nextCursor = hasMore && last ? `${last.created_at}|${last.id}` : null;

	const origin = new URL(request.url).origin;
	const entries = page.map((row) => toPublicEntry(row, origin));

	return jsonResponse({ entries, nextCursor });
}

async function handlePopularCatalog(
	env: Env,
	origin: string,
	limit: number,
	cursor: string | null,
	query: string | null,
): Promise<Response> {
	const current = popularSnapshot();
	let snapshot = current;
	let position = 0;
	if (cursor) {
		const match = /^p\|(\d+)\|(\d+)$/.exec(cursor);
		if (!match) return errorResponse("popular catalog cursor expired", 410);
		snapshot = Number(match[1]);
		position = Number(match[2]);
		if (!Number.isSafeInteger(position) || snapshot > current || snapshot < current - POPULAR_SNAPSHOT_MAX_AGE) {
			return errorResponse("popular catalog cursor expired", 410);
		}
	} else {
		// Every page uses the same ordering even while downloads update the live counters.
		await env.STORE_DB.prepare(
			`INSERT INTO store_popular_order (snapshot, position, entry_id, ranked_downloads)
			 SELECT ?, ROW_NUMBER() OVER (ORDER BY download_count DESC, created_at DESC, id DESC),
			     id, download_count
			 FROM store_entries WHERE status = 'published'
			     AND NOT EXISTS (SELECT 1 FROM store_popular_order WHERE snapshot = ?)`,
		)
			.bind(snapshot, snapshot)
			.run();
	}

	// Check publication live so a withdrawn entry disappears even from an older ranking.
	const filter = query ? " AND title LIKE ? ESCAPE '\\'" : "";
	const { results } = await env.STORE_DB.prepare(
		`SELECT ${PUBLIC_ENTRY_COLUMNS}, position, ranked_downloads
		 FROM store_popular_order JOIN store_entries ON id = entry_id
		 WHERE snapshot = ? AND position > ? AND status = 'published'${filter}
		 ORDER BY position LIMIT ?`,
	)
		.bind(snapshot, position, ...(query ? [`%${escapeLikePattern(query)}%`] : []), limit + 1)
		.all<PublicEntryRow & { position: number; ranked_downloads: number }>();
	const page = results.slice(0, limit);
	const last = page.at(-1);
	const nextCursor = results.length > limit && last ? `p|${snapshot}|${last.position}` : null;
	const entries = page.map((row) => toPublicEntry({ ...row, download_count: row.ranked_downloads }, origin));
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
	const row = await env.STORE_DB.prepare(
		"SELECT thumbnail_key FROM store_entries WHERE id = ? AND status = 'published'",
	)
		.bind(id)
		.first<{ thumbnail_key: string | null }>();
	if (!row || !row.thumbnail_key) {
		return errorResponse("thumbnail not found", 404);
	}

	// The bytes can stay at the edge, but a cached response must still pass the publication check.
	const cache = caches.default;
	const cacheKey = new Request(request.url);
	let cached = await cache.match(cacheKey);
	if (!cached) {
		const object = await env.STORE_BUCKET.get(row.thumbnail_key);
		if (!object) {
			return errorResponse("thumbnail missing from storage", 404);
		}

		cached = new Response(object.body, {
			headers: {
				"content-type": "image/jpeg",
				"content-length": object.size.toString(),
				"cache-control": "public, max-age=604800, immutable",
			},
		});
		await cache.put(cacheKey, cached.clone());
	}
	const response = new Response(cached.body, cached);
	response.headers.set("cache-control", "no-cache");
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
