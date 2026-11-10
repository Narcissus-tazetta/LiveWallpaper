<script lang="ts">
    import { asset, resolve } from "$app/paths";
    import CopyButton from "./CopyButton.svelte";
    import Faq from "./Faq.svelte";
    import Features from "./Features.svelte";
    import HeroVideo from "./HeroVideo.svelte";
    import Screenshots from "./Screenshots.svelte";
    import { brewCommand, dictionaries, donateUrl, repo, repoApi, siteUrl, type Lang } from "./i18n";

    let { lang, release }: { lang: Lang; release: { version: string; date: string } } = $props();

    const t = $derived(dictionaries[lang]);
    const other = $derived(lang === "ja" ? "en" : "ja");
    const pageUrl = { en: `${siteUrl}/`, ja: `${siteUrl}/ja/` } as const;

    const videoSource = "https://www.pexels.com/video/29717425/";
    const photoSource = "https://pixabay.com/photos/pond-lake-of-fire-azores-mountain-6390510/";
    const cloudsSource = "https://pixabay.com/videos/clouds-blue-sky-hdr-summer-nature-180151/";

    let scrolled = $state(false);
    let downloads = $state<number>();

    // Counts every release asset, so Homebrew installs and in-app updates (both zip) are included alongside DMGs.
    async function countDownloads() {
        let total = 0;
        for (let page = 1; ; page++) {
            const response = await fetch(`${repoApi}/releases?per_page=100&page=${page}`);
            if (!response.ok) throw new Error(`GitHub API responded ${response.status}`);
            const releases = (await response.json()) as { assets: { download_count: number }[] }[];
            for (const release of releases) {
                for (const item of release.assets) total += item.download_count;
            }
            if (releases.length < 100) return total;
        }
    }

    $effect(() => {
        countDownloads()
            .then((total) => (downloads = total))
            // The count is decoration; the page is complete without it.
            .catch((error: unknown) => console.warn("Could not load the download count:", error));
    });
</script>

<svelte:window onscroll={() => (scrolled = window.scrollY > 8)} />

<svelte:head>
    <title>{t.title}</title>
    <meta name="description" content={t.description} />
    <link rel="canonical" href={pageUrl[lang]} />
    <link rel="alternate" hreflang="en" href={pageUrl.en} />
    <link rel="alternate" hreflang="ja" href={pageUrl.ja} />
    <link rel="alternate" hreflang="x-default" href={pageUrl.en} />
    <meta property="og:type" content="website" />
    <meta property="og:site_name" content="LiveWallpaper" />
    <meta property="og:locale" content={t.locale} />
    <meta property="og:title" content={t.title} />
    <meta property="og:description" content={t.description} />
    <meta property="og:url" content={pageUrl[lang]} />
    <meta property="og:image" content="{siteUrl}/og-{lang}.jpg" />
    <meta property="og:image:width" content="1200" />
    <meta property="og:image:height" content="630" />
    <meta property="og:image:alt" content={t.title} />
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="theme-color" content="#090a0d" />
</svelte:head>

<header id="top" class="nav" class:scrolled>
    <div class="nav-inner">
        <a class="brand" href="#top">
            <img src="{asset('icon.png')}" alt="" width="24" height="24" />
            LiveWallpaper
        </a>
        <nav aria-label="Primary">
            <a class="section-link" href="#features">{t.nav.features}</a>
            <a class="section-link" href="#faq">{t.nav.faq}</a>
            <a href="#download">{t.nav.download}</a>
            <a href={repo}>{t.nav.github}</a>
            <!-- A full reload so the prerendered <html lang> of the other page applies; resolve() drops the trailing slash the static host expects. -->
            <a
                href={other === "ja" ? `${resolve("/ja")}/` : resolve("/")}
                hreflang={other}
                lang={other}
                data-sveltekit-reload
                onclick={() => localStorage.setItem("lang", other)}>{t.switchLabel}</a
            >
        </nav>
    </div>
</header>

