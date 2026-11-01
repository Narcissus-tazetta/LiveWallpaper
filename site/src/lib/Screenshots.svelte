<script lang="ts">
    import { asset } from "$app/paths";
    import type { Dict } from "./i18n";

    let { t }: { t: Dict } = $props();

    // The scene editor is its own, larger window, so it gets more room than the settings window.
    const sizes: Record<string, { width: number; height: number }> = {
        library: { width: 1560, height: 1144 },
        edit: { width: 1560, height: 1144 },
        scene: { width: 2000, height: 1331 },
    };

    let selected = $state(0);
    const item = $derived(t.screens.items[selected]);
</script>

<section id="screens" class="section">
    <div class="inner">
        <h2>{t.screens.title}</h2>

        <div class="tabs" role="tablist" aria-label={t.screens.title}>
            {#each t.screens.items as entry, index (entry.id)}
                <button
                    type="button"
                    role="tab"
                    id="tab-{entry.id}"
                    aria-selected={index === selected}
                    aria-controls="panel-screens"
                    onclick={() => (selected = index)}
                >
                    {entry.label}
                </button>
            {/each}
        </div>

        <div class="panel" role="tabpanel" id="panel-screens" aria-labelledby="tab-{item.id}">
            <img
                src={asset(`screens/${t.lang}-${item.id}.webp` as Parameters<typeof asset>[0])}
                alt="{t.screens.title}: {item.label}"
                class:wide={item.id === "scene"}
                width={sizes[item.id].width}
                height={sizes[item.id].height}
                loading="lazy"
            />
            <p>{item.caption}</p>
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

    .tabs {
        display: inline-flex;
        gap: 4px;
        margin-top: 24px;
        padding: 4px;
        border: 1px solid var(--line);
        border-radius: 10px;
        background: var(--bg-raised);
    }

    .tabs button {
        padding: 6px 14px;
        border: 0;
        border-radius: 7px;
        background: none;
        color: var(--muted);
        font: inherit;
        font-size: 13.5px;
        cursor: pointer;
        transition:
            background 0.15s,
            color 0.15s;
    }

    .tabs button:hover {
        color: var(--fg);
    }

    .tabs button[aria-selected="true"] {
        background: rgb(255 255 255 / 0.1);
        color: var(--fg);
    }

    .panel {
        margin-top: 24px;
        text-align: center;
    }

    img {
        display: block;
        width: min(100%, 780px);
        height: auto;
        margin: 0 auto;
        filter: drop-shadow(0 30px 50px rgb(0 0 0 / 0.55));
    }

    img.wide {
        width: min(100%, 1000px);
    }

    p {
        max-width: 60ch;
        margin: 28px auto 0;
        color: var(--muted);
        font-size: 14px;
        line-height: 1.65;
    }

    @media (max-width: 560px) {
        .section {
            padding: 64px 16px;
        }
    }
</style>
