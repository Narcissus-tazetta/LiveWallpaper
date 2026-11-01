<script lang="ts">
    import type { Dict } from "./i18n";
    import Icon from "./Icon.svelte";

    let { t }: { t: Dict } = $props();
</script>

<section id="features" class="section">
    <div class="inner">
        <header>
            <p class="eyebrow">{t.features.title}</p>
            <h2>{t.features.headline}</h2>
            <p class="lead">{t.features.lead}</p>
        </header>

        <dl class="stats">
            {#each t.features.stats as stat (stat.label)}
                <div>
                    <dt>{stat.label}</dt>
                    <dd>{stat.value}</dd>
                </div>
            {/each}
        </dl>
        <p class="note">{t.features.statsNote}</p>

        <div class="grid">
            {#each t.features.items as item (item.id)}
                <article>
                    <span class="icon"><Icon name={item.id} size={20} /></span>
                    <h3>{item.title}</h3>
                    <p>{item.body}</p>
                    <p class="spec">{item.tags.join(" · ")}</p>
                </article>
            {/each}
        </div>

        <ul class="more">
            {#each t.features.more as item (item.id)}
                <li>
                    <span class="more-icon"><Icon name={item.id} size={18} /></span>
                    <span>
                        <strong>{item.title}</strong>
                        <span class="more-body">{item.body}</span>
                    </span>
                </li>
            {/each}
        </ul>
    </div>
</section>

<style>
    .section {
        padding: 112px 24px;
        border-top: 1px solid var(--line);
    }

    .inner {
        max-width: var(--max);
        margin: 0 auto;
    }

    header {
        max-width: 680px;
    }

    .eyebrow {
        color: var(--accent);
        font-size: 13px;
        font-weight: 600;
        letter-spacing: 0.02em;
    }

    h2 {
        margin-top: 12px;
        font-size: clamp(28px, 4.2vw, 44px);
        line-height: 1.15;
        letter-spacing: -0.03em;
        text-wrap: balance;
    }

    .lead {
        margin-top: 16px;
        color: var(--muted);
        font-size: clamp(15px, 1.6vw, 17px);
        line-height: 1.7;
    }

    .stats {
        display: grid;
        grid-template-columns: repeat(3, 1fr);
        margin: 56px 0 0;
        border-top: 1px solid var(--line-strong);
        border-bottom: 1px solid var(--line);
    }

    .stats div {
        display: flex;
        flex-direction: column-reverse;
        gap: 6px;
        padding: 28px 24px 28px 0;
    }

    .stats div + div {
        padding-left: 24px;
        border-left: 1px solid var(--line);
    }

    dd {
        margin: 0;
        font-size: clamp(30px, 4vw, 44px);
        font-weight: 600;
        line-height: 1;
        letter-spacing: -0.03em;
        font-variant-numeric: tabular-nums;
    }

    dt {
        color: var(--muted);
        font-size: 13px;
    }

    .note {
        margin-top: 12px;
        color: var(--muted);
        font-size: 12px;
        opacity: 0.8;
    }

    .grid {
        display: grid;
        grid-template-columns: repeat(3, 1fr);
        gap: 48px 40px;
        margin-top: 72px;
    }

    article {
        padding-top: 24px;
        border-top: 1px solid var(--line);
    }

    .icon {
        display: block;
        margin-bottom: 16px;
        color: var(--accent);
    }

    h3 {
        font-size: 16px;
        letter-spacing: -0.01em;
    }

    article p {
        margin-top: 8px;
        font-size: 14px;
        line-height: 1.7;
        color: var(--muted);
    }

    article .spec {
        margin-top: 12px;
        color: #c4c7ce;
        font-size: 12.5px;
        line-height: 1.6;
    }

    .more {
        display: grid;
        grid-template-columns: repeat(3, 1fr);
        gap: 20px 40px;
        margin: 64px 0 0;
        padding: 28px 24px;
        border: 1px solid var(--line);
        border-radius: var(--radius);
        background: var(--bg-raised);
        list-style: none;
    }

    .more li {
        display: flex;
        align-items: flex-start;
        gap: 12px;
        font-size: 13.5px;
        line-height: 1.5;
    }

    .more-icon {
        flex: none;
        margin-top: 1px;
        color: var(--muted);
    }

    .more strong {
        display: block;
        font-weight: 600;
    }

    .more-body {
        color: var(--muted);
    }

    @media (max-width: 900px) {
        .grid,
        .more {
            grid-template-columns: repeat(2, 1fr);
        }
    }

    @media (max-width: 560px) {
        .section {
            padding: 72px 16px;
        }

        .stats {
            grid-template-columns: 1fr;
        }

        .stats div,
        .stats div + div {
            padding: 20px 0;
            border-left: 0;
        }

        .stats div + div {
            border-top: 1px solid var(--line);
        }

        .grid,
        .more {
            grid-template-columns: 1fr;
        }

        .grid {
            gap: 32px;
            margin-top: 48px;
        }
    }
</style>
