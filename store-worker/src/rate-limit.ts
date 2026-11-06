import type { Env } from "./env";
import { clientIP } from "./http";

/// アップロードURL発行/通報エンドポイントの簡易レート制限。IPごとに
/// bucket(エンドポイント名)単位でカウントする。成功なら true。
export async function checkRateLimit(env: Env, bucket: string, request: Request): Promise<boolean> {
	const { success } = await env.STORE_RATE_LIMITER.limit({
		key: `${bucket}:${clientIP(request)}`,
	});
	return success;
}
