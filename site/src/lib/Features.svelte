<script lang="ts">
    import type { Dict } from "./i18n";
    import Icon from "./Icon.svelte";
    import { reveal } from "./reveal";

    let { t }: { t: Dict } = $props();

    // Spans fill a 4-column grid exactly: 2+1+1, 1+2+1, 2+2.
    const spans: Record<string, number> = { media: 2, cursor: 2, saver: 2, store: 2 };

    function glow(e: PointerEvent) {
        const el = e.currentTarget as HTMLElement;
        const rect = el.getBoundingClientRect();
        el.style.setProperty("--mx", `${e.clientX - rect.left}px`);
        el.style.setProperty("--my", `${e.clientY - rect.top}px`);
    }
</script>

<section id="features" class="section">
    <div class="inner">
        <p class="eyebrow" use:reveal>{t.features.eyebrow}</p>
        <h2 use:reveal={80}>{t.features.title}</h2>

        <div class="grid">
            {#each t.features.items as item, i (item.id)}
                <article class="card" style="--span: {spans[item.id] ?? 1}" onpointermove={glow} use:reveal={(i % 4) * 70}>
                    <span class="icon"><Icon name={item.id} /></span>
                    <h3>{item.title}</h3>
                    <p>{item.body}</p>
                </article>
            {/each}
        </div>
    </div>
</section>

<style>
    .section {
        padding: 120px 24px;
    }

    .inner {
        max-width: var(--max);
        margin: 0 auto;
    }

    .eyebrow {
        font-size: 13px;
        font-weight: 600;
        letter-spacing: 0.14em;
        text-transform: uppercase;
        background: var(--gradient);
        -webkit-background-clip: text;
        background-clip: text;
        color: transparent;
        width: fit-content;
    }

    h2 {
        margin-top: 12px;
        font-size: clamp(30px, 4.6vw, 52px);
        line-height: 1.15;
        letter-spacing: -0.025em;
    }

    .grid {
        display: grid;
        grid-template-columns: repeat(4, 1fr);
        gap: 14px;
        margin-top: 56px;
    }

    .card {
        position: relative;
        grid-column: span var(--span);
        overflow: hidden;
        padding: 28px;
        min-height: 210px;
        border: 1px solid var(--line);
        border-radius: var(--radius);
        background: var(--bg-raised);
    }

    .card::before {
        content: "";
        position: absolute;
        inset: 0;
        background: radial-gradient(360px circle at var(--mx, 50%) var(--my, 0%), rgb(80 140 255 / 0.16), transparent 60%);
        opacity: 0;
        transition: opacity 0.3s;
        pointer-events: none;
    }

    .card:hover::before {
        opacity: 1;
    }

    .icon {
        display: grid;
        place-items: center;
        width: 42px;
        height: 42px;
        margin-bottom: 40px;
        border: 1px solid var(--line-strong);
        border-radius: 12px;
        background: rgb(255 255 255 / 0.04);
        color: #cfe0ff;
    }

    h3 {
        font-size: 19px;
        letter-spacing: -0.01em;
    }

    .card p {
        margin-top: 8px;
        max-width: 46ch;
        font-size: 15px;
        color: var(--muted);
    }

    @media (max-width: 900px) {
        .grid {
            grid-template-columns: repeat(2, 1fr);
        }

        .card {
            grid-column: span min(var(--span), 2);
        }
    }

    @media (max-width: 560px) {
        .section {
            padding: 80px 16px;
        }

        .grid {
            grid-template-columns: 1fr;
        }

        .card {
            grid-column: auto;
            min-height: 0;
        }

        .icon {
            margin-bottom: 24px;
        }
    }
</style>
