import type { Env } from "./env";
import { errorResponse } from "./http";
import { checkRateLimit } from "./rate-limit";

const MIN_ADMIN_KEY_LENGTH = 16;

/// ADMIN_KEY認証が必要な管理エンドポイント共通のガード。レート制限チェックと
/// 認証チェックの両方を必ずセットで行わせることで、片方だけ実装し忘れる
/// (例: 認証はあるがレート制限が無い)事故を防ぐ。問題なければnullを返す。
export async function requireAdmin(request: Request, env: Env): Promise<Response | null> {
	if (!(await checkRateLimit(env, "admin", request))) {
		return errorResponse("too many requests", 429);
	}
	// 短い/未設定のキーはブルートフォースに弱い。401だと正しいキーを送っても原因が
	// 分からないため、設定不備は500とログで区別する。
	if (typeof env.ADMIN_KEY !== "string" || env.ADMIN_KEY.length < MIN_ADMIN_KEY_LENGTH) {
		console.error(`ADMIN_KEY must be configured with at least ${MIN_ADMIN_KEY_LENGTH} characters`);
		return errorResponse("admin key is not configured", 500);
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
