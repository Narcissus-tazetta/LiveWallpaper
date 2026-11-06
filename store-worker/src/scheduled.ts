import type { Env } from "./env";
import { ORPHAN_UPLOAD_GRACE_SECONDS } from "./constants";
import { applyReviewDecision } from "./review-decision";

/// upload-url取得後にsubmitされなかったR2実体を定期回収する。DBに参照がある実体は
/// statusにかかわらず保持し、署名URLの有効期限+十分な猶予を過ぎた孤児だけを消す。
async function cleanupOrphanUploads(env: Env): Promise<void> {
	const cutoff = Date.now() - ORPHAN_UPLOAD_GRACE_SECONDS * 1000;
	for (const prefix of ["packages/", "thumbnails/"]) {
		let cursor: string | undefined;
		do {
			const listed = await env.STORE_BUCKET.list({ prefix, cursor, limit: 500 });
			for (const object of listed.objects) {
				if (object.uploaded.getTime() > cutoff) continue;
				const column = prefix === "packages/" ? "object_key" : "thumbnail_key";
				const referenced = await env.STORE_DB.prepare(`SELECT 1 FROM store_entries WHERE ${column} = ? LIMIT 1`)
					.bind(object.key)
					.first();
				if (!referenced) await env.STORE_BUCKET.delete(object.key);
			}
			cursor = listed.truncated ? listed.cursor : undefined;
		} while (cursor);
	}
}

/// 審査依頼の全トークンが失効しても管理者が決定しなかった投稿を自動的に却下する
/// (#2)。resend-reviewで新トークンを発行すると各トークンのexpires_atが更新される
/// ため、この条件は実質「最後に発行された審査リンクが失効してから」を意味し、
/// クライアント側の文言(48時間以内に承認されなかった場合は却下されたものとみなす)
/// と一致する。wrangler.tomlの[triggers].cronsで定期実行される。
export async function handleScheduled(env: Env): Promise<void> {
	const nowISO = new Date().toISOString();
	const { results } = await env.STORE_DB.prepare(
		`SELECT se.id as id FROM store_entries se
		 WHERE se.status = 'requested'
		 AND NOT EXISTS (
			 SELECT 1 FROM store_review_tokens srt
			 WHERE srt.entry_id = se.id AND srt.expires_at > ?
		 )`,
	)
		.bind(nowISO)
		.all();

	await Promise.all((results as { id: string }[]).map((row) => applyReviewDecision(env, row.id, "reject")));
	await cleanupOrphanUploads(env);
}
