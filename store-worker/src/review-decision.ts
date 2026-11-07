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

/// requested → published/rejected の状態遷移をこの1関数に集約する。トークン経由の
/// decide とADMIN_KEY直叩きのapprove/rejectの両方がここだけを呼ぶことで、二重承認や
/// 取りこぼしを防ぐ。WHERE status='requested' のガードにより、既に決定済みの
/// エントリを誤って上書きすることはない(meta.changesで判定)。
///
/// 決定が実際に反映された場合、この関数の中で副作用を集約して行う:
///   - このエントリに紐づく未消費の審査トークンを全て consumed 済みにし、action に
///     「実際の結果」を記録する。これにより decide(トークン経由)/approve・reject
///     (ADMIN_KEY直叩き)のどちらで決定されても /admin/requests の監査結果が一致する
///     (片方だけがaction列を更新する非対称を避ける)。
///   - rejected になった場合、R2上の動画/サムネイルを削除する(却下したのに実体が
///     オブジェクトキーを知る誰からも読めてしまう状態を残さないため)。
///
/// 呼び出し元(decide)がこのエントリの特定トークンを先に消費済み(consumed_at設定済み、
/// actionは未設定)にしていた場合でも、「action IS NULL」の条件でここから拾われて
/// 実際の結果が書き込まれる。これにより「トークンを消費したのに、他経路の決定と
/// 競合して実際には何も変わらなかった」ケースでも、記録されるactionは意図した
/// approve/rejectではなく実際のステータスになる(#4/#7 で指摘された不整合の解消)。
export async function applyReviewDecision(
	env: Env,
	entryId: string,
	action: "approve" | "reject",
): Promise<{ changed: boolean; status: string | null }> {
	const requestedStatus = action === "approve" ? "published" : "rejected";
	const nowISO = new Date().toISOString();
	// 状態遷移とトークン監査更新はD1 batchの同一トランザクションで
	// 実行し、片方だけが永続化される状態を作らない。
	const [result] = await env.STORE_DB.batch([
		env.STORE_DB.prepare("UPDATE store_entries SET status = ? WHERE id = ? AND status = 'requested'").bind(
			requestedStatus,
			entryId,
		),
		env.STORE_DB.prepare(
			`UPDATE store_review_tokens SET consumed_at = COALESCE(consumed_at, ?), action = ?
			 WHERE entry_id = ? AND (consumed_at IS NULL OR action IS NULL)`,
		).bind(nowISO, requestedStatus, entryId),
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

	if (status === null) {
		// entryIdが存在しない(呼び出し元のバグ以外では起きないはず)。トークンや
		// R2への副作用は行わずそのまま返し、呼び出し元に404判定させる。
		return { changed, status };
	}

	if (!changed) {
		// 競合相手が先に決定した場合は監査値を実際の状態に補正する。
		await env.STORE_DB.prepare("UPDATE store_review_tokens SET action = ? WHERE entry_id = ?")
			.bind(status, entryId)
			.run();
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