<main>
    <section class="hero">
        <div class="hero-inner">
            <h1>{t.hero.title}</h1>
            <p class="lead">{t.hero.lead}</p>
            <div class="actions">
                <a class="btn primary" href="#download">{t.hero.primary}</a>
                <a class="btn ghost" href={repo}>
                    {t.hero.secondary}
                    {#if downloads !== undefined}
                        <span class="count" title={t.hero.downloads(downloads.toLocaleString(lang))}>
                            <svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M8 2.5v8M4.5 7 8 10.5 11.5 7M3 13.5h10" /></svg>
                            <span class="visually-hidden">{t.hero.downloads(downloads.toLocaleString(lang))}</span>
                            <span aria-hidden="true">{downloads.toLocaleString(lang)}</span>
                        </span>
                    {/if}
                </a>
            </div>
            <p class="meta">
                <a href="{repo}/releases/latest">v{release.version}</a> · {t.hero.meta}
            </p>
        </div>

        <div class="demo">
            <HeroVideo label={t.hero.videoLabel} />
        </div>
    </section>

    <Features {t} />

    <Screenshots {t} />

    <Faq {t} />

    <section id="download" class="download">
        <div class="download-inner">
            <h2>{t.download.title}</h2>
            <p class="lead">{t.download.lead}</p>
            <p class="latest">
                <a href="{repo}/releases/latest">{t.download.latest(release.version, release.date)}</a>
            </p>

            <div class="brew">
                <span class="brew-label">{t.download.brewLabel}</span>
                <div class="brew-row">
                    <code>{brewCommand}</code>
                    <CopyButton text={brewCommand} label={t.download.copy} done={t.download.copied} />
                </div>
            </div>

            <div class="actions">
                <a class="btn primary" href="{repo}/releases/latest">{t.download.dmg}</a>
                <a class="btn ghost" href="{repo}/blob/main/{lang === 'ja' ? 'README.ja.md' : 'README.md'}">{t.download.readme}</a>
            </div>

            <aside class="note">
                <strong>{t.download.noteTitle}</strong>
                <p>{t.download.note}</p>
            </aside>
        </div>
    </section>
</main>

<footer class="footer">
    <div class="footer-inner">
        <span class="brand small">
            <img src="{asset('icon.png')}" alt="" width="18" height="18" />
            LiveWallpaper
        </span>
        <nav aria-label="Footer">
            <a href={repo}>{t.footer.github}</a>
            <a href="{repo}/releases">{t.footer.releases}</a>
            <a href="{repo}/blob/main/LICENSE">{t.footer.license}</a>
            <a href={donateUrl}>{t.footer.donate}</a>
        </nav>
        <p>
            {t.footer.unofficial}
            <a href={videoSource}>{t.footer.videoCredit}</a>
            <a href={photoSource}>{t.footer.photoCredit}</a>
            <a href={cloudsSource}>{t.footer.cloudsCredit}</a>
        </p>
    </div>
</footer>

<style>
    .nav {
        position: sticky;
        top: 0;
        z-index: 50;
        border-bottom: 1px solid transparent;
        transition:
            background 0.2s,
            border-color 0.2s;
    }

    .nav.scrolled {
        border-color: var(--line);
        background: rgb(9 10 13 / 0.9);
        backdrop-filter: blur(16px);
    }

    .nav-inner {
        display: flex;
        align-items: center;
        justify-content: space-between;
        max-width: var(--max);
        height: 56px;
        margin: 0 auto;
        padding: 0 24px;
    }

    .brand {
        display: inline-flex;
        align-items: center;
        gap: 9px;
        font-size: 15px;
        font-weight: 600;
        letter-spacing: -0.01em;
        text-decoration: none;
    }

    .brand img {
        border-radius: 6px;
    }

    nav {
        display: flex;
        align-items: center;
        gap: 22px;
        font-size: 13.5px;
    }

    nav a {
        white-space: nowrap;
        color: var(--muted);
        text-decoration: none;
        transition: color 0.15s;
    }

    nav a:hover {
        color: var(--fg);
    }

    .hero {
        padding: 56px 24px 80px;
    }

    .hero-inner {
        max-width: 720px;
        margin: 0 auto;
        text-align: center;
    }

    h1 {
        font-size: clamp(32px, 5vw, 52px);
        line-height: 1.15;
        letter-spacing: -0.03em;
    }

    .lead {
        margin: 16px auto 0;
        max-width: 58ch;
        color: var(--muted);
        font-size: clamp(15px, 1.8vw, 17px);
        line-height: 1.65;
    }

    .actions {
        display: flex;
        flex-wrap: wrap;
        justify-content: center;
        gap: 10px;
        margin-top: 24px;
    }

    .meta {
        margin-top: 14px;
        font-size: 12.5px;
        color: var(--muted);
    }

    .meta a {
        color: var(--fg);
        text-decoration: none;
        font-variant-numeric: tabular-nums;
    }

    .meta a:hover {
        text-decoration: underline;
        text-underline-offset: 2px;
    }

    .count {
        display: inline-flex;
        align-items: center;
        gap: 4px;
        margin-left: 8px;
        padding-left: 9px;
        border-left: 1px solid var(--line-strong);
        color: var(--muted);
        font-weight: 500;
        font-variant-numeric: tabular-nums;
    }

    .visually-hidden {
        position: absolute;
        width: 1px;
        height: 1px;
        overflow: hidden;
        clip-path: inset(50%);
        white-space: nowrap;
    }

    .btn {
        display: inline-flex;
        align-items: center;
        padding: 10px 20px;
        border-radius: 10px;
        font-size: 14px;
        font-weight: 600;
        text-decoration: none;
        transition: background 0.15s;
    }

    .btn.primary {
        background: var(--fg);
        color: #000;
    }

    .btn.primary:hover {
        background: #fff;
    }

    .btn.ghost {
        border: 1px solid var(--line-strong);
        background: rgb(255 255 255 / 0.04);
    }

    .btn.ghost:hover {
        background: rgb(255 255 255 / 0.09);
    }

    .demo {
        max-width: 960px;
        margin: 48px auto 0;
    }

    .download {
        padding: 88px 24px;
        border-top: 1px solid var(--line);
    }

    .download-inner {
        max-width: 640px;
        margin: 0 auto;
    }

    .download h2 {
        font-size: clamp(24px, 3.2vw, 32px);
        line-height: 1.2;
        letter-spacing: -0.02em;
    }

    .download .lead {
        margin: 10px 0 0;
    }

    .latest {
        margin-top: 6px;
        font-size: 13px;
    }

    .latest a {
        color: var(--accent);
        text-decoration: none;
    }

    .latest a:hover {
        text-decoration: underline;
        text-underline-offset: 2px;
    }

    .download .actions {
        justify-content: flex-start;
    }

    .brew {
        margin-top: 24px;
    }

    .brew-label {
        font-size: 13px;
        font-weight: 500;
        color: var(--muted);
    }

    .brew-row {
        display: flex;
        align-items: center;
        gap: 12px;
        margin-top: 6px;
        padding: 9px 10px 9px 14px;
        border: 1px solid var(--line-strong);
        border-radius: 10px;
        background: var(--bg-raised);
    }

    .brew-row code {
        flex: 1;
        overflow-x: auto;
        font-family: var(--mono);
        font-size: 13px;
        white-space: nowrap;
        color: var(--fg);
    }

    .note {
        margin-top: 24px;
        padding: 16px 18px;
        border: 1px solid var(--line);
        border-radius: 12px;
        background: var(--bg-raised);
        font-size: 13.5px;
        line-height: 1.6;
    }

    .note p {
        margin-top: 6px;
        color: var(--muted);
    }

    .footer {
        border-top: 1px solid var(--line);
        padding: 28px 24px 44px;
    }

    .footer-inner {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        justify-content: space-between;
        gap: 12px 24px;
        max-width: var(--max);
        margin: 0 auto;
        font-size: 13px;
        color: var(--muted);
    }

    .footer-inner p {
        flex-basis: 100%;
        font-size: 12px;
    }

    .footer-inner p a {
        margin-left: 12px;
        text-decoration: underline;
        text-underline-offset: 2px;
    }

    .brand.small {
        color: var(--fg);
        font-size: 13.5px;
    }

    @media (max-width: 780px) {
        .nav-inner {
            padding: 0 16px;
        }

        nav {
            gap: 14px;
        }

        .section-link {
            display: none;
        }

        .hero {
            padding: 36px 16px 56px;
        }

        .download {
            padding: 64px 16px;
        }

        .demo {
            margin-top: 32px;
        }
    }
</style>
