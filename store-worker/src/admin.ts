import { REVIEW_TOKEN_TTL_MS } from "./constants";
import { sendReviewRequestEmail } from "./email";
import type { Env } from "./env";
import { errorResponse, jsonResponse } from "./http";
import { requireAdmin } from "./admin-auth";
import { applyReviewDecision, uploadWindowOpenMessage, uploadWindowRemainingMs } from "./review-decision";
import { deleteEntryObjects, deleteEntryRecords } from "./storage";
import { generateRawToken, hashToken } from "./tokens";

/// 運営がADMIN_KEYを使って(投稿者の同意なく)削除する管理者専用エンドポイント。
/// 投稿者自身による自己サービスの取り下げは handleWithdraw
/// (DELETE /entries/:id/withdraw、投稿時に発行した秘密トークンが必須)が別途担う
/// — 誰でも削除できてしまう無認証の自己サービス削除は依然として設けていない。
/// D1の行とR2上の実体(動画/サムネイル)、および紐づく審査トークンを消す。
export async function handleAdminDelete(request: Request, env: Env, id: string): Promise<Response> {
	const denied = await requireAdmin(request, env);
	if (denied) {
		return denied;
	}

	const row = await env.STORE_DB.prepare("SELECT object_key, thumbnail_key FROM store_entries WHERE id = ?")
		.bind(id)
		.first<{ object_key: string; thumbnail_key: string | null }>();
	if (!row) {
		return errorResponse("entry not found", 404);
	}

	// 先に公開経路から隠し、R2削除失敗時は行とキーを残して再試行可能にする。
	await env.STORE_DB.prepare("UPDATE store_entries SET status = 'deletion_pending' WHERE id = ?").bind(id).run();
	await deleteEntryObjects(env, row.object_key, row.thumbnail_key);
	await deleteEntryRecords(env, id);

	return jsonResponse({ ok: true });
}

/// 通報メールはベストエフォート通知に過ぎず、送信失敗・迷惑メール振り分け等で
/// 見逃される可能性がある。通報自体はD1に確実に残るので、メールに依存しない
/// 確認手段として一覧APIを用意する。
export async function handleAdminReports(request: Request, env: Env): Promise<Response> {
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
export async function handleAdminEmailStatus(request: Request, env: Env, emailId: string): Promise<Response> {
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

/// 通報と同様、審査メールもベストエフォート通知に過ぎず見逃される可能性がある。
/// メールに依存しない確認手段として一覧APIを用意する。
export async function handleAdminRequests(request: Request, env: Env): Promise<Response> {
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

export async function handleAdminDecision(
	request: Request,
	env: Env,
	id: string,
	action: "approve" | "reject",
): Promise<Response> {
	const denied = await requireAdmin(request, env);
	if (denied) {
		return denied;
	}

	if (action === "approve") {
		const entry = await env.STORE_DB.prepare("SELECT created_at FROM store_entries WHERE id = ?")
			.bind(id)
			.first<{ created_at: string }>();
		const remaining = entry ? uploadWindowRemainingMs(entry.created_at) : 0;
		if (remaining > 0) {
			return errorResponse(uploadWindowOpenMessage(remaining), 409);
		}
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
export async function handleAdminResendReview(
	request: Request,
	env: Env,
	ctx: ExecutionContext,
	id: string,
): Promise<Response> {
	const denied = await requireAdmin(request, env);
	if (denied) {
		return denied;
	}

	const entry = await env.STORE_DB.prepare("SELECT id, title, author, status FROM store_entries WHERE id = ?")
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
			await env.STORE_DB.prepare("UPDATE store_review_tokens SET resend_email_id = ? WHERE id = ?")
				.bind(resendEmailId, tokenId)
				.run();
		}),
	);

	return jsonResponse({ ok: true, expiresAt });
}
