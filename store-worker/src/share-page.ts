import { findPublishedEntry, type PublicEntry } from "./catalog";
import type { Env } from "./env";
import { escapeHtml } from "./html";

const RELEASES_URL = "https://github.com/Narcissus-tazetta/LiveWallpaper/releases";
const DESCRIPTION_MAX_LENGTH = 200;

const STYLE = `:root{color-scheme:light dark;--bg:#f5f5f7;--fg:#1d1d1f;--muted:#6e6e73;--card:#fff;--accent:#0071e3;--accent-fg:#fff;--border:#d2d2d7}
@media (prefers-color-scheme:dark){:root{--bg:#000;--fg:#f5f5f7;--muted:#a1a1a6;--card:#1c1c1e;--accent:#2997ff;--accent-fg:#fff;--border:#38383a}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
main{max-width:640px;margin:0 auto;padding:32px 16px}
.card{background:var(--card);border:1px solid var(--border);border-radius:16px;overflow:hidden}
.thumb{display:block;width:100%;aspect-ratio:16/9;object-fit:cover;background:var(--border)}
.body{padding:20px}
h1{margin:0 0 4px;font-size:1.5rem;line-height:1.25;overflow-wrap:anywhere}
.meta{margin:0;color:var(--muted);overflow-wrap:anywhere}
.desc{margin:12px 0 0;white-space:pre-line;overflow-wrap:anywhere}
.actions{display:flex;flex-wrap:wrap;gap:12px;align-items:center;margin-top:20px}
.open{display:inline-block;padding:12px 20px;border-radius:10px;background:var(--accent);color:var(--accent-fg);font-weight:600;text-decoration:none}
.get{color:var(--accent);text-decoration:none}
.open:focus-visible,.get:focus-visible{outline:2px solid var(--accent);outline-offset:3px}`;

// CSP hashes the exact inline <style> bytes so the page can stay on style-src without 'unsafe-inline'.
let styleHashPromise: Promise<string> | null = null;
function styleHash(): Promise<string> {
	styleHashPromise ??= crypto.subtle.digest("SHA-256", new TextEncoder().encode(STYLE)).then((digest) => {
		const bytes = new Uint8Array(digest);
		let binary = "";
		for (const byte of bytes) binary += String.fromCharCode(byte);
		return `'sha256-${btoa(binary)}'`;
	});
	return styleHashPromise;
}

function formatDuration(seconds: number): string {
	const total = Math.max(0, Math.round(seconds));
	const h = Math.floor(total / 3600);
	const m = Math.floor((total % 3600) / 60);
	const s = total % 60;
	const ss = s.toString().padStart(2, "0");
	return h > 0 ? `${h}:${m.toString().padStart(2, "0")}:${ss}` : `${m}:${ss}`;
}

function truncate(s: string, max: number): string {
	return s.length > max ? `${s.slice(0, max - 1).trimEnd()}…` : s;
}

function renderEntryPage(entry: PublicEntry, pageURL: string): string {
	const metaParts = [`by ${entry.author}`];
	if (entry.durationSeconds !== null) metaParts.push(formatDuration(entry.durationSeconds));
	if (entry.license) metaParts.push(`License: ${entry.license}`);
	const metaLine = metaParts.join(" · ");
	const ogDescription = truncate(entry.description?.trim() || `A live wallpaper ${metaLine}`, DESCRIPTION_MAX_LENGTH);
	const openURL = `livewallpaper://store?id=${encodeURIComponent(entry.id)}`;
	const title = escapeHtml(entry.title);

	const imageMeta = entry.thumbnailURL
		? `<meta property="og:image" content="${escapeHtml(entry.thumbnailURL)}">
<meta property="og:image:alt" content="${title}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:image" content="${escapeHtml(entry.thumbnailURL)}">`
		: `<meta name="twitter:card" content="summary">`;
	const thumbnail = entry.thumbnailURL ? `<img class="thumb" src="${escapeHtml(entry.thumbnailURL)}" alt="">` : "";

	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title} · LiveWallpaper</title>
<meta name="description" content="${escapeHtml(ogDescription)}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="LiveWallpaper">
<meta property="og:title" content="${title}">
<meta property="og:description" content="${escapeHtml(ogDescription)}">
<meta property="og:url" content="${escapeHtml(pageURL)}">
${imageMeta}
<meta name="twitter:title" content="${title}">
<meta name="twitter:description" content="${escapeHtml(ogDescription)}">
<style>${STYLE}</style>
</head>
<body>
<main>
<article class="card">
${thumbnail}
<div class="body">
<h1>${title}</h1>
<p class="meta">${escapeHtml(metaLine)}</p>
${entry.description ? `<p class="desc">${escapeHtml(entry.description)}</p>` : ""}
<div class="actions">
<a class="open" href="${escapeHtml(openURL)}">Open in LiveWallpaper</a>
<a class="get" href="${RELEASES_URL}">Get LiveWallpaper</a>
</div>
</div>
</article>
</main>
</body>
</html>`;
}

function renderNotFoundPage(): string {
	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex">
<title>Wallpaper not found · LiveWallpaper</title>
<style>${STYLE}</style>
</head>
<body>
<main>
<article class="card">
<div class="body">
<h1>Wallpaper not found</h1>
<p class="meta">This wallpaper doesn't exist or is no longer available.</p>
<div class="actions">
<a class="get" href="${RELEASES_URL}">Get LiveWallpaper</a>
</div>
</div>
</article>
</main>
</body>
</html>`;
}

async function htmlResponse(html: string, status: number): Promise<Response> {
	return new Response(html, {
		status,
		headers: {
			"content-type": "text/html; charset=utf-8",
			"content-security-policy": `default-src 'none'; img-src 'self'; style-src ${await styleHash()}; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`,
			"x-content-type-options": "nosniff",
			"referrer-policy": "strict-origin-when-cross-origin",
			// Kept short because a withdrawn or rejected entry must disappear from shared links quickly.
			"cache-control": status === 200 ? "public, max-age=60" : "no-store",
		},
	});
}

export async function handleSharePage(request: Request, env: Env, id: string): Promise<Response> {
	const url = new URL(request.url);
	const entry = await findPublishedEntry(env, id, url.origin);
	if (!entry) {
		return htmlResponse(renderNotFoundPage(), 404);
	}
	return htmlResponse(renderEntryPage(entry, new URL(`/w/${entry.id}`, url.origin).toString()), 200);
}
