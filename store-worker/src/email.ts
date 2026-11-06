import { ADMIN_NOTIFY_EMAIL, REVIEW_TOKEN_TTL_MS } from "./constants";
import type { Env } from "./env";
import { escapeHtml } from "./html";

/// 通報を確認できるダッシュボードが無いため、Resend経由で運営メールに通知する。
/// 送信に失敗しても通報処理自体は失敗させない(ベストエフォート)。
export async function notifyReport(
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
				subject: hidden ? `[Store] 通報により非公開化: ${title}` : `[Store] 新しい通報: ${title}`,
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
export async function sendReviewRequestEmail(
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
