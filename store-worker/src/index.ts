import { AwsClient } from "aws4fetch";
import { unzipSync } from "fflate";

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
// .lwpkg はZIPなので審査用プレビューはWorker内でメモリ展開してから動画部分だけを
// 返す。ZIP本体(この値まで)と展開後の動画バッファ(ほぼ同サイズ、metadata/previews
// は無視できるほど小さい)が同時にメモリ上に載るため、ピークはこの値のおよそ2倍になる。
// Workers Isolateのメモリ上限(128MB)に対して十分な余裕(JS実行時オーバーヘッド分)を
// 残すため、2倍しても128MBを大きく下回るこの値を上限に据える(超える投稿はプレビュー
// 不可とし、/admin/review/:token/download での生ファイルダウンロードに倒す)。
const MAX_VIDEO_PREVIEW_BYTES = 48 * 1024 * 1024;
const REPORT_THRESHOLD = 3;
// 通報通知と審査依頼の両方の送信先(運営本人のメールアドレス)。
const ADMIN_NOTIFY_EMAIL = "ibaragiakira2007@gmail.com";
const REVIEW_TOKEN_TTL_MS = 48 * 60 * 60 * 1000; // 48時間

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

function base64UrlEncode(bytes: Uint8Array): string {
	let binary = "";
	for (const byte of bytes) {
		binary += String.fromCharCode(byte);
	}
	return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/// 審査用ワンタイムトークンの生トークンを生成する(256bit)。この文字列自体が
/// 認証情報になるため、DBにはハッシュのみ保存しメール本文にのみ埋め込む。
function generateRawToken(): string {
	return base64UrlEncode(crypto.getRandomValues(new Uint8Array(32)));
}

async function hashToken(raw: string): Promise<string> {
	const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(raw));
	return Array.from(new Uint8Array(digest))
		.map((b) => b.toString(16).padStart(2, "0"))
		.join("");
}

