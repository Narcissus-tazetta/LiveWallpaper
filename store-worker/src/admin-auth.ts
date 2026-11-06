import type { Env } from "./env";
import { errorResponse } from "./http";
import { checkRateLimit } from "./rate-limit";

/// ADMIN_KEY認証が必要な管理エンドポイント共通のガード。レート制限チェックと
/// 認証チェックの両方を必ずセットで行わせることで、片方だけ実装し忘れる
/// (例: 認証はあるがレート制限が無い)事故を防ぐ。問題なければnullを返す。
export async function requireAdmin(request: Request, env: Env): Promise<Response | null> {
	if (!(await checkRateLimit(env, "admin", request))) {
		return errorResponse("too many requests", 429);
	}
	const key = request.headers.get("x-admin-key");
	if (!key || !(await adminKeyMatches(key, env.ADMIN_KEY))) {
		return errorResponse("unauthorized", 401);
	}
	return null;
}

/// `!==` returns as soon as a character differs, which leaks how much of the key matched
/// through response timing. Hashing first gives timingSafeEqual the equal-length inputs it
/// requires without revealing the key's length.
async function adminKeyMatches(provided: string, expected: string): Promise<boolean> {
	const encoder = new TextEncoder();
	const [a, b] = await Promise.all([
		crypto.subtle.digest("SHA-256", encoder.encode(provided)),
		crypto.subtle.digest("SHA-256", encoder.encode(expected)),
	]);
	return crypto.subtle.timingSafeEqual(a, b);
}
