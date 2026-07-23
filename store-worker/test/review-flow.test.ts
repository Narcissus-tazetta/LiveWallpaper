import {
	createExecutionContext,
	env,
	fetchMock,
	waitOnExecutionContext,
} from "cloudflare:test";
import { zipSync } from "fflate";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";
import worker from "../src/index";
// Workers環境にはnode:fsが無いため、Viteの?raw importでビルド時にschema.sqlの
// 内容を文字列として取り込む(本番のスキーマ管理方法=schema.sqlはそのまま)。
import schema from "../schema.sql?raw";

const ADMIN_KEY = "test-admin-key";

beforeAll(async () => {
	// D1のexec()は1行=1文として扱うため複数行のCREATE TABLEを解釈できない。
	// ";"区切りで文単位に分割し、prepare().run()で1文ずつ流す。
	const statements = schema
		.split(";")
		.map((s) => s.trim())
		.filter((s) => s.length > 0);
	for (const stmt of statements) {
		await env.STORE_DB.prepare(stmt).run();
	}
});

beforeEach(() => {
	fetchMock.activate();
	fetchMock.disableNetConnect();
});

/// worker.fetch()を直接呼び、ctx.waitUntil()された審査メール送信が完了するまで
/// 待ってからレスポンスを返す(SELF.fetchと違いwaitUntilの完了を保証できるため、
/// モックしたResend呼び出しからトークンを確実に読み取れる)。
async function callWorker(request: Request): Promise<Response> {
	const ctx = createExecutionContext();
	const res = await worker.fetch(request, env, ctx);
	await waitOnExecutionContext(ctx);
	return res;
}

/// Resendへの審査メール送信をモックし、本文に埋め込まれた審査URLから生トークンを
/// 抜き出せるようにする。実際の管理者がメールから得るのと同じ経路でトークンを
/// 取得することで、テストがDB内部実装(ハッシュ化)に依存しないようにしている。
///
/// fetchMockの登録済みインターセプターは「テストファイル単位」でしかリセットされない
/// (テストごとではない)ため、.persist()で使い回すと前のテストの捕獲用クロージャが
/// 後続テストの呼び出しを横取りしてしまう。1回消費されると自動的にキューから
/// 外れる非persistのインターセプターを、期待する呼び出し回数分だけ積む方式にする。
function mockResendEmail() {
	const tokens: string[] = [];
	function queueOne() {
		fetchMock
			.get("https://api.resend.com")
			.intercept({ path: "/emails", method: "POST" })
			.reply(200, (opts) => {
				const payload = JSON.parse(opts.body as string) as { text: string };
				const match = payload.text.match(/\/admin\/review\/([\w-]+)/);
				tokens.push(match ? match[1] : "");
				return JSON.stringify({ id: "test-email-id" });
			});
	}
	queueOne();
	return {
		getToken: (index = 0) => tokens[index] ?? "",
		queueAnother: queueOne,
	};
}

async function submitEntry(overrides: { title?: string; author?: string } = {}) {
	const id = crypto.randomUUID();
	const objectKey = `packages/${id}.lwpkg`;
	const bytes = new TextEncoder().encode("fake package bytes");
	await env.STORE_BUCKET.put(objectKey, bytes);

	const res = await callWorker(
		new Request("https://store.example.com/submit", {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify({
				id,
				title: overrides.title ?? "Test Title",
				author: overrides.author ?? "Test Author",
				sha256: "deadbeef",
				sizeBytes: bytes.byteLength,
				objectKey,
			}),
		}),
	);
	return { res, id };
}

/// /admin/review/:token/video のテスト用に、動画バイト列を含む本物のZIP(.lwpkg相当)
/// を組み立ててsubmitする。PackageExporter/PackageArchiveWriter が実際に作る
/// content/videos/<id>.mp4 という配置(--keepParentでcontent/を持つZIP)を再現する。
async function submitEntryWithVideo(
	videoBytes: Uint8Array,
): Promise<{ res: Response; id: string }> {
	const id = crypto.randomUUID();
	const objectKey = `packages/${id}.lwpkg`;
	const zipBytes = zipSync({
		"content/metadata.json": new TextEncoder().encode("{}"),
		"content/videos/some-video-id.mp4": videoBytes,
	});
	await env.STORE_BUCKET.put(objectKey, zipBytes);

	const res = await callWorker(
		new Request("https://store.example.com/submit", {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify({
				id,
				title: "Video Test",
				author: "Test Author",
				sha256: "deadbeef",
				sizeBytes: zipBytes.byteLength,
				objectKey,
			}),
		}),
	);
	return { res, id };
}

