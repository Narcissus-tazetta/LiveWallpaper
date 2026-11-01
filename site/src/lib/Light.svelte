<script lang="ts">
    import type { Dict } from "./i18n";
    import Icon from "./Icon.svelte";
    import Shader from "./Shader.svelte";
    import { reveal } from "./reveal";

    let { t }: { t: Dict } = $props();

    let covered = $state(false);
    let reducedMotion = $state(false);

    $effect(() => {
        reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    });

    const still = { x: 0.5, y: 0.5 };
    const noRipple = { x: 0.5, y: 0.5, id: 0 };
</script>

<section id="light" class="section">
    <div class="inner">
        <div class="copy" use:reveal>
            <p class="eyebrow">{t.light.eyebrow}</p>
            <h2>{t.light.title[0]}<br />{t.light.title[1]}</h2>
            <p class="lead">{t.light.lead}</p>

            <ul class="points">
                {#each t.light.points as point (point.title)}
                    <li>
                        <h3>{point.title}</h3>
                        <p>{point.body}</p>
                    </li>
                {/each}
            </ul>
        </div>

        <div class="demo" use:reveal={120}>
            <div class="screen" class:covered>
                <div class="paper" aria-hidden="true">
                    <Shader preset={1} parallax={false} spotlight={false} pointer={still} ripple={noRipple} {reducedMotion} paused={covered} />
                </div>

                <div class="status" class:paused={covered} role="status">
                    <span class="dot"></span>
                    {covered ? t.light.statePaused : t.light.statePlaying}
                </div>

                <div class="window" aria-hidden="true">
                    <div class="titlebar">
                        <i></i><i></i><i></i>
                        <span>{t.light.windowTitle}</span>
                    </div>
                    <div class="lines"><b></b><b></b><b></b><b></b></div>
                </div>
            </div>

            <button type="button" class="toggle" onclick={() => (covered = !covered)} aria-pressed={covered}>
                <Icon name="multi" />
                {covered ? t.light.toggleUncover : t.light.toggleCover}
            </button>
        </div>
    </div>
</section>

<style>
    .section {
        padding: 120px 24px;
        border-top: 1px solid var(--line);
        background: radial-gradient(900px 500px at 85% 20%, rgb(166 120 255 / 0.1), transparent 70%), var(--bg);
    }

    .inner {
        display: grid;
        grid-template-columns: 1.05fr 1fr;
        gap: 72px;
        align-items: center;
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
        font-size: clamp(30px, 4.2vw, 48px);
        line-height: 1.18;
        letter-spacing: -0.025em;
    }

    .lead {
        margin-top: 20px;
        max-width: 48ch;
        color: var(--muted);
        font-size: 17px;
    }

    .points {
        display: grid;
        gap: 22px;
        margin: 44px 0 0;
        padding: 0;
        list-style: none;
    }

    .points li {
        padding-left: 18px;
        border-left: 1px solid var(--line-strong);
    }

    .points h3 {
        font-size: 16px;
    }

    .points p {
        margin-top: 4px;
        font-size: 14.5px;
        color: var(--muted);
    }

    .screen {
        position: relative;
        overflow: hidden;
        aspect-ratio: 4 / 3;
        border-radius: 18px;
        border: 1px solid var(--line-strong);
        background: #000;
        box-shadow: 0 40px 100px -30px rgb(0 0 0 / 0.8);
    }

    .paper {
        position: absolute;
        inset: 0;
        transition: filter 0.6s;
    }

    .covered .paper {
        filter: saturate(0.5) brightness(0.55);
    }

    .window {
        position: absolute;
        inset: 14% 10% 10% 10%;
        display: flex;
        flex-direction: column;
        overflow: hidden;
        border-radius: 12px;
        border: 1px solid rgb(255 255 255 / 0.1);
        background: #1b1c21;
        box-shadow: 0 30px 60px -10px rgb(0 0 0 / 0.6);
        transform: translateY(110%);
        transition: transform 0.7s cubic-bezier(0.2, 0.8, 0.2, 1);
    }

    .covered .window {
        transform: none;
    }

    .titlebar {
        display: flex;
        align-items: center;
        gap: 6px;
        padding: 10px 12px;
        font-size: 11px;
        color: var(--muted);
        background: #25262c;
    }

    .titlebar i {
        width: 9px;
        height: 9px;
        border-radius: 50%;
        background: #4a4b52;
    }

    .titlebar span {
        margin: 0 auto;
        padding-right: 40px;
    }

    .lines {
        display: grid;
        gap: 10px;
        padding: 18px;
    }

    .lines b {
        height: 8px;
        border-radius: 4px;
        background: #2d2e35;
    }

    .lines b:nth-child(2) {
        width: 80%;
    }

    .lines b:nth-child(3) {
        width: 92%;
    }

    .lines b:nth-child(4) {
        width: 55%;
    }

    .status {
        position: absolute;
        top: 12px;
        left: 12px;
        z-index: 2;
        display: flex;
        align-items: center;
        gap: 8px;
        padding: 6px 12px;
        border: 1px solid rgb(255 255 255 / 0.16);
        border-radius: 999px;
        background: rgb(10 12 16 / 0.6);
        backdrop-filter: blur(16px);
        font-size: 12px;
        font-weight: 500;
    }

    .dot {
        width: 7px;
        height: 7px;
        border-radius: 50%;
        background: var(--accent-2);
        box-shadow: 0 0 10px var(--accent-2);
        animation: pulse 1.8s ease-in-out infinite;
    }

    .paused .dot {
        background: #ffb340;
        box-shadow: none;
        animation: none;
    }

    @keyframes pulse {
        50% {
            opacity: 0.35;
        }
    }

    .toggle {
        display: inline-flex;
        align-items: center;
        gap: 10px;
        margin-top: 22px;
        padding: 11px 18px;
        border: 1px solid var(--line-strong);
        border-radius: 999px;
        background: rgb(255 255 255 / 0.06);
        color: var(--fg);
        font: inherit;
        font-size: 14px;
        cursor: pointer;
        transition: background 0.2s;
    }

    .toggle:hover {
        background: rgb(255 255 255 / 0.12);
    }

    .toggle :global(svg) {
        width: 18px;
        height: 18px;
    }

    @media (max-width: 900px) {
        .inner {
            grid-template-columns: 1fr;
            gap: 48px;
        }
    }

    @media (max-width: 560px) {
        .section {
            padding: 80px 16px;
        }
    }
</style>
