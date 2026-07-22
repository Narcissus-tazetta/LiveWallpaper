import { AwsClient } from "aws4fetch";

export interface Env {
	STORE_BUCKET: R2Bucket;
	STORE_DB: D1Database;
	STORE_RATE_LIMITER: RateLimit;
	R2_ACCOUNT_ID: string;
	R2_BUCKET_NAME: string;
	R2_ACCESS_KEY_ID: string;
	R2_SECRET_ACCESS_KEY: string;
	RESEND_API_KEY: string;
	ADMIN_KEY: string;
}

const MAX_UPLOAD_BYTES = 500 * 1024 * 1024; // 500MB, per plan
const ALLOWED_CONTENT_TYPES = new Set(["application/octet-stream"]);
const MAX_THUMBNAIL_BYTES = 2 * 1024 * 1024; // 2MB, plenty above the ~15-40KB expected size
const ALLOWED_THUMBNAIL_CONTENT_TYPES = new Set(["image/jpeg"]);
const PRESIGNED_URL_TTL_SECONDS = 900;
const REPORT_THRESHOLD = 3;
const REPORT_NOTIFY_EMAIL = "ibaragiakira2007@gmail.com";

function jsonResponse(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { "content-type": "application/json" },
	});
}

function errorResponse(message: string, status = 400): Response {
	return jsonResponse({ error: message }, status);
}

function clientIP(request: Request): string {
	return request.headers.get("cf-connecting-ip") ?? "unknown";
}

/// アップロードURL発行/通報エンドポイントの簡易レート制限。IPごとに
/// bucket(エンドポイント名)単位でカウントする。成功なら true。
async function checkRateLimit(env: Env, bucket: string, request: Request): Promise<boolean> {
	const { success } = await env.STORE_RATE_LIMITER.limit({
		key: `${bucket}:${clientIP(request)}`,
	});
	return success;
}

