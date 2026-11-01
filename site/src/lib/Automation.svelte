<script lang="ts">
    import CopyButton from "./CopyButton.svelte";
    import type { Dict } from "./i18n";
    import { reveal } from "./reveal";

    let { t }: { t: Dict } = $props();

    // Sunrise 06:00 / sunset 18:00 as fractions of the day, purely illustrative.
    const sunrise = 6 / 24;
    const sunset = 18 / 24;

    const urls = ["livewallpaper://next", "livewallpaper://toggle-pause", "livewallpaper://set?name=Ocean"];
    const urlText = urls.map((u) => `open "${u}"`).join("\n");
</script>

<section id="automation" class="section">
    <div class="inner">
        <header>
            <p class="eyebrow" use:reveal>{t.automation.eyebrow}</p>
            <h2 use:reveal={80}>{t.automation.title[0]} {t.automation.title[1]}</h2>
            <p class="lead" use:reveal={140}>{t.automation.lead}</p>
        </header>

        <div class="panels">
            <article class="panel wide" use:reveal>
                <h3>{t.automation.scheduleTitle}</h3>
                <p class="note">{t.automation.scheduleNote}</p>

                <div class="timeline" role="img" aria-label={t.automation.scheduleNote}>
                    <div class="bar">
                        <span class="seg night" style="left:0; width:{sunrise * 100}%"></span>
                        <span class="seg day" style="left:{sunrise * 100}%; width:{(sunset - sunrise) * 100}%"></span>
                        <span class="seg night" style="left:{sunset * 100}%; width:{(1 - sunset) * 100}%"></span>
                        <span class="mark" style="left:{sunrise * 100}%"><em>{t.automation.sunrise}</em></span>
                        <span class="mark" style="left:{sunset * 100}%"><em>{t.automation.sunset}</em></span>
                    </div>
                    <div class="ticks"><span>0:00</span><span>6:00</span><span>12:00</span><span>18:00</span><span>24:00</span></div>
                    <div class="legend">
                        <span><i class="night"></i>{t.automation.segments.night}</span>
                        <span><i class="day"></i>{t.automation.segments.day}</span>
                    </div>
                </div>
            </article>

            <article class="panel" use:reveal={80}>
                <h3>{t.automation.shortcutsTitle}</h3>
                <ul class="shortcuts">
                    {#each t.automation.shortcuts as s (s.label)}
                        <li>
                            <span class="keys">
                                {#each s.keys as k, i (i)}<kbd>{k}</kbd>{/each}
                            </span>
                            <span>{s.label}</span>
                        </li>
                    {/each}
                </ul>
            </article>

            <article class="panel" use:reveal={160}>
                <div class="row">
                    <h3>{t.automation.urlTitle}</h3>
                    <CopyButton text={urlText} label={t.automation.copy} done={t.automation.copied} />
                </div>
                <p class="note">{t.automation.urlNote}</p>
                <pre><code>{#each urls as u (u)}<span class="cmd">open</span> <span class="str">"{u}"</span>
{/each}</code></pre>
            </article>
        </div>
    </div>
</section>

<style>
    .section {
        padding: 120px 24px;
        border-top: 1px solid var(--line);
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

    .lead {
        margin-top: 18px;
        max-width: 52ch;
        color: var(--muted);
        font-size: 17px;
    }

    .panels {
        display: grid;
        grid-template-columns: 1fr 1fr;
        gap: 14px;
        margin-top: 56px;
    }

    .panel {
        padding: 28px;
        border: 1px solid var(--line);
        border-radius: var(--radius);
        background: var(--bg-raised);
        min-width: 0;
    }

    .panel.wide {
        grid-column: 1 / -1;
    }

    h3 {
        font-size: 18px;
        letter-spacing: -0.01em;
    }

    .note {
        margin-top: 4px;
        font-size: 14px;
        color: var(--muted);
    }

    .row {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 12px;
    }

    .timeline {
        margin-top: 32px;
    }

    .bar {
        position: relative;
        height: 44px;
        border-radius: 12px;
        background: #12141a;
    }

    .seg {
        position: absolute;
        top: 0;
        bottom: 0;
    }

    .seg.night,
    .legend .night {
        background: linear-gradient(90deg, #2a1d63, #5a3aa8);
    }

    .seg.day,
    .legend .day {
        background: linear-gradient(90deg, #ffb25b, #ff7a6b);
    }

    .seg:first-child {
        border-radius: 12px 0 0 12px;
    }

    .seg:nth-child(3) {
        border-radius: 0 12px 12px 0;
    }

    .mark {
        position: absolute;
        top: -6px;
        bottom: -6px;
        width: 2px;
        background: #fff;
        box-shadow: 0 0 12px rgb(255 255 255 / 0.6);
    }

    .mark em {
        position: absolute;
        bottom: calc(100% + 6px);
        left: 50%;
        transform: translateX(-50%);
        font-size: 12px;
        font-style: normal;
        color: var(--fg);
        white-space: nowrap;
    }

    .ticks {
        display: flex;
        justify-content: space-between;
        margin-top: 10px;
        font-size: 11px;
        font-variant-numeric: tabular-nums;
        color: var(--muted);
    }

    .legend {
        display: flex;
        flex-wrap: wrap;
        gap: 22px;
        margin-top: 18px;
        font-size: 13px;
        color: var(--muted);
    }

    .legend span {
        display: inline-flex;
        align-items: center;
        gap: 8px;
    }

    .legend i {
        width: 12px;
        height: 12px;
        border-radius: 4px;
    }

    .timeline {
        padding-top: 20px;
    }

    .shortcuts {
        display: grid;
        gap: 14px;
        margin: 22px 0 0;
        padding: 0;
        list-style: none;
    }

    .shortcuts li {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 16px;
        font-size: 14px;
        color: var(--muted);
    }

    .keys {
        display: inline-flex;
        flex: none;
        gap: 4px;
    }

    kbd {
        display: grid;
        place-items: center;
        min-width: 28px;
        height: 28px;
        padding: 0 6px;
        border: 1px solid var(--line-strong);
        border-bottom-width: 2px;
        border-radius: 7px;
        background: rgb(255 255 255 / 0.05);
        color: var(--fg);
        font-family: var(--font);
        font-size: 13px;
    }

    pre {
        margin: 18px 0 0;
        padding: 16px;
        overflow-x: auto;
        border-radius: 12px;
        background: #090a0e;
        border: 1px solid var(--line);
        font-family: var(--mono);
        font-size: 12.5px;
        line-height: 1.9;
    }

    .cmd {
        color: var(--accent-2);
    }

    .str {
        color: #9ec2ff;
    }

    @media (max-width: 900px) {
        .panels {
            grid-template-columns: 1fr;
        }
    }

    @media (max-width: 560px) {
        .section {
            padding: 80px 16px;
        }

        .shortcuts li {
            flex-direction: column;
            align-items: flex-start;
            gap: 6px;
        }

        .panel {
            padding: 22px;
        }
    }
</style>
