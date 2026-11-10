import type { Env } from "./env";

/// R2上の動画本体/サムネイル実体を削除する。handleAdminDelete・
/// applyReviewDecision(reject時)・handleWithdrawの3箇所から呼ばれる共通処理。
/// 既に削除済み(またはそもそも存在しない)キーに対するR2 delete は無害
/// (エラーにならない)なので、呼び出し側で存在チェックを二重に行う必要はない。
export async function deleteEntryObjects(env: Env, objectKey: string, thumbnailKey: string | null): Promise<void> {
	await env.STORE_BUCKET.delete(objectKey);
	if (thumbnailKey) {
		await env.STORE_BUCKET.delete(thumbnailKey);
	}
}

export async function deleteEntryRecords(env: Env, id: string): Promise<void> {
	await env.STORE_DB.batch([
		env.STORE_DB.prepare("DELETE FROM store_reports WHERE entry_id = ?").bind(id),
		env.STORE_DB.prepare("DELETE FROM store_review_tokens WHERE entry_id = ?").bind(id),
		env.STORE_DB.prepare("DELETE FROM store_entries WHERE id = ?").bind(id),
	]);
}
