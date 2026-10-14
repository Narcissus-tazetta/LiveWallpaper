import { build } from "esbuild";
import { Miniflare, Response } from "miniflare";
import { readFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

const storeRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const repositoryRoot = resolve(storeRoot, "..");
const temporary = await mkdtemp(resolve(tmpdir(), "store-integration-"));
const production = Bun.TOML.parse(await readFile(resolve(storeRoot, "wrangler.toml"), "utf8"));
let runtime;
let child;
let emails = 0;
const blockedRequests = [];
let interrupted = false;
function stop() {
	if (!child?.pid || child.exitCode !== null || child.signalCode !== null) return;
	// Swift launches a separate XCTest process; stopping only Swift leaves it behind.
	try { process.kill(-child.pid, "SIGTERM"); }
	catch (error) { if (error.code !== "ESRCH") throw error; }
}
function interrupt() { interrupted = true; stop(); }
process.on("SIGINT", interrupt);
process.on("SIGTERM", interrupt);
try {
	const bundled = await build({
		entryPoints: [resolve(storeRoot, "test/integration/worker.ts")],
		bundle: true, format: "esm", platform: "browser", write: false,
	});
	runtime = new Miniflare({
		modules: true, script: bundled.outputFiles[0].text,
		host: "127.0.0.1", port: 0,
		compatibilityDate: production.compatibility_date,
		compatibilityFlags: production.compatibility_flags ?? [],
		d1Databases: { STORE_DB: "integration-db" }, d1Persist: resolve(temporary, "d1"),
		r2Buckets: { STORE_BUCKET: "integration-bucket" }, r2Persist: resolve(temporary, "r2"),
		ratelimits: Object.fromEntries(production.ratelimits.map(({ name, ...binding }) => [name, binding])),
		bindings: {
			ADMIN_KEY: "integration-admin", RESEND_API_KEY: "integration-mail",
			R2_ACCOUNT_ID: "integration-account", R2_BUCKET_NAME: "integration-bucket",
			R2_ACCESS_KEY_ID: "integration-access", R2_SECRET_ACCESS_KEY: "integration-secret",
		},
		outboundService: async request => {
			const url = new URL(request.url);
			if (request.method === "POST" && url.href === "https://api.resend.com/emails") {
				await request.json();
				emails++;
				return Response.json({ id: `integration-email-${emails}` });
			}
			blockedRequests.push(request.url);
			throw new Error(`External network blocked: ${url.origin}`);
		},
	});
	const baseURL = await runtime.ready;
	const db = await runtime.getD1Database("STORE_DB");
	const schema = await readFile(resolve(storeRoot, "schema.sql"), "utf8");
	for (const statement of schema.split(";").map(value => value.trim()).filter(Boolean)) {
		await db.prepare(statement).run();
	}
	if (interrupted) throw new Error("Store integration interrupted");
	console.log(`Isolated Store: ${baseURL.origin}`);
	const code = await new Promise((resolveCode, reject) => {
		child = spawn("swift", ["test", "--filter", "StoreIntegrationTests"], {
			cwd: repositoryRoot, stdio: "inherit", detached: true,
			env: { ...process.env, LIVEWALLPAPER_STORE_TEST_URL: baseURL.origin },
		});
		let timedOut = false;
		const timeout = setTimeout(() => { timedOut = true; stop(); }, 180_000);
		child.on("error", error => { clearTimeout(timeout); reject(error); });
		child.on("exit", (status, signal) => {
			clearTimeout(timeout);
			if (timedOut) reject(new Error("Swift integration tests exceeded 180 seconds"));
			else if (signal) reject(new Error(`Swift integration tests terminated: ${signal}`));
			else resolveCode(status);
		});
	});
	if (code !== 0) throw new Error(`Swift integration tests failed (${code})`);
	if (blockedRequests.length) throw new Error("Unexpected external requests were blocked");
	if (emails === 0) throw new Error("The submission did not exercise review email delivery");
	console.log(`Store integration passed; ${emails} review email(s) captured locally.`);
} finally {
	stop();
	await runtime?.dispose();
	await rm(temporary, { recursive: true, force: true });
	process.removeListener("SIGINT", interrupt);
	process.removeListener("SIGTERM", interrupt);
}
