import { AwsClient } from "aws4fetch";

export interface Env {
	STORE_BUCKET: R2Bucket;
	STORE_DB: D1Database;
	STORE_RATE_LIMITER: RateLimit;
	R2_ACCOUNT_ID: string;
	R2_BUCKET_NAME: string;
	R2_ACCESS_KEY_ID: string;
	R2_SECRET_ACCESS_KEY: string;
}

const MAX_UPLOAD_BYTES = 500 * 1024 * 1024; // 500MB, per plan
const ALLOWED_CONTENT_TYPES = new Set(["application/octet-stream"]);
const PRESIGNED_URL_TTL_SECONDS = 900;
const REPORT_THRESHOLD = 3;

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

interface UploadUrlRequest {
	contentType?: string;
	sizeBytes?: number;
}

async function handleUploadUrl(request: Request, env: Env): Promise<Response> {
	if (!(await checkRateLimit(env, "upload-url", request))) {
		return errorResponse("too many requests", 429);
	}

	let body: UploadUrlRequest;
	try {
		body = await request.json();
	} catch {
		return errorResponse("invalid JSON body");
	}

	const { contentType, sizeBytes } = body;
	if (!contentType || !ALLOWED_CONTENT_TYPES.has(contentType)) {
		return errorResponse("unsupported contentType");
	}
	if (
		typeof sizeBytes !== "number" ||
		!Number.isFinite(sizeBytes) ||
		sizeBytes <= 0
	) {
		return errorResponse("invalid sizeBytes");
	}
	if (sizeBytes > MAX_UPLOAD_BYTES) {
		return errorResponse(
			`sizeBytes exceeds ${MAX_UPLOAD_BYTES} byte limit`,
			413,
		);
	}

	const id = crypto.randomUUID();
	const objectKey = `packages/${id}.lwpkg`;

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

	const createdAt = new Date().toISOString();
	await env.STORE_DB.prepare(
		`INSERT INTO store_entries
			(id, title, author, description, object_key, thumbnail_key, sha256, size_bytes,
			 duration_seconds, has_audio, license, created_at, status)
		 VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, 'published')`,
	)
		.bind(
			id,
			title,
			author,
			body.description ?? null,
			objectKey,
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
			duration_seconds, has_audio, license, created_at, download_count
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
			downloadURL: new URL(
				`/download/${r.id}`,
				new URL(request.url).origin,
			).toString(),
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

interface ReportRequest {
	entryId?: string;
	reason?: string;
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
		"SELECT report_count FROM store_entries WHERE id = ?",
	)
		.bind(entryId)
		.first<{ report_count: number }>();
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
	if (newCount >= REPORT_THRESHOLD) {
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

	return jsonResponse({ ok: true, reportCount: newCount });
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
		if (method === "POST" && pathname === "/report") {
			return handleReport(request, env);
		}

		return errorResponse("not found", 404);
	},
} satisfies ExportedHandler<Env>;