function decideRequest(token: string, action: "approve" | "reject"): Request {
	return new Request(`https://store.example.com/admin/review/${token}/decide`, {
		method: "POST",
		headers: { "content-type": "application/x-www-form-urlencoded" },
		body: `action=${action}`,
	});
}

async function entryStatus(id: string): Promise<string | undefined> {
	const row = await env.STORE_DB.prepare("SELECT status FROM store_entries WHERE id = ?")
		.bind(id)
		.first<{ status: string }>();
	return row?.status;
}

describe("store submission review flow", () => {
	it("submit creates a 'requested' entry with a one-time review token", async () => {
		const { res, id } = await submitEntry();
		expect(res.status).toBe(200);
		const json = (await res.json()) as { entry: { status: string } };
		expect(json.entry.status).toBe("requested");
		expect(await entryStatus(id)).toBe("requested");

		const tokenRow = await env.STORE_DB.prepare(
			"SELECT consumed_at, expires_at FROM store_review_tokens WHERE entry_id = ?",
		)
			.bind(id)
			.first<{ consumed_at: string | null; expires_at: string }>();
		expect(tokenRow?.consumed_at).toBeNull();
		expect(new Date(tokenRow!.expires_at).getTime()).toBeGreaterThan(Date.now());
	});

	it("hides 'requested' entries from catalog/download/thumbnail", async () => {
		const { id } = await submitEntry();

		const catalogRes = await callWorker(new Request("https://store.example.com/catalog"));
		const catalogJson = (await catalogRes.json()) as { entries: { id: string }[] };
		expect(catalogJson.entries.find((e) => e.id === id)).toBeUndefined();

		const downloadRes = await callWorker(
			new Request(`https://store.example.com/download/${id}`),
		);
		expect(downloadRes.status).toBe(404);

		const thumbnailRes = await callWorker(
			new Request(`https://store.example.com/thumbnail/${id}`),
		);
		expect(thumbnailRes.status).toBe(404);
	});

	it("decide is one-time use: a second decision on the same token is rejected", async () => {
		const mock = mockResendEmail();
		const { id } = await submitEntry();
		const token = mock.getToken();
		expect(token).not.toBe("");

		const first = await callWorker(decideRequest(token, "approve"));
		expect(first.status).toBe(303);
		expect(await entryStatus(id)).toBe("published");

		const second = await callWorker(decideRequest(token, "reject"));
		expect(second.status).toBe(410);
		// 2回目は拒否されるので、承認済みのステータスは変わらない。
		expect(await entryStatus(id)).toBe("published");
	});

	it("an expired token is rejected and the review page shows an expired notice", async () => {
		const mock = mockResendEmail();
		const { id } = await submitEntry();
		const token = mock.getToken();

		await env.STORE_DB.prepare(
			"UPDATE store_review_tokens SET expires_at = ? WHERE entry_id = ?",
		)
			.bind(new Date(0).toISOString(), id)
			.run();

		const decideRes = await callWorker(decideRequest(token, "approve"));
		expect(decideRes.status).toBe(410);
		expect(await entryStatus(id)).toBe("requested");

		const pageRes = await callWorker(
			new Request(`https://store.example.com/admin/review/${token}`),
		);
		expect(pageRes.status).toBe(200);
		expect(await pageRes.text()).toContain("失効しました");
	});

	it("direct ADMIN_KEY approve/reject requires the key and cannot double-decide", async () => {
		const { id } = await submitEntry();

		const unauthed = await callWorker(
			new Request(`https://store.example.com/admin/entries/${id}/approve`, { method: "POST" }),
		);
		expect(unauthed.status).toBe(401);

		const approve = await callWorker(
			new Request(`https://store.example.com/admin/entries/${id}/approve`, {
				method: "POST",
				headers: { "x-admin-key": ADMIN_KEY },
			}),
		);
		expect(approve.status).toBe(200);
		expect(await entryStatus(id)).toBe("published");

		const approveAgain = await callWorker(
			new Request(`https://store.example.com/admin/entries/${id}/approve`, {
				method: "POST",
				headers: { "x-admin-key": ADMIN_KEY },
			}),
		);
		expect(approveAgain.status).toBe(409);

		const rejectAfterApprove = await callWorker(
			new Request(`https://store.example.com/admin/entries/${id}/reject`, {
				method: "POST",
				headers: { "x-admin-key": ADMIN_KEY },
			}),
		);
		expect(rejectAfterApprove.status).toBe(409);
		expect(await entryStatus(id)).toBe("published");
	});

	it("resend-review force-expires the old token and the new one still works", async () => {
		const mock = mockResendEmail();
		const { id } = await submitEntry();
		const oldToken = mock.getToken(0);

		mock.queueAnother();
		const resendRes = await callWorker(
			new Request(`https://store.example.com/admin/entries/${id}/resend-review`, {
				method: "POST",
				headers: { "x-admin-key": ADMIN_KEY },
			}),
		);
		expect(resendRes.status).toBe(200);
		const newToken = mock.getToken(1);
		expect(newToken).not.toBe("");
		expect(newToken).not.toBe(oldToken);

		const oldDecide = await callWorker(decideRequest(oldToken, "approve"));
		expect(oldDecide.status).toBe(410);

		const newDecide = await callWorker(decideRequest(newToken, "approve"));
		expect(newDecide.status).toBe(303);
		expect(await entryStatus(id)).toBe("published");
	});

	it("/admin/requests requires ADMIN_KEY and lists only 'requested' entries", async () => {
		const { id: requestedId } = await submitEntry();
		const { id: approvedId } = await submitEntry();
		await callWorker(
			new Request(`https://store.example.com/admin/entries/${approvedId}/approve`, {
				method: "POST",
				headers: { "x-admin-key": ADMIN_KEY },
			}),
		);

		const unauthed = await callWorker(new Request("https://store.example.com/admin/requests"));
		expect(unauthed.status).toBe(401);

		const res = await callWorker(
			new Request("https://store.example.com/admin/requests", {
				headers: { "x-admin-key": ADMIN_KEY },
			}),
		);
		expect(res.status).toBe(200);
		const json = (await res.json()) as { entries: { id: string }[] };
		const ids = json.entries.map((e) => e.id);
		expect(ids).toContain(requestedId);
		expect(ids).not.toContain(approvedId);
	});

	it("/admin/review/:token/video extracts the video entry out of the .lwpkg zip", async () => {
		const mock = mockResendEmail();
		const videoBytes = new TextEncoder().encode("fake mp4 bytes for review preview");
		await submitEntryWithVideo(videoBytes);
		const token = mock.getToken();

		const res = await callWorker(
			new Request(`https://store.example.com/admin/review/${token}/video`),
		);
		expect(res.status).toBe(200);
		expect(res.headers.get("content-type")).toBe("video/mp4");
		expect(res.headers.get("accept-ranges")).toBe("bytes");
		const body = new Uint8Array(await res.arrayBuffer());
		expect(body).toEqual(videoBytes);

		// レビューページ自体にも<video>タグが埋め込まれていること。
		const pageRes = await callWorker(
			new Request(`https://store.example.com/admin/review/${token}`),
		);
		const pageHtml = await pageRes.text();
		expect(pageHtml).toContain(`/admin/review/${token}/video`);
	});

	it("/admin/review/:token/video honors Range requests for scrubbing", async () => {
		const mock = mockResendEmail();
		const videoBytes = new TextEncoder().encode("0123456789abcdefghij");
		await submitEntryWithVideo(videoBytes);
		const token = mock.getToken();

		const res = await callWorker(
			new Request(`https://store.example.com/admin/review/${token}/video`, {
				headers: { range: "bytes=5-9" },
			}),
		);
		expect(res.status).toBe(206);
		expect(res.headers.get("content-range")).toBe(`bytes 5-9/${videoBytes.byteLength}`);
		const body = new Uint8Array(await res.arrayBuffer());
		expect(new TextDecoder().decode(body)).toBe("56789");
	});

	it("/admin/review/:token/video refuses to preview packages over the size cap", async () => {
		const mock = mockResendEmail();
		const { id } = await submitEntryWithVideo(new TextEncoder().encode("small video"));
		const token = mock.getToken();

		await env.STORE_DB.prepare("UPDATE store_entries SET size_bytes = ? WHERE id = ?")
			.bind(200 * 1024 * 1024, id)
			.run();

		const videoRes = await callWorker(
			new Request(`https://store.example.com/admin/review/${token}/video`),
		);
		expect(videoRes.status).toBe(413);

		const pageRes = await callWorker(
			new Request(`https://store.example.com/admin/review/${token}`),
		);
		const pageHtml = await pageRes.text();
		expect(pageHtml).toContain("プレビューできません");
		expect(pageHtml).toContain(`/admin/review/${token}/download`);
	});

	it("/admin/review/:token/download streams the raw package even when it's too large to preview and still 'requested'", async () => {
		const mock = mockResendEmail();
		const videoBytes = new TextEncoder().encode("raw package bytes for download fallback");
		const { id } = await submitEntryWithVideo(videoBytes);
		const token = mock.getToken();

		await env.STORE_DB.prepare("UPDATE store_entries SET size_bytes = ? WHERE id = ?")
			.bind(200 * 1024 * 1024, id)
			.run();

		// /download (公開用) はrequestedの間は404になるはず。
		const publicDownload = await callWorker(
			new Request(`https://store.example.com/download/${id}`),
		);
		expect(publicDownload.status).toBe(404);

		// が、トークン付きのレビュー用downloadは生バイト列をそのまま返す。
		const reviewDownload = await callWorker(
			new Request(`https://store.example.com/admin/review/${token}/download`),
		);
		expect(reviewDownload.status).toBe(200);
		const body = new Uint8Array(await reviewDownload.arrayBuffer());
		expect(body.byteLength).toBeGreaterThan(0);
	});

	it("rejecting an entry deletes its R2 objects (video + thumbnail)", async () => {
		const mock = mockResendEmail();
		const { id } = await submitEntry();
		const token = mock.getToken();

		const objectKey = `packages/${id}.lwpkg`;
		const thumbnailKey = `thumbnails/${id}.jpg`;
		await env.STORE_BUCKET.put(thumbnailKey, new TextEncoder().encode("thumb"));
		await env.STORE_DB.prepare("UPDATE store_entries SET thumbnail_key = ? WHERE id = ?")
			.bind(thumbnailKey, id)
			.run();

		expect(await env.STORE_BUCKET.head(objectKey)).not.toBeNull();
		expect(await env.STORE_BUCKET.head(thumbnailKey)).not.toBeNull();

		const decideRes = await callWorker(decideRequest(token, "reject"));
		expect(decideRes.status).toBe(303);
		expect(await entryStatus(id)).toBe("rejected");

		expect(await env.STORE_BUCKET.head(objectKey)).toBeNull();
		expect(await env.STORE_BUCKET.head(thumbnailKey)).toBeNull();
	});

	it("recording the review-token action stays consistent regardless of which path decided the entry", async () => {
		// ADMIN_KEY直叩き(admin.sh)経由でも、トークンのaction列が実際の結果に
		// 同期されること(#7)。
		const mock = mockResendEmail();
		const { id } = await submitEntry();

		await callWorker(
			new Request(`https://store.example.com/admin/entries/${id}/approve`, {
				method: "POST",
				headers: { "x-admin-key": ADMIN_KEY },
			}),
		);

		const tokenRow = await env.STORE_DB.prepare(
			"SELECT consumed_at, action FROM store_review_tokens WHERE entry_id = ?",
		)
			.bind(id)
			.first<{ consumed_at: string | null; action: string | null }>();
		expect(tokenRow?.consumed_at).not.toBeNull();
		expect(tokenRow?.action).toBe("published");
	});

	it("an ADMIN_KEY decision immediately closes out the entry's outstanding email token, so a later decide on it is rejected rather than silently no-oping", async () => {
		const mock = mockResendEmail();
		const { id } = await submitEntry();
		const token = mock.getToken();

		// 先にADMIN_KEY経由で承認が確定する。applyReviewDecisionが未消費トークンを
		// 同期的にconsumed_at/action済みにするため、そのトークンはこの時点で
		// 既に使用済み扱いになる。
		await callWorker(
			new Request(`https://store.example.com/admin/entries/${id}/approve`, {
				method: "POST",
				headers: { "x-admin-key": ADMIN_KEY },
			}),
		);

		const decideRes = await callWorker(decideRequest(token, "reject"));
		// トークンは既に(ADMIN_KEY側の決定に伴って)消費済みなので、この却下は
		// 410で拒否される — エントリは承認済みのまま変わらない。
		expect(decideRes.status).toBe(410);
		expect(await entryStatus(id)).toBe("published");

		const tokenRow = await env.STORE_DB.prepare(
			"SELECT action FROM store_review_tokens WHERE entry_id = ?",
		)
			.bind(id)
			.first<{ action: string | null }>();
		// 記録されるactionは要求されなかった"reject"ではなく実際の結果("published")。
		expect(tokenRow?.action).toBe("published");
	});

	it("scheduled() auto-rejects 'requested' entries whose review tokens have all expired", async () => {
		const mock = mockResendEmail();
		const { id: staleId } = await submitEntry({ title: "Stale" });
		const { id: freshId } = await submitEntry({ title: "Fresh" });
		void mock;

		await env.STORE_DB.prepare(
			"UPDATE store_review_tokens SET expires_at = ? WHERE entry_id = ?",
		)
			.bind(new Date(0).toISOString(), staleId)
			.run();

		const ctx = createExecutionContext();
		await worker.scheduled(
			{ cron: "0 * * * *", scheduledTime: Date.now(), noRetry: () => {} } as never,
			env,
			ctx,
		);
		await waitOnExecutionContext(ctx);

		expect(await entryStatus(staleId)).toBe("rejected");
		expect(await entryStatus(freshId)).toBe("requested");
	});
});
