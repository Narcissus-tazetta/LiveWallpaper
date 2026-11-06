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
