<script lang="ts">
    import type { Dict } from "./i18n";

    let { t }: { t: Dict } = $props();
</script>

<section id="faq" class="section">
    <div class="inner">
        <h2>{t.faq.title}</h2>

        <div class="list">
            {#each t.faq.items as item (item.q)}
                <details>
                    <summary>{item.q}</summary>
                    <p>{item.a}</p>
                </details>
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
        max-width: 760px;
        margin: 0 auto;
    }

    h2 {
        font-size: clamp(24px, 3.2vw, 32px);
        line-height: 1.2;
        letter-spacing: -0.02em;
    }

    .list {
        margin-top: 24px;
        border-top: 1px solid var(--line);
    }

    details {
        border-bottom: 1px solid var(--line);
    }

    summary {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 16px;
        padding: 18px 2px;
        font-size: 15px;
        font-weight: 600;
        list-style: none;
        cursor: pointer;
    }

    summary::-webkit-details-marker {
        display: none;
    }

    summary::after {
        content: "";
        flex: none;
        width: 8px;
        height: 8px;
        margin-right: 4px;
        border-right: 1.5px solid var(--muted);
        border-bottom: 1.5px solid var(--muted);
        transform: translateY(-2px) rotate(45deg);
        transition: transform 0.2s;
    }

    details[open] summary::after {
        transform: translateY(2px) rotate(-135deg);
    }

    details p {
        padding: 0 2px 20px;
        max-width: 64ch;
        color: var(--muted);
        font-size: 14px;
        line-height: 1.75;
    }

    @media (max-width: 560px) {
        .section {
            padding: 64px 16px;
        }
    }
</style>
