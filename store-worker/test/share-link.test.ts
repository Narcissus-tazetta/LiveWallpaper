import { createExecutionContext, env, waitOnExecutionContext } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";
import worker from "../src/index";
import schema from "../schema.sql?raw";

const ORIGIN = "https://store.example.com";

beforeAll(async () => {
	// D1 exec() treats each line as a statement, so multi-line CREATE TABLE has to go through prepare().run().
	const statements = schema
		.split(";")
		.map((s) => s.trim())
		.filter((s) => s.length > 0);
	for (const stmt of statements) {
		await env.STORE_DB.prepare(stmt).run();
	}
});

async function callWorker(request: Request): Promise<Response> {
	const ctx = createExecutionContext();
	const res = await worker.fetch(request, env, ctx);
	await waitOnExecutionContext(ctx);
	return res;
}

interface EntryFixture {
	title?: string;
	author?: string;
	description?: string | null;
	license?: string | null;
	durationSeconds?: number | null;
	hasAudio?: number | null;
	thumbnailKey?: string | null;
	status?: string;
}

async function insertEntry(fixture: EntryFixture = {}): Promise<string> {
	const id = crypto.randomUUID();
	await env.STORE_DB.prepare(
		`INSERT INTO store_entries (id, title, author, description, object_key, thumbnail_key, sha256, size_bytes,
			duration_seconds, has_audio, license, created_at, status, download_count)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
	)
		.bind(
			id,
			fixture.title ?? "Ocean Waves",
			fixture.author ?? "Alice",
			fixture.description === undefined ? "Calm sea at dusk" : fixture.description,
			`packages/${id}.lwpkg`,
			fixture.thumbnailKey === undefined ? `thumbnails/${id}.jpg` : fixture.thumbnailKey,
			"a".repeat(64),
			1234,
			fixture.durationSeconds === undefined ? 75 : fixture.durationSeconds,
			fixture.hasAudio === undefined ? 1 : fixture.hasAudio,
			fixture.license === undefined ? "CC BY 4.0" : fixture.license,
			"2026-11-01T00:00:00.000Z",
			fixture.status ?? "published",
			3,
		)
		.run();
	return id;
}

describe("GET /entries/:id", () => {
	it("returns a published entry in the same shape as a /catalog item", async () => {
		const id = await insertEntry({ title: "Catalog Shape Check" });

		const res = await callWorker(new Request(`${ORIGIN}/entries/${id}`));
		expect(res.status).toBe(200);
		expect(res.headers.get("cache-control")).toBe("public, max-age=60");
		const entry = await res.json();
		expect(entry).toEqual({
			id,
			title: "Catalog Shape Check",
			author: "Alice",
			description: "Calm sea at dusk",
			sha256: "a".repeat(64),
			sizeBytes: 1234,
			durationSeconds: 75,
			hasAudio: true,
			license: "CC BY 4.0",
			createdAt: "2026-11-01T00:00:00.000Z",
			downloadCount: 3,
			downloadURL: `${ORIGIN}/download/${id}`,
			thumbnailURL: `${ORIGIN}/thumbnail/${id}`,
		});

		const catalog = (await (await callWorker(new Request(`${ORIGIN}/catalog?q=Catalog%20Shape%20Check`))).json()) as {
			entries: unknown[];
		};
		expect(catalog.entries).toEqual([entry]);
	});

	it("maps missing optional fields to null", async () => {
		const id = await insertEntry({
			description: null,
			license: null,
			durationSeconds: null,
			hasAudio: null,
			thumbnailKey: null,
		});

		const entry = (await (await callWorker(new Request(`${ORIGIN}/entries/${id}`))).json()) as Record<string, unknown>;
		expect(entry).toMatchObject({
			description: null,
			license: null,
			durationSeconds: null,
			hasAudio: null,
			thumbnailURL: null,
		});
	});

	it("404s for unpublished and missing entries", async () => {
		for (const status of ["requested", "rejected"]) {
			const id = await insertEntry({ status });
			const res = await callWorker(new Request(`${ORIGIN}/entries/${id}`));
			expect(res.status).toBe(404);
			expect(await res.json()).toEqual({ error: "entry not found" });
		}
		const missing = await callWorker(new Request(`${ORIGIN}/entries/${crypto.randomUUID()}`));
		expect(missing.status).toBe(404);
	});

	it("does not shadow /entries/:id/status", async () => {
		const id = await insertEntry({ status: "requested" });
		const res = await callWorker(new Request(`${ORIGIN}/entries/${id}/status`));
		expect(res.status).toBe(200);
		expect(await res.json()).toMatchObject({ id, status: "requested" });
	});
});

describe("GET /w/:id", () => {
	it("renders the share page with the open-in-app link and social preview tags", async () => {
		const id = await insertEntry({ title: "Aurora", author: "Bob", durationSeconds: 3725 });

		const res = await callWorker(new Request(`${ORIGIN}/w/${id}`));
		expect(res.status).toBe(200);
		expect(res.headers.get("content-type")).toBe("text/html; charset=utf-8");
		const csp = res.headers.get("content-security-policy") ?? "";
		expect(csp).toContain("default-src 'none'");
		expect(csp).toMatch(/style-src 'sha256-[A-Za-z0-9+/=]+'/);
		expect(csp).not.toContain("script-src");

		const html = await res.text();
		expect(html).toContain(`href="livewallpaper://store?id=${id}"`);
		expect(html).toContain(">Open in LiveWallpaper</a>");
		expect(html).toContain('href="https://github.com/Narcissus-tazetta/LiveWallpaper/releases"');
		expect(html).toContain(`<img class="thumb" src="${ORIGIN}/thumbnail/${id}"`);
		expect(html).toContain('<meta property="og:title" content="Aurora">');
		expect(html).toContain('<meta property="og:description" content="Calm sea at dusk">');
		expect(html).toContain(`<meta property="og:image" content="${ORIGIN}/thumbnail/${id}">`);
		expect(html).toContain(`<meta property="og:url" content="${ORIGIN}/w/${id}">`);
		expect(html).toContain('<meta name="twitter:card" content="summary_large_image">');
		expect(html).toContain("by Bob · 1:02:05 · License: CC BY 4.0");
		expect(html).not.toContain("<script");
	});

	it("matches the CSP style hash to the inline style", async () => {
		const id = await insertEntry();
		const res = await callWorker(new Request(`${ORIGIN}/w/${id}`));
		const html = await res.text();
		const style = html.match(/<style>([\s\S]*?)<\/style>/)?.[1] ?? "";
		const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(style)));
		const expected = btoa(String.fromCharCode(...digest));
		expect(res.headers.get("content-security-policy")).toContain(`'sha256-${expected}'`);
	});

	it("escapes every submitter-provided string", async () => {
		const id = await insertEntry({
			title: `<script>alert(1)</script>"'`,
			author: `"><img src=x onerror=alert(2)>`,
			description: `</p><b>bold</b>`,
			license: `<i>MIT</i>`,
		});

		const html = await (await callWorker(new Request(`${ORIGIN}/w/${id}`))).text();
		expect(html).not.toContain("<script>alert(1)");
		expect(html).not.toContain("<img src=x");
		expect(html).not.toContain("<b>bold</b>");
		expect(html).not.toContain("<i>MIT</i>");
		expect(html).toContain("&lt;script&gt;alert(1)&lt;/script&gt;&quot;&#39;");
		expect(html).toContain(`<meta property="og:title" content="&lt;script&gt;alert(1)&lt;/script&gt;&quot;&#39;">`);
		expect(html).toContain("&quot;&gt;&lt;img src=x onerror=alert(2)&gt;");
		expect(html).toContain("&lt;/p&gt;&lt;b&gt;bold&lt;/b&gt;");
		expect(html).toContain("License: &lt;i&gt;MIT&lt;/i&gt;");
	});

	it("falls back to a summary card and generated description without a thumbnail or description", async () => {
		const id = await insertEntry({ author: "Carol", description: null, thumbnailKey: null, license: null });

		const html = await (await callWorker(new Request(`${ORIGIN}/w/${id}`))).text();
		expect(html).toContain('<meta name="twitter:card" content="summary">');
		expect(html).not.toContain("og:image");
		expect(html).not.toContain('class="thumb"');
		expect(html).toContain('<meta property="og:description" content="A live wallpaper by Carol · 1:15">');
	});

	it("serves an uncached HTML 404 for unpublished and missing entries", async () => {
		const requestedId = await insertEntry({ status: "requested", title: "Secret Draft" });
		for (const id of [requestedId, crypto.randomUUID()]) {
			const res = await callWorker(new Request(`${ORIGIN}/w/${id}`));
			expect(res.status).toBe(404);
			expect(res.headers.get("content-type")).toBe("text/html; charset=utf-8");
			expect(res.headers.get("cache-control")).toBe("no-store");
			const html = await res.text();
			expect(html).toContain("Wallpaper not found");
			expect(html).not.toContain("Secret Draft");
		}
	});
});
