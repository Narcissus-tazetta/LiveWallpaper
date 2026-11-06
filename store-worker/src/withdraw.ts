import type { Env } from "./env";
import { errorResponse, jsonResponse } from "./http";
import { checkRateLimit } from "./rate-limit";
import { deleteEntryObjects } from "./storage";
import { hashToken } from "./tokens";

interface WithdrawRequest {
	token?: string;
}

/// 投稿者本人による自己サービスの取り下げ。/submitのレスポンスで一度だけ渡した
/// 秘密トークンをこの端末がローカルに持っている前提で、ハッシュが一致した場合のみ
/// 実行する(=idを知っているだけでは取り下げられない。/entries/:id/statusとは
/// 異なりidは公開情報同然なので、こちらは真の秘密であるトークンをゲートにする)。
/// 審査状態(requested/published/rejected)を問わず、いつでも取り下げ可能。
export async function handleWithdraw(request: Request, env: Env, id: string): Promise<Response> {
	if (!(await checkRateLimit(env, "withdraw", request))) {
		return errorResponse("too many requests", 429);
	}

	let body: WithdrawRequest;
	try {
		body = await request.json();
	} catch {
		return errorResponse("invalid JSON body");
	}
	if (!body.token) {
		return errorResponse("missing token");
	}

	const tokenHash = await hashToken(body.token);
	const row = await env.STORE_DB.prepare(
		`SELECT object_key, thumbnail_key FROM store_entries
		 WHERE id = ? AND withdraw_token_hash IS NOT NULL AND withdraw_token_hash = ?`,
	)
		.bind(id, tokenHash)
		.first<{ object_key: string; thumbnail_key: string | null }>();
	if (!row) {
		return errorResponse("entry not found or invalid token", 404);
	}

	// 認証済みの行を先に非公開化し、R2削除失敗時にも同じトークンで再試行可能にする。
	await env.STORE_DB.prepare("UPDATE store_entries SET status = 'deletion_pending' WHERE id = ?").bind(id).run();
	await deleteEntryObjects(env, row.object_key, row.thumbnail_key);
	await env.STORE_DB.batch([
		env.STORE_DB.prepare("DELETE FROM store_review_tokens WHERE entry_id = ?").bind(id),
		env.STORE_DB.prepare("DELETE FROM store_entries WHERE id = ?").bind(id),
	]);

	return jsonResponse({ ok: true });
}
