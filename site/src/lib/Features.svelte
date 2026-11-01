<script lang="ts">
    import type { Dict } from "./i18n";
    import Icon from "./Icon.svelte";

    let { t }: { t: Dict } = $props();

    // Spans fill a 4-column grid: 2+1+1, 1+2+1, 2+2.
    const spans: Record<string, number> = { media: 2, power: 2, control: 2, store: 2 };
</script>

<section id="features" class="section">
    <div class="inner">
        <h2>{t.features.title}</h2>

        <div class="grid">
            {#each t.features.items as item (item.id)}
                <article class="card" style="--span: {spans[item.id] ?? 1}">
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
        padding: 88px 24px;
        border-top: 1px solid var(--line);
    }

    .inner {
        max-width: var(--max);
        margin: 0 auto;
    }

    h2 {
        font-size: clamp(24px, 3.2vw, 32px);
        line-height: 1.2;
        letter-spacing: -0.02em;
    }

    .grid {
        display: grid;
        grid-template-columns: repeat(4, 1fr);
        gap: 12px;
        margin-top: 32px;
    }

    .card {
        grid-column: span var(--span);
        padding: 24px;
        border: 1px solid var(--line);
        border-radius: var(--radius);
        background: var(--bg-raised);
    }

    .icon {
        display: grid;
        place-items: center;
        width: 36px;
        height: 36px;
        margin-bottom: 18px;
        border: 1px solid var(--line-strong);
        border-radius: 9px;
        background: rgb(255 255 255 / 0.03);
        color: var(--fg);
    }

    h3 {
        font-size: 16px;
        letter-spacing: -0.01em;
    }

    .card p {
        margin-top: 8px;
        max-width: 60ch;
        font-size: 14px;
        line-height: 1.65;
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
            padding: 64px 16px;
        }

        .grid {
            grid-template-columns: 1fr;
        }

        .card {
            grid-column: auto;
            padding: 20px;
        }
    }
</style>
