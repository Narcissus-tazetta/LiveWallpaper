import { AwsClient } from "aws4fetch";
import {
	ALLOWED_CONTENT_TYPES,
	ALLOWED_THUMBNAIL_CONTENT_TYPES,
	MAX_DESCRIPTION_LENGTH,
	MAX_LICENSE_LENGTH,
	MAX_THUMBNAIL_BYTES,
	MAX_UPLOAD_BYTES,
	PRESIGNED_URL_TTL_SECONDS,
	REVIEW_TOKEN_TTL_MS,
	UUID_RE,
} from "./constants";
import { sendReviewRequestEmail } from "./email";
import type { Env } from "./env";
import { errorResponse, isNonEmptyString, jsonResponse } from "./http";
import { checkRateLimit } from "./rate-limit";
import { generateRawToken, hashToken } from "./tokens";

interface UploadUrlRequest {
	contentType?: string;
	sizeBytes?: number;
	kind?: string;
	relatedId?: string;
}

export async function handleUploadUrl(request: Request, env: Env): Promise<Response> {
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
	const allowedContentTypes = isThumbnail ? ALLOWED_THUMBNAIL_CONTENT_TYPES : ALLOWED_CONTENT_TYPES;

	if (!contentType || !allowedContentTypes.has(contentType)) {
		return errorResponse("unsupported contentType");
	}
	if (typeof sizeBytes !== "number" || !Number.isFinite(sizeBytes) || sizeBytes <= 0) {
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
		// relatedIdは/submit未実行の新規パッケージのidであるはずで、その時点では
		// store_entriesに行が存在しない。既存の(公開済み含む)エントリのidが渡された
		// 場合は、そのエントリの生きているサムネイルオブジェクトを無認証で
		// 上書きされてしまうため拒否する。
		const existing = await env.STORE_DB.prepare("SELECT 1 FROM store_entries WHERE id = ?").bind(relatedId).first();
		if (existing) {
			return errorResponse("relatedId already belongs to an existing entry", 409);
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
	const objectURL = new URL(`https://${env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${env.R2_BUCKET_NAME}/${objectKey}`);
	objectURL.searchParams.set("X-Amz-Expires", String(PRESIGNED_URL_TTL_SECONDS));
	// content-length も署名対象に含め、検証済みの申告サイズを実際のPUTに拘束する。
	const signed = await s3.sign(
		new Request(objectURL, {
			method: "PUT",
			headers: { "content-length": String(sizeBytes) },
		}),
		{
			aws: { signQuery: true, allHeaders: true },
		},
	);

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
async function resolveThumbnailKey(env: Env, objectKey: string, body: SubmitRequest): Promise<string | null> {
	const { thumbnailKey, thumbnailSizeBytes } = body;
	if (!thumbnailKey) {
		return null;
	}
	const packageMatch = objectKey.match(/^packages\/([\w-]+)\.lwpkg$/);
	if (!packageMatch || thumbnailKey !== `thumbnails/${packageMatch[1]}.jpg`) {
		return null;
	}
	if (typeof thumbnailSizeBytes !== "number" || !Number.isFinite(thumbnailSizeBytes) || thumbnailSizeBytes <= 0) {
		return null;
	}
	const head = await env.STORE_BUCKET.head(thumbnailKey);
	if (!head || head.size !== thumbnailSizeBytes) {
		return null;
	}
	return thumbnailKey;
}

export async function handleSubmit(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
	if (!(await checkRateLimit(env, "submit", request))) {
		return errorResponse("too many requests", 429);
	}

	let body: SubmitRequest;
	try {
		body = await request.json();
	} catch {
		return errorResponse("invalid JSON body");
	}

	const { id, title, author, sha256, sizeBytes, objectKey } = body;
	if (
		!isNonEmptyString(id, 36) ||
		!isNonEmptyString(title, 200) ||
		!isNonEmptyString(author, 200) ||
		!isNonEmptyString(sha256, 64) ||
		!isNonEmptyString(objectKey, 128)
	) {
		return errorResponse("missing required fields");
	}
	if (/[\r\n]/.test(title) || /[\r\n]/.test(author)) {
		return errorResponse("newlines are not allowed in title or author");
	}
	if (typeof sizeBytes !== "number" || !Number.isSafeInteger(sizeBytes) || sizeBytes <= 0) {
		return errorResponse("invalid sizeBytes");
	}
	if (sizeBytes > MAX_UPLOAD_BYTES) {
		return errorResponse(`sizeBytes exceeds ${MAX_UPLOAD_BYTES} byte limit`, 413);
	}
	if (!/^[0-9a-f]{64}$/i.test(sha256)) {
		return errorResponse("invalid sha256");
	}
	if (
		body.description !== undefined &&
		body.description !== null &&
		(typeof body.description !== "string" || body.description.length > MAX_DESCRIPTION_LENGTH)
	) {
		return errorResponse(`description must be a string of at most ${MAX_DESCRIPTION_LENGTH} characters`);
	}
	if (
		body.license !== undefined &&
		body.license !== null &&
		(typeof body.license !== "string" || body.license.length > MAX_LICENSE_LENGTH || /[\r\n]/.test(body.license))
	) {
		return errorResponse(`license must be a single-line string of at most ${MAX_LICENSE_LENGTH} characters`);
	}
	if (
		body.durationSeconds !== undefined &&
		(typeof body.durationSeconds !== "number" || !Number.isFinite(body.durationSeconds) || body.durationSeconds <= 0)
	) {
		return errorResponse("invalid durationSeconds");
	}
	if (body.hasAudio !== undefined && typeof body.hasAudio !== "boolean") {
		return errorResponse("invalid hasAudio");
	}

	// store_entries.id はクライアント申告値をそのまま主キーに使うため、objectKey
	// (packages/<uuid>.lwpkg、/upload-url がサーバー側で発行した乱数)に埋め込まれた
	// idと一致することを必須で検証する。これが無いと、任意の文字列をidに指定されて
	// 既存エントリと主キー衝突させられたり(D1のUNIQUE制約違反で素の500になる)、
	// UUID形式ですらない値がそのまま主キーとして永続化されてしまう。
	const packageMatch = objectKey.match(/^packages\/([\w-]+)\.lwpkg$/);
	if (!packageMatch || !UUID_RE.test(packageMatch[1]) || id !== packageMatch[1]) {
		return errorResponse("id does not match objectKey");
	}
	const existing = await env.STORE_DB.prepare("SELECT 1 FROM store_entries WHERE id = ?").bind(id).first();
	if (existing) {
		return errorResponse("entry already exists", 409);
	}

	const head = await env.STORE_BUCKET.head(objectKey);
	if (!head) {
		return errorResponse("object not found in storage", 404);
	}
	if (head.size !== sizeBytes) {
		return errorResponse("size mismatch between submitted metadata and stored object", 409);
	}

	const thumbnailKey = await resolveThumbnailKey(env, objectKey, body);

	const createdAt = new Date().toISOString();
	const tokenId = crypto.randomUUID();
	const rawToken = generateRawToken();
	const tokenHash = await hashToken(rawToken);
	const expiresAt = new Date(Date.now() + REVIEW_TOKEN_TTL_MS).toISOString();

	// 投稿者本人が自己サービスで取り下げる(DELETE /entries/:id/withdraw)ための
	// 秘密トークン。審査トークンと同様、生の値はDBに残さずハッシュだけ保存し、
	// このレスポンスで一度だけ返す(サーバー側は二度と生の値を知らない)。
	const withdrawRawToken = generateRawToken();
	const withdrawTokenHash = await hashToken(withdrawRawToken);

	// エントリ作成と初回審査トークンの発行を1つのバッチ(D1の暗黙トランザクション)
	// にまとめ、片方だけ書き込まれる状態を避ける。
	try {
		await env.STORE_DB.batch([
			env.STORE_DB.prepare(
				`INSERT INTO store_entries
					(id, title, author, description, object_key, thumbnail_key, sha256, size_bytes,
					 duration_seconds, has_audio, license, created_at, status, withdraw_token_hash)
				 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'requested', ?)`,
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
				withdrawTokenHash,
			),
			env.STORE_DB.prepare(
				`INSERT INTO store_review_tokens (id, entry_id, token_hash, created_at, expires_at)
				 VALUES (?, ?, ?, ?, ?)`,
			).bind(tokenId, id, tokenHash, createdAt, expiresAt),
		]);
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		if (/UNIQUE constraint failed/i.test(message)) {
			return errorResponse("entry already exists", 409);
		}
		throw error;
	}

	// 審査メール送信はレスポンスをブロックしない(Resendへの往復でアップロード完了の
	// レスポンスを遅らせないため)。ctx.waitUntilでWorkerの実行を継続させる。
	const origin = new URL(request.url).origin;
	ctx.waitUntil(
		sendReviewRequestEmail(env, origin, { id, title, author }, rawToken).then(async (resendEmailId) => {
			if (!resendEmailId) {
				return;
			}
			await env.STORE_DB.prepare("UPDATE store_review_tokens SET resend_email_id = ? WHERE id = ?")
				.bind(resendEmailId, tokenId)
				.run();
		}),
	);

	return jsonResponse({
		ok: true,
		entry: { id, title, author, createdAt, status: "requested" },
		withdrawToken: withdrawRawToken,
	});
}