/// 審査ページ(HTML)に投稿者由来の文字列(タイトル/作者名など)を埋め込む前に
/// 必ず通す。投稿時点では未審査のため、stored XSSを防ぐ目的で必須。
function escapeHtml(s: string): string {
	return s
		.replace(/&/g, "&amp;")
		.replace(/</g, "&lt;")
		.replace(/>/g, "&gt;")
		.replace(/"/g, "&quot;")
		.replace(/'/g, "&#39;");
}

async function handleSubmit(
	request: Request,
	env: Env,
	ctx: ExecutionContext,
): Promise<Response> {
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
	const tokenId = crypto.randomUUID();
	const rawToken = generateRawToken();
	const tokenHash = await hashToken(rawToken);
	const expiresAt = new Date(Date.now() + REVIEW_TOKEN_TTL_MS).toISOString();

	// エントリ作成と初回審査トークンの発行を1つのバッチ(D1の暗黙トランザクション)
	// にまとめ、片方だけ書き込まれる状態を避ける。
	await env.STORE_DB.batch([
		env.STORE_DB.prepare(
			`INSERT INTO store_entries
				(id, title, author, description, object_key, thumbnail_key, sha256, size_bytes,
				 duration_seconds, has_audio, license, created_at, status)
			 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'requested')`,
		).bind(
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
		),
		env.STORE_DB.prepare(
			`INSERT INTO store_review_tokens (id, entry_id, token_hash, created_at, expires_at)
			 VALUES (?, ?, ?, ?, ?)`,
		).bind(tokenId, id, tokenHash, createdAt, expiresAt),
	]);

	// 審査メール送信はレスポンスをブロックしない(Resendへの往復でアップロード完了の
	// レスポンスを遅らせないため)。ctx.waitUntilでWorkerの実行を継続させる。
	const origin = new URL(request.url).origin;
	ctx.waitUntil(
		sendReviewRequestEmail(env, origin, { id, title, author }, rawToken).then(
			async (resendEmailId) => {
				if (!resendEmailId) {
					return;
				}
				await env.STORE_DB.prepare(
					"UPDATE store_review_tokens SET resend_email_id = ? WHERE id = ?",
				)
					.bind(resendEmailId, tokenId)
					.run();
			},
		),
	);

	return jsonResponse({
		ok: true,
		entry: { id, title, author, createdAt, status: "requested" },
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
				to: [ADMIN_NOTIFY_EMAIL],
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

/// 新規投稿の審査依頼メール。Resend成功時はメールIDを返す(呼び出し側が
/// store_review_tokens.resend_email_id に保存し、/admin/email-status で追跡できるように
/// するため)。notifyReportと同様ベストエフォート — 送信失敗はsubmit自体を失敗させない。
async function sendReviewRequestEmail(
	env: Env,
	origin: string,
	entry: { id: string; title: string; author: string },
	rawToken: string,
): Promise<string | null> {
	const reviewURL = new URL(`/admin/review/${rawToken}`, origin).toString();
	const thumbnailURL = new URL(`/admin/review/${rawToken}/thumbnail`, origin).toString();
	const expiresInHours = Math.round(REVIEW_TOKEN_TTL_MS / (60 * 60 * 1000));

	try {
		const res = await fetch("https://api.resend.com/emails", {
			method: "POST",
			headers: {
				"content-type": "application/json",
				authorization: `Bearer ${env.RESEND_API_KEY}`,
			},
			body: JSON.stringify({
				from: "LiveWallpaper Store <onboarding@resend.dev>",
				to: [ADMIN_NOTIFY_EMAIL],
				subject: `[LiveWallpaper Store] 審査依頼: ${entry.title}`,
				html: [
					"<p>新しい投稿の審査依頼です。</p>",
					"<ul>",
					`<li>タイトル: ${escapeHtml(entry.title)}</li>`,
					`<li>作者: ${escapeHtml(entry.author)}</li>`,
					`<li>投稿ID: ${escapeHtml(entry.id)}</li>`,
					"</ul>",
					`<p><img src="${thumbnailURL}" alt="thumbnail" style="max-width:320px"></p>`,
					`<p><a href="${reviewURL}">審査画面を開く</a></p>`,
					`<p style="color:#666;font-size:0.9em">このリンクは${expiresInHours}時間で失効します。心当たりがない場合は対応しないでください。</p>`,
				].join(""),
				text: [
					"新しい投稿の審査依頼です。",
					`タイトル: ${entry.title}`,
					`作者: ${entry.author}`,
					`投稿ID: ${entry.id}`,
					`審査画面: ${reviewURL}`,
					`このリンクは${expiresInHours}時間で失効します。心当たりがない場合は対応しないでください。`,
				].join("\n"),
			}),
		});
		const bodyText = await res.text();
		if (!res.ok) {
			console.error(`sendReviewRequestEmail: Resend API returned ${res.status} for entry ${entry.id}: ${bodyText}`);
			return null;
		}
		console.log(`sendReviewRequestEmail: Resend accepted for entry ${entry.id}: ${bodyText}`);
		try {
			const parsed = JSON.parse(bodyText) as { id?: string };
			return parsed.id ?? null;
		} catch {
			return null;
		}
	} catch (err) {
		console.error(`sendReviewRequestEmail: failed to reach Resend for entry ${entry.id}:`, err);
		return null;
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

/// requested → published/rejected の状態遷移をこの1関数に集約する。トークン経由の
/// decide とADMIN_KEY直叩きのapprove/rejectの両方がここだけを呼ぶことで、二重承認や
/// 取りこぼしを防ぐ。WHERE status='requested' のガードにより、既に決定済みの
/// エントリを誤って上書きすることはない(meta.changesで判定)。
///
/// 決定が実際に反映された場合、この関数の中で副作用を集約して行う:
///   - このエントリに紐づく未消費の審査トークンを全て consumed 済みにし、action に
///     「実際の結果」を記録する。これにより decide(トークン経由)/approve・reject
///     (ADMIN_KEY直叩き)のどちらで決定されても /admin/requests の監査結果が一致する
///     (片方だけがaction列を更新する非対称を避ける)。
///   - rejected になった場合、R2上の動画/サムネイルを削除する(却下したのに実体が
///     オブジェクトキーを知る誰からも読めてしまう状態を残さないため)。
///
/// 呼び出し元(decide)がこのエントリの特定トークンを先に消費済み(consumed_at設定済み、
/// actionは未設定)にしていた場合でも、「action IS NULL」の条件でここから拾われて
/// 実際の結果が書き込まれる。これにより「トークンを消費したのに、他経路の決定と
/// 競合して実際には何も変わらなかった」ケースでも、記録されるactionは意図した
/// approve/rejectではなく実際のステータスになる(#4/#7 で指摘された不整合の解消)。
async function applyReviewDecision(
	env: Env,
	entryId: string,
	action: "approve" | "reject",
): Promise<{ changed: boolean; status: string | null }> {
	const requestedStatus = action === "approve" ? "published" : "rejected";
	const result = await env.STORE_DB.prepare(
		"UPDATE store_entries SET status = ? WHERE id = ? AND status = 'requested'",
	)
		.bind(requestedStatus, entryId)
		.run();
	const changed = result.meta.changes === 1;

	// changed===false の場合、実際のステータス(既に決定済みならそれ、entryIdが
	// 存在しなければnull)を読み直す。呼び出し元(handleAdminDecision)がこれで
	// 「既に決定済み」と「そもそも存在しない」を区別できるようにする。
	let status: string | null = requestedStatus;
	if (!changed) {
		const row = await env.STORE_DB.prepare("SELECT status FROM store_entries WHERE id = ?")
			.bind(entryId)
			.first<{ status: string }>();
		status = row?.status ?? null;
	}

	if (status === null) {
		// entryIdが存在しない(呼び出し元のバグ以外では起きないはず)。トークンや
		// R2への副作用は行わずそのまま返し、呼び出し元に404判定させる。
		return { changed, status };
	}

	const nowISO = new Date().toISOString();
	await env.STORE_DB.prepare(
		`UPDATE store_review_tokens SET consumed_at = COALESCE(consumed_at, ?), action = ?
		 WHERE entry_id = ? AND (consumed_at IS NULL OR action IS NULL)`,
	)
		.bind(nowISO, status, entryId)
		.run();

	if (changed && status === "rejected") {
		const row = await env.STORE_DB.prepare(
			"SELECT object_key, thumbnail_key FROM store_entries WHERE id = ?",
		)
			.bind(entryId)
			.first<{ object_key: string; thumbnail_key: string | null }>();
		if (row) {
			await env.STORE_BUCKET.delete(row.object_key);
			if (row.thumbnail_key) {
				await env.STORE_BUCKET.delete(row.thumbnail_key);
			}
		}
	}

	return { changed, status };
}

interface ReviewPageEntry {
	id: string;
	title: string;
	author: string;
	description: string | null;
	createdAt: string;
	status: string;
	sizeBytes: number;
}

/// 審査ページのHTML。テンプレートエンジンなしの手書きビルダーなので、投稿者由来の
/// 文字列は必ずescapeHtmlを通す(stored XSS対策)。表示は常にDB上の最新
/// entry.status を見る(トークン自身のconsumed_at/actionではなく) —
/// ADMIN_KEY直叩きで先に決定された場合でも、このページが古い状態を誤表示しないため。
function renderReviewPage(opts: {
	token: string;
	entry: ReviewPageEntry;
	tokenExpired: boolean;
}): string {
	const { token, entry, tokenExpired } = opts;
	const style = `body{font-family:-apple-system,sans-serif;max-width:560px;margin:2rem auto;padding:0 1rem;color:#1a1a1a}
img,video{max-width:100%;border-radius:8px;margin:1rem 0}
button{font-size:1rem;padding:0.6rem 1.2rem;border-radius:6px;border:none;cursor:pointer;margin-right:0.5rem}
.approve{background:#2e7d32;color:#fff}
.reject{background:#c62828;color:#fff}
.notice{color:#666;font-size:0.9em}`;

	let body: string;
	if (entry.status !== "requested") {
		body = `<p>審査済みです。現在のステータス: <strong>${escapeHtml(entry.status)}</strong></p>`;
	} else if (tokenExpired) {
		body = `<p class="notice">このリンクは失効しました。admin.sh または /admin/requests から直接操作してください。</p>`;
	} else {
		// サムネイルをposterにしておくと、動画本体の展開(ZIP解凍)を待たずに
		// まず静止画が出るので体感が速い。再生ボタンを押すと初めて/videoを叩く。
		const preview =
			entry.sizeBytes > MAX_VIDEO_PREVIEW_BYTES
				? `<img src="/admin/review/${token}/thumbnail" alt="thumbnail">
<p class="notice">動画が大きいためプレビューできません(サイズ上限${Math.round(MAX_VIDEO_PREVIEW_BYTES / (1024 * 1024))}MB)。
<a href="/admin/review/${token}/download">元ファイルをダウンロードして確認</a>してください。</p>`
				: `<video controls preload="metadata" poster="/admin/review/${token}/thumbnail">
	<source src="/admin/review/${token}/video" type="video/mp4">
</video>`;
		body = `${preview}
<form method="post" action="/admin/review/${token}/decide">
	<button class="approve" name="action" value="approve">承認する</button>
	<button class="reject" name="action" value="reject">却下する</button>
</form>`;
	}

	return `<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>審査: ${escapeHtml(entry.title)}</title><style>${style}</style></head><body>
<h1>${escapeHtml(entry.title)}</h1>
<p>作者: ${escapeHtml(entry.author)} / 投稿ID: ${escapeHtml(entry.id)} / 申請日時: ${escapeHtml(entry.createdAt)}</p>
${entry.description ? `<p>${escapeHtml(entry.description)}</p>` : ""}
${body}
</body></html>`;
}

async function handleAdminReviewPage(
	request: Request,
	env: Env,
	token: string,
): Promise<Response> {
	// ページ/サムネイル/動画/decideでバケットを分ける(#5): 動画の<video>要素だけで
	// 複数回のRangeリクエストが飛ぶため、同一バケットだと動画プレビューだけで
	// レビュー担当者自身のdecideクリックがレート制限に引っかかってしまう。
	if (!(await checkRateLimit(env, "review-page", request))) {
		return errorResponse("too many requests", 429);
	}

	const tokenHash = await hashToken(token);
	const row = await env.STORE_DB.prepare(
		`SELECT srt.expires_at as expires_at, se.id as id, se.title as title, se.author as author,
			se.description as description, se.created_at as created_at, se.status as status,
			se.size_bytes as size_bytes
		 FROM store_review_tokens srt JOIN store_entries se ON se.id = srt.entry_id
		 WHERE srt.token_hash = ?`,
	)
		.bind(tokenHash)
		.first<{
			expires_at: string;
			id: string;
			title: string;
			author: string;
			description: string | null;
			created_at: string;
			status: string;
			size_bytes: number;
		}>();
	if (!row) {
		return errorResponse("review link not found", 404);
	}

	const tokenExpired = new Date(row.expires_at).getTime() <= Date.now();
	const html = renderReviewPage({
		token,
		tokenExpired,
		entry: {
			id: row.id,
			title: row.title,
			author: row.author,
			description: row.description,
			createdAt: row.created_at,
			status: row.status,
			sizeBytes: row.size_bytes,
		},
	});
	return new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } });
}

/// レビューページ/メールに埋め込むサムネイル画像。トークンの有効期限のみで判定し
/// (consumed_atは問わない) — decide後の303リダイレクト先でもページ自身のサムネイルを
/// 表示できるようにするため。公開の /thumbnail/:id とは別に、未公開(requested)の
/// エントリでもトークンさえ有効なら見られるようにする専用ルート。
async function handleAdminReviewThumbnail(
	request: Request,
	env: Env,
	token: string,
): Promise<Response> {
	if (!(await checkRateLimit(env, "review-thumbnail", request))) {
		return errorResponse("too many requests", 429);
	}

	const tokenHash = await hashToken(token);
	const row = await env.STORE_DB.prepare(
		`SELECT srt.expires_at as expires_at, se.thumbnail_key as thumbnail_key
		 FROM store_review_tokens srt JOIN store_entries se ON se.id = srt.entry_id
		 WHERE srt.token_hash = ?`,
	)
		.bind(tokenHash)
		.first<{ expires_at: string; thumbnail_key: string | null }>();
	if (!row || !row.thumbnail_key || new Date(row.expires_at).getTime() <= Date.now()) {
		return errorResponse("thumbnail not found", 404);
	}

	const object = await env.STORE_BUCKET.get(row.thumbnail_key);
	if (!object) {
		return errorResponse("thumbnail missing from storage", 404);
	}
	return new Response(object.body, {
		headers: {
			"content-type": "image/jpeg",
			"content-length": object.size.toString(),
		},
	});
}

/// Rangeヘッダ("bytes=start-end"等)を解釈する。ブラウザの<video>は再生開始時や
/// シーク時に必ずRangeで問い合わせてくる(特にSafariはRange非対応のサーバーからは
/// 動画そのものを再生してくれない)ため、プレビューエンドポイントは対応必須。
/// 不正な形式やtotalLengthを超える範囲は無視して全体を返す(仕様上のフォールバック)。
function parseRangeHeader(
	rangeHeader: string | null,
	totalLength: number,
): { start: number; end: number } | null {
	if (!rangeHeader) {
		return null;
	}
	const match = rangeHeader.match(/^bytes=(\d*)-(\d*)$/);
	if (!match || (match[1] === "" && match[2] === "")) {
		return null;
	}
	let start: number;
	let end: number;
	if (match[1] === "") {
		// "bytes=-500" 形式: 末尾500バイト。
		const suffixLength = Number.parseInt(match[2], 10);
		start = Math.max(totalLength - suffixLength, 0);
		end = totalLength - 1;
	} else {
		start = Number.parseInt(match[1], 10);
		end = match[2] === "" ? totalLength - 1 : Number.parseInt(match[2], 10);
	}
	if (
		!Number.isFinite(start) ||
		!Number.isFinite(end) ||
		start < 0 ||
		end < start ||
		start >= totalLength
	) {
		return null;
	}
	return { start, end: Math.min(end, totalLength - 1) };
}

/// .lwpkg(ZIP)の中から動画本体(content/videos/<id>.mp4)だけを取り出して返す。
/// unzipSyncのfilterで動画エントリ以外(metadata.json/previews/*.png)の展開を
/// スキップさせ、Worker内メモリ使用量を動画本体分だけに抑える。
function extractVideoEntry(zipBytes: Uint8Array): Uint8Array | null {
	const videoPathRe = /^content\/videos\/[^/]+$/i;
	let matchedKey: string | null = null;
	const unzipped = unzipSync(zipBytes, {
		filter(file) {
			if (matchedKey) {
				// 単一動画パッケージ想定なので最初に見つかった1件だけを対象にする。
				return false;
			}
			if (videoPathRe.test(file.name)) {
				matchedKey = file.name;
				return true;
			}
			return false;
		},
	});
	if (!matchedKey) {
		return null;
	}
	return unzipped[matchedKey] ?? null;
}

/// R2から取得したZIPをまるごとメモリ展開するのはピークメモリも計算量も大きいため、
/// 一度展開した動画バイト列をエッジのCache APIに載せて使い回す(#3)。同じ動画に対する
/// <video>タグからの複数回のRangeリクエストが、毎回R2フェッチ+unzipをやり直さずに
/// 済むようにする(初回のみR2+unzipのコストを払う)。Range処理自体はここでは行わず
/// 常に「展開済みの動画全体」を返す(呼び出し元がparseRangeHeaderでスライスする)。
async function getCachedExtractedVideo(env: Env, objectKey: string): Promise<Uint8Array | null> {
	const cache = caches.default;
	// R2のオブジェクトキーをそのままキャッシュキーにする、実在しないhttps URLで
	// (Cache APIはRequest/URLをキーにする必要があるための便宜上のもの)。
	const cacheKey = new Request(`https://review-video-cache.internal/${encodeURIComponent(objectKey)}`);

	const cached = await cache.match(cacheKey);
	if (cached) {
		return new Uint8Array(await cached.arrayBuffer());
	}

	const object = await env.STORE_BUCKET.get(objectKey);
	if (!object) {
		return null;
	}
	const zipBytes = new Uint8Array(await object.arrayBuffer());
	const video = extractVideoEntry(zipBytes);
	if (!video) {
		return null;
	}

	await cache.put(
		cacheKey,
		new Response(video, {
			headers: {
				"content-type": "video/mp4",
				"content-length": video.byteLength.toString(),
				"cache-control": "private, max-age=3600",
			},
		}),
	);
	return video;
}

/// 審査ページに埋め込む動画プレビュー。サムネイルと同様トークンの有効期限のみで
/// 判定する(consumed_at後のdecideリダイレクト先でも表示できるようにするため)。
async function handleAdminReviewVideo(
	request: Request,
	env: Env,
	token: string,
): Promise<Response> {
	if (!(await checkRateLimit(env, "review-video", request))) {
		return errorResponse("too many requests", 429);
	}

	const tokenHash = await hashToken(token);
	const row = await env.STORE_DB.prepare(
		`SELECT srt.expires_at as expires_at, se.object_key as object_key, se.size_bytes as size_bytes
		 FROM store_review_tokens srt JOIN store_entries se ON se.id = srt.entry_id
		 WHERE srt.token_hash = ?`,
	)
		.bind(tokenHash)
		.first<{ expires_at: string; object_key: string; size_bytes: number }>();
	if (!row || new Date(row.expires_at).getTime() <= Date.now()) {
		return errorResponse("video not found", 404);
	}
	if (row.size_bytes > MAX_VIDEO_PREVIEW_BYTES) {
		return errorResponse(
			`package too large to preview inline; use /admin/review/${token}/download instead`,
			413,
		);
	}

	const video = await getCachedExtractedVideo(env, row.object_key);
	if (!video) {
		return errorResponse("no video found inside package", 404);
	}

	const range = parseRangeHeader(request.headers.get("range"), video.byteLength);
	if (range) {
		const chunk = video.subarray(range.start, range.end + 1);
		return new Response(chunk, {
			status: 206,
			headers: {
				"content-type": "video/mp4",
				"content-length": chunk.byteLength.toString(),
				"content-range": `bytes ${range.start}-${range.end}/${video.byteLength}`,
				"accept-ranges": "bytes",
			},
		});
	}

	return new Response(video, {
		headers: {
			"content-type": "video/mp4",
			"content-length": video.byteLength.toString(),
			"accept-ranges": "bytes",
		},
	});
}

/// MAX_VIDEO_PREVIEW_BYTESを超える(インラインプレビュー不可の)投稿を、審査担当者が
/// 承認/却下前に確認できるようにする手段(#6)。/download と違い status='published'
/// を要求せず、有効な審査トークンだけをゲートにする。ZIPの展開はせず、R2オブジェクトの
/// 生バイト列をそのままストリームするので、handleAdminReviewVideoのような
/// メモリ展開コストは発生しない。
async function handleAdminReviewDownload(
	request: Request,
	env: Env,
	token: string,
): Promise<Response> {
	if (!(await checkRateLimit(env, "review-download", request))) {
		return errorResponse("too many requests", 429);
	}

	const tokenHash = await hashToken(token);
	const row = await env.STORE_DB.prepare(
		`SELECT srt.expires_at as expires_at, se.object_key as object_key
		 FROM store_review_tokens srt JOIN store_entries se ON se.id = srt.entry_id
		 WHERE srt.token_hash = ?`,
	)
		.bind(tokenHash)
		.first<{ expires_at: string; object_key: string }>();
	if (!row || new Date(row.expires_at).getTime() <= Date.now()) {
		return errorResponse("package not found", 404);
	}

	const object = await env.STORE_BUCKET.get(row.object_key);
	if (!object) {
		return errorResponse("package missing from storage", 404);
	}
	return new Response(object.body, {
		headers: {
			"content-type": "application/octet-stream",
			"content-length": object.size.toString(),
		},
	});
}

async function handleAdminReviewDecide(
	request: Request,
	env: Env,
	token: string,
): Promise<Response> {
	if (!(await checkRateLimit(env, "review-decide", request))) {
		return errorResponse("too many requests", 429);
	}

	const form = await request.formData();
	const action = form.get("action");
	if (action !== "approve" && action !== "reject") {
		return errorResponse("invalid action");
	}

	const tokenHash = await hashToken(token);
	const nowISO = new Date().toISOString();

	// トークンの一回限り消費をこの1文のUPDATEで保証する。meta.changes===1なら
	// このリクエストが「勝った」ことが分かる(GETは消費しない。メールセキュリティ
	// スキャナの自動プリフェッチでリンクが死なないようにするため)。
	const consumeResult = await env.STORE_DB.prepare(
		`UPDATE store_review_tokens SET consumed_at = ?, action = ?
		 WHERE token_hash = ? AND consumed_at IS NULL AND expires_at > ?`,
	)
		.bind(nowISO, action, tokenHash, nowISO)
		.run();

	if (consumeResult.meta.changes !== 1) {
		const exists = await env.STORE_DB.prepare(
			"SELECT 1 FROM store_review_tokens WHERE token_hash = ?",
		)
			.bind(tokenHash)
			.first();
		return errorResponse(
			exists ? "review link already used or expired" : "review link not found",
			exists ? 410 : 404,
		);
	}

	const tokenRow = await env.STORE_DB.prepare(
		"SELECT entry_id FROM store_review_tokens WHERE token_hash = ?",
	)
		.bind(tokenHash)
		.first<{ entry_id: string }>();
	if (tokenRow) {
		await applyReviewDecision(env, tokenRow.entry_id, action);
	}

	return new Response(null, {
		status: 303,
		headers: { location: `/admin/review/${token}` },
	});
}

/// 通報と同様、審査メールもベストエフォート通知に過ぎず見逃される可能性がある。
/// メールに依存しない確認手段として一覧APIを用意する。
async function handleAdminRequests(request: Request, env: Env): Promise<Response> {
	const denied = await requireAdmin(request, env);
	if (denied) {
		return denied;
	}

	const { results: entries } = await env.STORE_DB.prepare(
		`SELECT id, title, author, created_at FROM store_entries
		 WHERE status = 'requested' ORDER BY created_at DESC`,
	).all();

	const { results: tokens } = await env.STORE_DB.prepare(
		`SELECT entry_id, created_at, expires_at, consumed_at, action, resend_email_id
		 FROM store_review_tokens ORDER BY created_at DESC`,
	).all();

	const latestTokenByEntry = new Map<string, Record<string, unknown>>();
	for (const row of tokens as Record<string, unknown>[]) {
		const entryId = row.entry_id as string;
		if (!latestTokenByEntry.has(entryId)) {
			latestTokenByEntry.set(entryId, row);
		}
	}

	const result = (entries as Record<string, unknown>[]).map((e) => {
		const t = latestTokenByEntry.get(e.id as string);
		return {
			id: e.id,
			title: e.title,
			author: e.author,
			createdAt: e.created_at,
			latestToken: t
				? {
						expiresAt: t.expires_at,
						consumedAt: t.consumed_at,
						action: t.action,
						resendEmailId: t.resend_email_id,
					}
				: null,
		};
	});

	return jsonResponse({ entries: result });
}

async function handleAdminDecision(
	request: Request,
	env: Env,
	id: string,
	action: "approve" | "reject",
): Promise<Response> {
	const denied = await requireAdmin(request, env);
	if (denied) {
		return denied;
	}

	const { changed, status } = await applyReviewDecision(env, id, action);
	if (!changed) {
		if (status === null) {
			return errorResponse("entry not found", 404);
		}
		return errorResponse(`entry is not in 'requested' state (current: ${status})`, 409);
	}

	return jsonResponse({ ok: true, status });
}

/// 未消費トークンを強制失効(expires_atのみ更新。consumed_atは「このトークン経由で
/// 決定が行われたか」を意味するため触らない)させ、新しいトークンを発行して
/// 審査メールを再送する。Resendのspam判定等でメールが届かなかった場合の手段。
async function handleAdminResendReview(
	request: Request,
	env: Env,
	ctx: ExecutionContext,
	id: string,
): Promise<Response> {
	const denied = await requireAdmin(request, env);
	if (denied) {
		return denied;
	}

	const entry = await env.STORE_DB.prepare(
		"SELECT id, title, author, status FROM store_entries WHERE id = ?",
	)
		.bind(id)
		.first<{ id: string; title: string; author: string; status: string }>();
	if (!entry) {
		return errorResponse("entry not found", 404);
	}
	if (entry.status !== "requested") {
		return errorResponse(`entry is not in 'requested' state (current: ${entry.status})`, 409);
	}

	const nowISO = new Date().toISOString();
	await env.STORE_DB.prepare(
		`UPDATE store_review_tokens SET expires_at = ?
		 WHERE entry_id = ? AND consumed_at IS NULL AND expires_at > ?`,
	)
		.bind(nowISO, id, nowISO)
		.run();

	const tokenId = crypto.randomUUID();
	const rawToken = generateRawToken();
	const tokenHash = await hashToken(rawToken);
	const expiresAt = new Date(Date.now() + REVIEW_TOKEN_TTL_MS).toISOString();
	await env.STORE_DB.prepare(
		`INSERT INTO store_review_tokens (id, entry_id, token_hash, created_at, expires_at)
		 VALUES (?, ?, ?, ?, ?)`,
	)
		.bind(tokenId, id, tokenHash, nowISO, expiresAt)
		.run();

	const origin = new URL(request.url).origin;
	ctx.waitUntil(
		sendReviewRequestEmail(env, origin, entry, rawToken).then(async (resendEmailId) => {
			if (!resendEmailId) {
				return;
			}
			await env.STORE_DB.prepare(
				"UPDATE store_review_tokens SET resend_email_id = ? WHERE id = ?",
			)
				.bind(resendEmailId, tokenId)
				.run();
		}),
	);

	return jsonResponse({ ok: true, expiresAt });
}

export default {
	async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
		const url = new URL(request.url);
		const { pathname } = url;
		const method = request.method;

		if (method === "POST" && pathname === "/upload-url") {
			return handleUploadUrl(request, env);
		}
		if (method === "POST" && pathname === "/submit") {
			return handleSubmit(request, env, ctx);
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
		if (method === "GET" && pathname === "/admin/requests") {
			return handleAdminRequests(request, env);
		}
		const adminApproveMatch = pathname.match(/^\/admin\/entries\/([\w-]+)\/approve$/);
		if (method === "POST" && adminApproveMatch) {
			return handleAdminDecision(request, env, adminApproveMatch[1], "approve");
		}
		const adminRejectMatch = pathname.match(/^\/admin\/entries\/([\w-]+)\/reject$/);
		if (method === "POST" && adminRejectMatch) {
			return handleAdminDecision(request, env, adminRejectMatch[1], "reject");
		}
		const adminResendReviewMatch = pathname.match(/^\/admin\/entries\/([\w-]+)\/resend-review$/);
		if (method === "POST" && adminResendReviewMatch) {
			return handleAdminResendReview(request, env, ctx, adminResendReviewMatch[1]);
		}
		const reviewDecideMatch = pathname.match(/^\/admin\/review\/([\w-]+)\/decide$/);
		if (method === "POST" && reviewDecideMatch) {
			return handleAdminReviewDecide(request, env, reviewDecideMatch[1]);
		}
		const reviewThumbnailMatch = pathname.match(/^\/admin\/review\/([\w-]+)\/thumbnail$/);
		if (method === "GET" && reviewThumbnailMatch) {
			return handleAdminReviewThumbnail(request, env, reviewThumbnailMatch[1]);
		}
		const reviewVideoMatch = pathname.match(/^\/admin\/review\/([\w-]+)\/video$/);
		if (method === "GET" && reviewVideoMatch) {
			return handleAdminReviewVideo(request, env, reviewVideoMatch[1]);
		}
		const reviewDownloadMatch = pathname.match(/^\/admin\/review\/([\w-]+)\/download$/);
		if (method === "GET" && reviewDownloadMatch) {
			return handleAdminReviewDownload(request, env, reviewDownloadMatch[1]);
		}
		const reviewPageMatch = pathname.match(/^\/admin\/review\/([\w-]+)$/);
		if (method === "GET" && reviewPageMatch) {
			return handleAdminReviewPage(request, env, reviewPageMatch[1]);
		}

		return errorResponse("not found", 404);
	},

	/// 審査依頼の全トークンが失効しても管理者が決定しなかった投稿を自動的に却下する
	/// (#2)。resend-reviewで新トークンを発行すると各トークンのexpires_atが更新される
	/// ため、この条件は実質「最後に発行された審査リンクが失効してから」を意味し、
	/// クライアント側の文言(48時間以内に承認されなかった場合は却下されたものとみなす)
	/// と一致する。wrangler.tomlの[triggers].cronsで定期実行される。
	async scheduled(_controller: ScheduledController, env: Env): Promise<void> {
		const nowISO = new Date().toISOString();
		const { results } = await env.STORE_DB.prepare(
			`SELECT se.id as id FROM store_entries se
			 WHERE se.status = 'requested'
			 AND NOT EXISTS (
				 SELECT 1 FROM store_review_tokens srt
				 WHERE srt.entry_id = se.id AND srt.expires_at > ?
			 )`,
		)
			.bind(nowISO)
			.all();

		await Promise.all(
			(results as { id: string }[]).map((row) => applyReviewDecision(env, row.id, "reject")),
		);
	},
} satisfies ExportedHandler<Env>;