/// ADMIN_KEY認証が必要な管理エンドポイント共通のガード。レート制限チェックと
/// 認証チェックの両方を必ずセットで行わせることで、片方だけ実装し忘れる
/// (例: 認証はあるがレート制限が無い)事故を防ぐ。問題なければnullを返す。
async function requireAdmin(request: Request, env: Env): Promise<Response | null> {
	if (!(await checkRateLimit(env, "admin", request))) {
		return errorResponse("too many requests", 429);
	}
	const key = request.headers.get("x-admin-key");
	if (!key || key !== env.ADMIN_KEY) {
		return errorResponse("unauthorized", 401);
	}
	return null;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface UploadUrlRequest {
	contentType?: string;
	sizeBytes?: number;
	kind?: string;
	relatedId?: string;
}

async function handleUploadUrl(request: Request, env: Env): Promise<Response> {
	// bodyのパースより前に汎用バケットでレート制限する。不正なJSONボディを
	// 連投された場合でもレート制限そのものをすり抜けられないようにするため
	// (kind別バケットの判定にはbodyのパースが必要なので、それとは別に一段目として)。
	if (!(await checkRateLimit(env, "upload-url-request", request))) {
		return errorResponse("too many requests", 429);
	}

	let body: UploadUrlRequest;
	try {
		body = await request.json();
	} catch {
		return errorResponse("invalid JSON body");
	}

	const { contentType, sizeBytes, kind, relatedId } = body;
	if (kind !== undefined && kind !== "package" && kind !== "thumbnail") {
		return errorResponse("unsupported kind");
	}
	const isThumbnail = kind === "thumbnail";

	// サムネイル分は動画投稿の upload-url レート制限枠を消費しないよう、
	// 独立したバケット名でカウントする(1回の投稿で両方を叩くため)。
	const rateLimitBucket = isThumbnail ? "upload-url-thumbnail" : "upload-url";
	if (!(await checkRateLimit(env, rateLimitBucket, request))) {
		return errorResponse("too many requests", 429);
	}

	const maxBytes = isThumbnail ? MAX_THUMBNAIL_BYTES : MAX_UPLOAD_BYTES;
	const allowedContentTypes = isThumbnail
		? ALLOWED_THUMBNAIL_CONTENT_TYPES
		: ALLOWED_CONTENT_TYPES;

	if (!contentType || !allowedContentTypes.has(contentType)) {
		return errorResponse("unsupported contentType");
	}
	if (
		typeof sizeBytes !== "number" ||
		!Number.isFinite(sizeBytes) ||
		sizeBytes <= 0
	) {
		return errorResponse("invalid sizeBytes");
	}
	if (sizeBytes > maxBytes) {
		return errorResponse(`sizeBytes exceeds ${maxBytes} byte limit`, 413);
	}

	let id: string;
	let objectKey: string;
	if (isThumbnail) {
		// サムネイルのidは動画パッケージ側で払い出された(推測不可能な)idをそのまま
		// 再利用させる。ここで新規に乱数idを発行してしまうと、/submit 側で
		// thumbnailKeyがどのパッケージ用に発行されたものか検証できず、任意の
		// thumbnails/<id>.jpg を他エントリに流用されてしまう(resolveThumbnailKey参照)。
		if (!relatedId || !UUID_RE.test(relatedId)) {
			return errorResponse("missing or invalid relatedId for thumbnail upload");
		}
		id = relatedId;
		objectKey = `thumbnails/${id}.jpg`;
	} else {
		id = crypto.randomUUID();
		objectKey = `packages/${id}.lwpkg`;
	}

	// The client PUTs the package bytes directly to R2 via this presigned URL,
	// bypassing the Worker entirely so the upload isn't subject to Cloudflare's
	// account-plan-based request body size limit on Worker routes (as low as
	// 100MB on Free/Pro, well under our MAX_UPLOAD_BYTES). R2's own single-PUT
	// limit is 5GiB, comfortably above MAX_UPLOAD_BYTES.
	const s3 = new AwsClient({
		accessKeyId: env.R2_ACCESS_KEY_ID,
		secretAccessKey: env.R2_SECRET_ACCESS_KEY,
		service: "s3",
		region: "auto",
	});
	const objectURL = new URL(
		`https://${env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${env.R2_BUCKET_NAME}/${objectKey}`,
	);
	objectURL.searchParams.set("X-Amz-Expires", String(PRESIGNED_URL_TTL_SECONDS));
	const signed = await s3.sign(new Request(objectURL, { method: "PUT" }), {
		aws: { signQuery: true },
	});

	return jsonResponse({
		id,
		objectKey,
		uploadURL: signed.url,
		expiresIn: PRESIGNED_URL_TTL_SECONDS,
	});
}

interface SubmitRequest {
	id?: string;
	title?: string;
	author?: string;
	sha256?: string;
	sizeBytes?: number;
	objectKey?: string;
	durationSeconds?: number;
	hasAudio?: boolean;
	license?: string;
	description?: string;
	thumbnailKey?: string;
	thumbnailSha256?: string;
	thumbnailSizeBytes?: number;
}

/// サムネイルはベストエフォート: 動画本体と違い、検証に失敗しても投稿全体は
/// 失敗させず、単に thumbnail_key を NULL のまま進める。
///
/// thumbnailKeyは、このsubmitと同じ動画パッケージ(objectKey)のidを使って
/// 発行されたもの(thumbnails/<packageId>.jpg)であることを必須で検証する。
/// これが無いと、他エントリ用に発行された(あるいは自分が過去に取得した無関係な)
/// thumbnails/<id>.jpg をそのまま流用されてしまう。
async function resolveThumbnailKey(
	env: Env,
	objectKey: string,
	body: SubmitRequest,
): Promise<string | null> {
	const { thumbnailKey, thumbnailSizeBytes } = body;
	if (!thumbnailKey) {
		return null;
	}
	const packageMatch = objectKey.match(/^packages\/([\w-]+)\.lwpkg$/);
	if (!packageMatch || thumbnailKey !== `thumbnails/${packageMatch[1]}.jpg`) {
		return null;
	}
	if (
		typeof thumbnailSizeBytes !== "number" ||
		!Number.isFinite(thumbnailSizeBytes) ||
		thumbnailSizeBytes <= 0
	) {
		return null;
	}
	const head = await env.STORE_BUCKET.head(thumbnailKey);
	if (!head || head.size !== thumbnailSizeBytes) {
		return null;
	}
	return thumbnailKey;
}

async function handleSubmit(request: Request, env: Env): Promise<Response> {
	let body: SubmitRequest;
	try {
		body = await request.json();
	} catch {
		return errorResponse("invalid JSON body");
	}

	const { id, title, author, sha256, sizeBytes, objectKey } = body;
	if (!id || !title || !author || !sha256 || !objectKey) {
		return errorResponse("missing required fields");
	}
	if (typeof sizeBytes !== "number" || sizeBytes <= 0) {
		return errorResponse("invalid sizeBytes");
	}

	const head = await env.STORE_BUCKET.head(objectKey);
	if (!head) {
		return errorResponse("object not found in storage", 404);
	}
	if (head.size !== sizeBytes) {
		await env.STORE_BUCKET.delete(objectKey);
		return errorResponse("size mismatch between submitted metadata and stored object", 409);
	}

	const thumbnailKey = await resolveThumbnailKey(env, objectKey, body);

	const createdAt = new Date().toISOString();
	await env.STORE_DB.prepare(
		`INSERT INTO store_entries
			(id, title, author, description, object_key, thumbnail_key, sha256, size_bytes,
			 duration_seconds, has_audio, license, created_at, status)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'published')`,
	)
		.bind(
			id,
			title,
			author,
			body.description ?? null,
			objectKey,
			thumbnailKey,
			sha256,
			sizeBytes,
			body.durationSeconds ?? null,
			body.hasAudio === undefined ? null : body.hasAudio ? 1 : 0,
			body.license ?? null,
			createdAt,
		)
		.run();

	return jsonResponse({
		ok: true,
		entry: { id, title, author, createdAt, status: "published" },
	});
}

async function handleCatalog(request: Request, env: Env): Promise<Response> {
	const url = new URL(request.url);
	const limit = Math.min(
		Math.max(Number.parseInt(url.searchParams.get("limit") ?? "20", 10) || 20, 1),
		50,
	);
	const cursor = url.searchParams.get("cursor");

	let query = `SELECT id, title, author, description, sha256, size_bytes,
			duration_seconds, has_audio, license, created_at, download_count, thumbnail_key
		FROM store_entries WHERE status = 'published'`;
	const bindings: unknown[] = [];
	if (cursor) {
		query += " AND created_at < ?";
		bindings.push(cursor);
	}
	query += " ORDER BY created_at DESC LIMIT ?";
	bindings.push(limit + 1);

	const { results } = await env.STORE_DB.prepare(query)
		.bind(...bindings)
		.all();

	const hasMore = results.length > limit;
	const page = hasMore ? results.slice(0, limit) : results;
	const nextCursor = hasMore
		? (page[page.length - 1] as { created_at: string }).created_at
		: null;

	const entries = page.map((row) => {
		const r = row as Record<string, unknown>;
		const origin = new URL(request.url).origin;
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
			thumbnailURL: r.thumbnail_key
				? new URL(`/thumbnail/${r.id}`, origin).toString()
				: null,
		};
	});

	return jsonResponse({ entries, nextCursor });
}

