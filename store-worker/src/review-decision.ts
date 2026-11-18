import { UPLOAD_WINDOW_MS } from "./constants";
import type { Env } from "./env";
import { deleteEntryObjects } from "./storage";

/// How long the entry's presigned upload URLs may still overwrite its objects (0 once closed).
/// See UPLOAD_WINDOW_MS.
export function uploadWindowRemainingMs(createdAt: string, now = Date.now()): number {
	return Math.max(0, new Date(createdAt).getTime() + UPLOAD_WINDOW_MS - now);
}

export function uploadWindowOpenMessage(remainingMs: number): string {
	return `upload window still open; review is possible in ${Math.ceil(remainingMs / 60_000)} min`;
}

// Keep the recorded action tied to the actual entry state when different review
// routes race. Rejected objects may still need cleanup after a previous failed delete.
export async function applyReviewDecision(
	env: Env,
	entryId: string,
	action: "approve" | "reject",
	expiredAt?: string,
): Promise<{ changed: boolean; status: string | null }> {
	const requestedStatus = action === "approve" ? "published" : "rejected";
	const nowISO = new Date().toISOString();
	const expirationCondition =
		expiredAt === undefined
			? ""
			: ` AND NOT EXISTS (
				SELECT 1 FROM store_review_tokens WHERE entry_id = store_entries.id AND expires_at > ?
			)`;
	// 状態遷移とトークン監査更新はD1 batchの同一トランザクションで
	// 実行し、片方だけが永続化される状態を作らない。
	const [result] = await env.STORE_DB.batch([
		env.STORE_DB.prepare(
			`UPDATE store_entries SET status = ? WHERE id = ? AND status = 'requested'${expirationCondition}`,
		).bind(requestedStatus, entryId, ...(expiredAt === undefined ? [] : [expiredAt])),
		env.STORE_DB.prepare(
			`UPDATE store_review_tokens SET consumed_at = COALESCE(consumed_at, ?),
			     action = (SELECT status FROM store_entries WHERE id = entry_id)
			 WHERE entry_id = ? AND (action IS NULL OR action IN ('approve', 'reject'))
			 AND EXISTS (
			     SELECT 1 FROM store_entries WHERE id = entry_id AND status IN ('published', 'rejected')
			 )`,
		).bind(nowISO, entryId),
	]);
	const changed = result.meta.changes === 1;

	// changed===false の場合、実際のステータス(既に決定済みならそれ、entryIdが
	// 存在しなければnull)を読み直す。呼び出し元(handleAdminDecision)がこれで
	// 「既に決定済み」と「そもそも存在しない」を区別できるようにする。
	let status: string | null = requestedStatus;
	if (!changed) {
		const row = await env.STORE_DB.prepare("SELECT status FROM store_entries WHERE id = ?")
			.bind(entryId)
			.first<{ status: string }>();
		status = row?.status ?? null;
	}

	if (status === "rejected") {
		const row = await env.STORE_DB.prepare("SELECT object_key, thumbnail_key FROM store_entries WHERE id = ?")
			.bind(entryId)
			.first<{ object_key: string; thumbnail_key: string | null }>();
		if (row) {
			await deleteEntryObjects(env, row.object_key, row.thumbnail_key);
		}
	}

	return { changed, status };
}
