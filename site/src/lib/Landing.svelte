<script lang="ts">
    import { asset, resolve } from "$app/paths";
    import Automation from "./Automation.svelte";
    import CopyButton from "./CopyButton.svelte";
    import Desktop from "./Desktop.svelte";
    import Features from "./Features.svelte";
    import { brewCommand, dictionaries, repo, siteUrl, type Lang } from "./i18n";
    import Light from "./Light.svelte";
    import { reveal } from "./reveal";

    let { lang }: { lang: Lang } = $props();

    const t = $derived(dictionaries[lang]);
    const other = $derived<Lang>(lang === "ja" ? "en" : "ja");
    const here = $derived(lang === "ja" ? `${siteUrl}/` : `${siteUrl}/en/`);
    const switchHref = $derived(other === "ja" ? resolve("/") : resolve("/en"));

    let scrolled = $state(false);
</script>

<svelte:window onscroll={() => (scrolled = window.scrollY > 8)} />

<svelte:head>
    <title>{t.title}</title>
    <meta name="description" content={t.description} />
    <link rel="canonical" href={here} />
    <link rel="alternate" hreflang="ja" href="{siteUrl}/" />
    <link rel="alternate" hreflang="en" href="{siteUrl}/en/" />
    <link rel="alternate" hreflang="x-default" href="{siteUrl}/" />
    <meta property="og:type" content="website" />
    <meta property="og:title" content={t.title} />
    <meta property="og:description" content={t.description} />
    <meta property="og:url" content={here} />
    <meta property="og:image" content="{siteUrl}/icon.png" />
    <meta name="twitter:card" content="summary" />
    <meta name="theme-color" content="#07080b" />
</svelte:head>

<header class="nav" class:scrolled>
    <div class="nav-inner">
        <a class="brand" href={lang === "ja" ? resolve("/") : resolve("/en")}>
            <img src="{asset('icon.png')}" alt="" width="26" height="26" />
            LiveWallpaper
        </a>
        <nav aria-label="Primary">
            <a href="#features">{t.nav.features}</a>
            <a href="#light">{t.nav.light}</a>
            <a href="#automation">{t.nav.automation}</a>
            <a class="lang" href={switchHref} hreflang={other}>{t.switchLabel}</a>
            <a class="cta" href="#download">{t.nav.download}</a>
        </nav>
    </div>
</header>