async function handleDownload(
	request: Request,
	env: Env,
	id: string,
): Promise<Response> {
	const row = await env.STORE_DB.prepare(
		"SELECT object_key FROM store_entries WHERE id = ? AND status = 'published'",
	)
		.bind(id)
		.first<{ object_key: string }>();
	if (!row) {
		return errorResponse("entry not found", 404);
	}

	const object = await env.STORE_BUCKET.get(row.object_key);
	if (!object) {
		return errorResponse("object missing from storage", 404);
	}

	await env.STORE_DB.prepare(
		"UPDATE store_entries SET download_count = download_count + 1 WHERE id = ?",
	)
		.bind(id)
		.run();

	return new Response(object.body, {
		headers: {
			"content-type": "application/octet-stream",
			"content-length": object.size.toString(),
		},
	});
}

async function handleThumbnail(
	request: Request,
	env: Env,
	id: string,
): Promise<Response> {
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

interface ReportRequest {
	entryId?: string;
	reason?: string;
}

/// 通報を確認できるダッシュボードが無いため、Resend経由で運営メールに通知する。
/// 送信に失敗しても通報処理自体は失敗させない(ベストエフォート)。
async function notifyReport(
	env: Env,
	entryId: string,
	title: string,
	reason: string | null,
	reportCount: number,
	hidden: boolean,
): Promise<void> {
	try {
		const res = await fetch("https://api.resend.com/emails", {
			method: "POST",
			headers: {
				"content-type": "application/json",
				authorization: `Bearer ${env.RESEND_API_KEY}`,
			},
			body: JSON.stringify({
				from: "LiveWallpaper Store <onboarding@resend.dev>",
				to: [REPORT_NOTIFY_EMAIL],
				subject: hidden
					? `[Store] 通報により非公開化: ${title}`
					: `[Store] 新しい通報: ${title}`,
				text: [
					`entryId: ${entryId}`,
					`title: ${title}`,
					`reason: ${reason ?? "(未記入)"}`,
					`reportCount: ${reportCount}`,
					`status: ${hidden ? "pending (非公開化済み)" : "published"}`,
				].join("\n"),
			}),
		});
		// Resendはエラー時も2xx以外のJSONを返すだけで例外を投げないため、
		// ステータスとボディを明示的にログしないと失敗が完全に見えなくなる。
		const bodyText = await res.text();
		if (!res.ok) {
			console.error(`notifyReport: Resend API returned ${res.status} for entry ${entryId}: ${bodyText}`);
		} else {
			console.log(`notifyReport: Resend accepted for entry ${entryId}: ${bodyText}`);
		}
	} catch (err) {
		// ネットワークエラー等。ベストエフォートなので通報処理自体は継続するが、
		// ログには残す(Cloudflareのログ/wrangler tailで確認できる)。
		console.error(`notifyReport: failed to reach Resend for entry ${entryId}:`, err);
	}
}

async function handleReport(request: Request, env: Env): Promise<Response> {
	if (!(await checkRateLimit(env, "report", request))) {
		return errorResponse("too many requests", 429);
	}

	let body: ReportRequest;
	try {
		body = await request.json();
	} catch {
		return errorResponse("invalid JSON body");
	}
	const { entryId, reason } = body;
	if (!entryId) {
		return errorResponse("missing entryId");
	}

	const entry = await env.STORE_DB.prepare(
		"SELECT title, report_count FROM store_entries WHERE id = ?",
	)
		.bind(entryId)
		.first<{ title: string; report_count: number }>();
	if (!entry) {
		return errorResponse("entry not found", 404);
	}

	const reporterIP = clientIP(request);
	const alreadyReported = await env.STORE_DB.prepare(
		"SELECT 1 FROM store_reports WHERE entry_id = ? AND reporter_ip = ?",
	)
		.bind(entryId, reporterIP)
		.first();
	if (alreadyReported) {
		// 同じ通報者からの重複通報は黙って現在の件数を返す(多重投票で閾値を
		// 越えさせられないようにする)。
		return jsonResponse({ ok: true, reportCount: entry.report_count });
	}

	await env.STORE_DB.prepare(
		"INSERT INTO store_reports (entry_id, reason, reporter_ip, reported_at) VALUES (?, ?, ?, ?)",
	)
		.bind(entryId, reason ?? null, reporterIP, new Date().toISOString())
		.run();

	const newCount = entry.report_count + 1;
	const hidden = newCount >= REPORT_THRESHOLD;
	if (hidden) {
		await env.STORE_DB.prepare(
			"UPDATE store_entries SET report_count = ?, status = 'pending' WHERE id = ?",
		)
			.bind(newCount, entryId)
			.run();
	} else {
		await env.STORE_DB.prepare(
			"UPDATE store_entries SET report_count = ? WHERE id = ?",
		)
			.bind(newCount, entryId)
			.run();
	}

	await notifyReport(env, entryId, entry.title, reason ?? null, newCount, hidden);

	return jsonResponse({ ok: true, reportCount: newCount });
}

/// 自己サービスの削除機能(誰でも削除できてしまう)は設けず、運営がADMIN_KEYを
/// 使って削除する管理者専用エンドポイント。D1の行とR2上の実体(動画/サムネイル)
/// を両方消す。
async function handleAdminDelete(
	request: Request,
	env: Env,
	id: string,
): Promise<Response> {
	const denied = await requireAdmin(request, env);
	if (denied) {
		return denied;
	}

	const row = await env.STORE_DB.prepare(
		"SELECT object_key, thumbnail_key FROM store_entries WHERE id = ?",
	)
		.bind(id)
		.first<{ object_key: string; thumbnail_key: string | null }>();
	if (!row) {
		return errorResponse("entry not found", 404);
	}

	await env.STORE_DB.prepare("DELETE FROM store_entries WHERE id = ?").bind(id).run();
	await env.STORE_BUCKET.delete(row.object_key);
	if (row.thumbnail_key) {
		await env.STORE_BUCKET.delete(row.thumbnail_key);
	}

	return jsonResponse({ ok: true });
}

/// 通報メールはベストエフォート通知に過ぎず、送信失敗・迷惑メール振り分け等で
/// 見逃される可能性がある。通報自体はD1に確実に残るので、メールに依存しない
/// 確認手段として一覧APIを用意する。
async function handleAdminReports(request: Request, env: Env): Promise<Response> {
	const denied = await requireAdmin(request, env);
	if (denied) {
		return denied;
	}

	const { results: entries } = await env.STORE_DB.prepare(
		`SELECT id, title, author, status, report_count, created_at
		 FROM store_entries WHERE report_count > 0
		 ORDER BY report_count DESC, created_at DESC`,
	).all();

	const { results: reports } = await env.STORE_DB.prepare(
		`SELECT entry_id, reason, reporter_ip, reported_at FROM store_reports
		 ORDER BY reported_at DESC LIMIT 200`,
	).all();

	const reportsByEntry = new Map<string, unknown[]>();
	for (const row of reports as Record<string, unknown>[]) {
		const entryId = row.entry_id as string;
		const list = reportsByEntry.get(entryId) ?? [];
		list.push({
			reason: row.reason,
			reporterIP: row.reporter_ip,
			reportedAt: row.reported_at,
		});
		reportsByEntry.set(entryId, list);
	}

	const result = (entries as Record<string, unknown>[]).map((e) => ({
		id: e.id,
		title: e.title,
		author: e.author,
		status: e.status,
		reportCount: e.report_count,
		createdAt: e.created_at,
		reports: reportsByEntry.get(e.id as string) ?? [],
	}));

	return jsonResponse({ entries: result });
}

/// 診断用: Resendが受理したメールの実際の配送状況(delivered/bounced/complained等)を
/// 確認する。Resend APIが2xxを返しても実配送を保証しないため、通報メールが届かない
/// 原因切り分けに使う一時的なエンドポイント。
async function handleAdminEmailStatus(
	request: Request,
	env: Env,
	emailId: string,
): Promise<Response> {
	const denied = await requireAdmin(request, env);
	if (denied) {
		return denied;
	}

	const res = await fetch(`https://api.resend.com/emails/${emailId}`, {
		headers: { authorization: `Bearer ${env.RESEND_API_KEY}` },
	});
	const body = await res.text();
	return new Response(body, {
		status: res.status,
		headers: { "content-type": "application/json" },
	});
}

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const url = new URL(request.url);
		const { pathname } = url;
		const method = request.method;

		if (method === "POST" && pathname === "/upload-url") {
			return handleUploadUrl(request, env);
		}
		if (method === "POST" && pathname === "/submit") {
			return handleSubmit(request, env);
		}
		if (method === "GET" && pathname === "/catalog") {
			return handleCatalog(request, env);
		}
		const downloadMatch = pathname.match(/^\/download\/([\w-]+)$/);
		if (method === "GET" && downloadMatch) {
			return handleDownload(request, env, downloadMatch[1]);
		}
		const thumbnailMatch = pathname.match(/^\/thumbnail\/([\w-]+)$/);
		if (method === "GET" && thumbnailMatch) {
			return handleThumbnail(request, env, thumbnailMatch[1]);
		}
		if (method === "POST" && pathname === "/report") {
			return handleReport(request, env);
		}
		const adminDeleteMatch = pathname.match(/^\/admin\/entries\/([\w-]+)$/);
		if (method === "DELETE" && adminDeleteMatch) {
			return handleAdminDelete(request, env, adminDeleteMatch[1]);
		}
		if (method === "GET" && pathname === "/admin/reports") {
			return handleAdminReports(request, env);
		}
		const emailStatusMatch = pathname.match(/^\/admin\/email-status\/([\w-]+)$/);
		if (method === "GET" && emailStatusMatch) {
			return handleAdminEmailStatus(request, env, emailStatusMatch[1]);
		}

		return errorResponse("not found", 404);
	},
} satisfies ExportedHandler<Env>;
