import { MAX_PREVIEW_ARCHIVE_BYTES, MAX_VIDEO_PREVIEW_BYTES } from "./constants";
import type { Env } from "./env";
import { escapeHtml } from "./html";
import { errorResponse } from "./http";
import { checkRateLimit } from "./rate-limit";
import { applyReviewDecision } from "./review-decision";
import { getCachedExtractedVideo, parseRangeHeader } from "./review-video";
import { hashToken } from "./tokens";

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
function renderReviewPage(opts: { token: string; entry: ReviewPageEntry; tokenExpired: boolean }): string {
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

export async function handleAdminReviewPage(request: Request, env: Env, token: string): Promise<Response> {
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
export async function handleAdminReviewThumbnail(request: Request, env: Env, token: string): Promise<Response> {
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

/// 審査ページに埋め込む動画プレビュー。サムネイルと同様トークンの有効期限のみで
/// 判定する(consumed_at後のdecideリダイレクト先でも表示できるようにするため)。
export async function handleAdminReviewVideo(request: Request, env: Env, token: string): Promise<Response> {
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
	if (row.size_bytes > MAX_PREVIEW_ARCHIVE_BYTES) {
		return errorResponse(`package too large to preview inline; use /admin/review/${token}/download instead`, 413);
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
export async function handleAdminReviewDownload(request: Request, env: Env, token: string): Promise<Response> {
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

export async function handleAdminReviewDecide(request: Request, env: Env, token: string): Promise<Response> {
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
	const requestedStatus = action === "approve" ? "published" : "rejected";
	const [consumeResult] = await env.STORE_DB.batch([
		env.STORE_DB.prepare(
			`UPDATE store_review_tokens SET consumed_at = ?, action = ?
			 WHERE token_hash = ? AND consumed_at IS NULL AND expires_at > ?`,
		).bind(nowISO, action, tokenHash, nowISO),
		env.STORE_DB.prepare(
			`UPDATE store_entries SET status = ?
			 WHERE status = 'requested' AND id = (
				 SELECT entry_id FROM store_review_tokens
				 WHERE token_hash = ? AND consumed_at = ?
			 )`,
		).bind(requestedStatus, tokenHash, nowISO),
	]);

	if (consumeResult.meta.changes !== 1) {
		const existing = await env.STORE_DB.prepare("SELECT entry_id, action FROM store_review_tokens WHERE token_hash = ?")
			.bind(tokenHash)
			.first<{ entry_id: string; action: string | null }>();
		// 却下状態のR2削除だけが失敗した場合、消費済みリンクでも後始末を再試行する。
		if (existing?.action === "rejected" || existing?.action === "reject") {
			await applyReviewDecision(env, existing.entry_id, "reject");
			return new Response(null, {
				status: 303,
				headers: { location: `/admin/review/${token}` },
			});
		}
		return errorResponse(
			existing ? "review link already used or expired" : "review link not found",
			existing ? 410 : 404,
		);
	}

	const tokenRow = await env.STORE_DB.prepare("SELECT entry_id FROM store_review_tokens WHERE token_hash = ?")
		.bind(tokenHash)
		.first<{ entry_id: string }>();
	if (tokenRow) {
		// batchで状態は決定済み。共通関数は監査値の正規化と
		// rejected実体の再試行可能な削除を担当する。
		await applyReviewDecision(env, tokenRow.entry_id, action);
	}

	return new Response(null, {
		status: 303,
		headers: { location: `/admin/review/${token}` },
	});
}