<main>
    <section class="hero">
        <div class="glow" aria-hidden="true"></div>
        <div class="hero-inner">
            <p class="pill" use:reveal>{t.hero.eyebrow}</p>
            <h1 use:reveal={80}>
                <span>{t.hero.title[0]}</span>
                <span class="grad">{t.hero.title[1]}</span>
            </h1>
            <p class="lead" use:reveal={160}>{t.hero.lead}</p>
            <div class="actions" use:reveal={240}>
                <a class="btn primary" href="#download">{t.hero.primary}</a>
                <a class="btn ghost" href={repo}>{t.hero.secondary}</a>
            </div>
        </div>

        <div class="demo" use:reveal={320}>
            <Desktop {t} />
        </div>
    </section>

    <Features {t} />
    <Light {t} />
    <Automation {t} />

    <section class="langs">
        <div class="langs-inner">
            <p class="eyebrow" use:reveal>{t.languages.eyebrow}</p>
            <h2 use:reveal={80}>{t.languages.title}</h2>
            <p class="lead" use:reveal={140}>{t.languages.lead}</p>
            <ul class="chips" use:reveal={200}>
                {#each t.languages.list as name (name)}
                    <li>{name}</li>
                {/each}
            </ul>
        </div>
    </section>

    <section id="download" class="download">
        <div class="download-inner" use:reveal>
            <h2>{t.download.title[0]}<br /><span class="grad">{t.download.title[1]}</span></h2>
            <p class="lead">{t.download.lead}</p>
            <div class="actions center">
                <a class="btn primary" href="{repo}/releases/latest">{t.download.dmg}</a>
                <a class="btn ghost" href={repo}>{t.hero.secondary}</a>
            </div>

            <div class="brew">
                <span class="brew-label">{t.download.brewLabel}</span>
                <div class="brew-row">
                    <code>{brewCommand}</code>
                    <CopyButton text={brewCommand} label={t.download.copy} done={t.download.copied} />
                </div>
            </div>

            <aside class="note">
                <strong>{t.download.noteTitle}</strong>
                <p>{t.download.note}</p>
                <a href="{repo}/blob/main/{lang === 'ja' ? 'README.ja.md' : 'README.md'}">{t.download.readme} →</a>
            </aside>
        </div>
    </section>
</main>

<footer class="footer">
    <div class="footer-inner">
        <span class="brand small">
            <img src="{asset('icon.png')}" alt="" width="20" height="20" />
            LiveWallpaper
        </span>
        <nav aria-label="Footer">
            <a href={repo}>{t.footer.github}</a>
            <a href="{repo}/releases">{t.footer.releases}</a>
            <a href="{repo}/blob/main/LICENSE">{t.footer.license}</a>
        </nav>
        <p>{t.footer.unofficial}</p>
    </div>
</footer>

<style>
    .nav {
        position: sticky;
        top: 0;
        z-index: 50;
        border-bottom: 1px solid transparent;
        transition:
            background 0.3s,
            border-color 0.3s,
            backdrop-filter 0.3s;
    }

    .nav.scrolled {
        border-color: var(--line);
        background: rgb(7 8 11 / 0.88);
        backdrop-filter: blur(20px) saturate(1.6);
    }

    .nav-inner {
        display: flex;
        align-items: center;
        justify-content: space-between;
        max-width: var(--max);
        height: 60px;
        margin: 0 auto;
        padding: 0 24px;
    }

    .brand {
        display: inline-flex;
        align-items: center;
        gap: 10px;
        font-weight: 600;
        letter-spacing: -0.01em;
        text-decoration: none;
    }

    .brand img {
        border-radius: 7px;
    }

    nav {
        display: flex;
        align-items: center;
        gap: 26px;
        font-size: 14px;
    }

    nav a {
        color: var(--muted);
        text-decoration: none;
        transition: color 0.2s;
    }

    nav a:hover {
        color: var(--fg);
    }

    nav .cta {
        padding: 7px 16px;
        border-radius: 999px;
        background: var(--fg);
        color: #000;
        font-weight: 600;
    }

    nav .cta:hover {
        color: #000;
        background: #fff;
    }

    .hero {
        position: relative;
        padding: 72px 24px 100px;
        overflow: hidden;
    }

    .glow {
        position: absolute;
        top: -200px;
        left: 50%;
        width: 1100px;
        height: 700px;
        transform: translateX(-50%);
        background:
            radial-gradient(closest-side at 30% 40%, rgb(46 230 166 / 0.22), transparent),
            radial-gradient(closest-side at 70% 35%, rgb(166 120 255 / 0.22), transparent),
            radial-gradient(closest-side at 50% 70%, rgb(59 139 255 / 0.2), transparent);
        filter: blur(40px);
        pointer-events: none;
    }

    .hero-inner {
        position: relative;
        max-width: 860px;
        margin: 0 auto;
        text-align: center;
    }

    .pill {
        display: inline-block;
        padding: 6px 16px;
        border: 1px solid var(--line-strong);
        border-radius: 999px;
        background: rgb(255 255 255 / 0.04);
        font-size: 13px;
        color: var(--muted);
    }

    h1 {
        margin-top: 26px;
        font-size: clamp(44px, 8.2vw, 96px);
        line-height: 1.05;
        letter-spacing: -0.04em;
    }

    h1 span {
        display: block;
    }

    .grad {
        background: var(--gradient);
        -webkit-background-clip: text;
        background-clip: text;
        color: transparent;
    }

    .lead {
        margin: 24px auto 0;
        max-width: 56ch;
        color: var(--muted);
        font-size: clamp(16px, 2vw, 19px);
    }

    .actions {
        display: flex;
        flex-wrap: wrap;
        justify-content: center;
        gap: 12px;
        margin-top: 36px;
    }

    .btn {
        display: inline-flex;
        align-items: center;
        padding: 14px 28px;
        border-radius: 999px;
        font-size: 15px;
        font-weight: 600;
        text-decoration: none;
        transition:
            transform 0.2s,
            background 0.2s,
            box-shadow 0.2s;
    }

    .btn:hover {
        transform: translateY(-1px);
    }

    .btn.primary {
        background: var(--fg);
        color: #000;
        box-shadow: 0 10px 40px -8px rgb(120 160 255 / 0.55);
    }

    .btn.ghost {
        border: 1px solid var(--line-strong);
        background: rgb(255 255 255 / 0.05);
    }

    .btn.ghost:hover {
        background: rgb(255 255 255 / 0.1);
    }

    .demo {
        position: relative;
        max-width: 1000px;
        margin: 72px auto 0;
    }

    .langs {
        padding: 120px 24px;
        border-top: 1px solid var(--line);
    }

    .langs-inner {
        max-width: 860px;
        margin: 0 auto;
        text-align: center;
    }

    .eyebrow {
        margin: 0 auto;
        width: fit-content;
        font-size: 13px;
        font-weight: 600;
        letter-spacing: 0.14em;
        text-transform: uppercase;
        background: var(--gradient);
        -webkit-background-clip: text;
        background-clip: text;
        color: transparent;
    }

    h2 {
        margin-top: 12px;
        font-size: clamp(30px, 4.6vw, 52px);
        line-height: 1.15;
        letter-spacing: -0.025em;
    }

    .chips {
        display: flex;
        flex-wrap: wrap;
        justify-content: center;
        gap: 10px;
        margin: 44px 0 0;
        padding: 0;
        list-style: none;
    }

    .chips li {
        padding: 9px 18px;
        border: 1px solid var(--line-strong);
        border-radius: 999px;
        background: rgb(255 255 255 / 0.04);
        font-size: 15px;
    }

    .download {
        position: relative;
        padding: 120px 24px;
        border-top: 1px solid var(--line);
        background: radial-gradient(800px 420px at 50% 0%, rgb(59 139 255 / 0.16), transparent 70%), var(--bg);
    }

    .download-inner {
        max-width: 640px;
        margin: 0 auto;
        text-align: center;
    }

    .download h2 {
        font-size: clamp(40px, 6.4vw, 72px);
        line-height: 1.1;
        letter-spacing: -0.035em;
    }

    .brew {
        margin-top: 44px;
        text-align: left;
    }

    .brew-label {
        font-size: 13px;
        color: var(--muted);
    }

    .brew-row {
        display: flex;
        align-items: center;
        gap: 12px;
        margin-top: 8px;
        padding: 10px 10px 10px 18px;
        border: 1px solid var(--line-strong);
        border-radius: 14px;
        background: #090a0e;
    }

    .brew-row code {
        flex: 1;
        overflow-x: auto;
        font-family: var(--mono);
        font-size: 13px;
        white-space: nowrap;
        color: #cfe0ff;
    }

    .note {
        margin-top: 28px;
        padding: 20px 22px;
        border: 1px solid var(--line);
        border-radius: 16px;
        background: var(--bg-raised);
        text-align: left;
        font-size: 14px;
    }

    .note p {
        margin-top: 6px;
        color: var(--muted);
    }

    .note a {
        display: inline-block;
        margin-top: 12px;
        color: var(--accent);
        text-decoration: none;
    }

    .footer {
        border-top: 1px solid var(--line);
        padding: 36px 24px 56px;
    }

    .footer-inner {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        justify-content: space-between;
        gap: 16px 32px;
        max-width: var(--max);
        margin: 0 auto;
        font-size: 13px;
        color: var(--muted);
    }

    .footer-inner p {
        flex-basis: 100%;
        font-size: 12px;
    }

    .brand.small {
        color: var(--fg);
        font-size: 14px;
    }

    @media (max-width: 780px) {
        .nav-inner {
            padding: 0 16px;
        }

        nav {
            gap: 16px;
        }

        nav a:nth-child(-n + 3) {
            display: none;
        }

        .hero {
            padding: 40px 16px 72px;
        }

        .langs,
        .download {
            padding: 80px 16px;
        }

        .demo {
            margin-top: 48px;
        }
    }
</style>
