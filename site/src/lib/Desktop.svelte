<script lang="ts">
    import { asset } from "$app/paths";
    import type { Dict } from "./i18n";
    import { presets } from "./presets";
    import Shader from "./Shader.svelte";

    let { t }: { t: Dict } = $props();

    let preset = $state(0);
    let parallax = $state(true);
    let spotlight = $state(false);
    let trail = $state(true);
    let rippleOn = $state(true);
    let reducedMotion = $state(false);
    let clock = $state("9:41");

    const pointer = $state({ x: 0.5, y: 0.5 });
    const ripple = $state({ x: 0.5, y: 0.5, id: 0 });

    let stage: HTMLDivElement;
    let trailCanvas: HTMLCanvasElement;

    interface Particle {
        x: number;
        y: number;
        vx: number;
        vy: number;
        life: number;
        size: number;
    }
    const particles: Particle[] = [];
    let trailFrame = 0;

    $effect(() => {
        const query = window.matchMedia("(prefers-reduced-motion: reduce)");
        reducedMotion = query.matches;
        const onChange = () => (reducedMotion = query.matches);
        query.addEventListener("change", onChange);

        const tick = () => {
            clock = new Date().toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
        };
        tick();
        const timer = setInterval(tick, 20000);

        return () => {
            query.removeEventListener("change", onChange);
            clearInterval(timer);
            cancelAnimationFrame(trailFrame);
        };
    });

    function paintTrail() {
        const ctx = trailCanvas.getContext("2d")!;
        const dpr = Math.min(window.devicePixelRatio || 1, 2);
        const w = trailCanvas.clientWidth;
        const h = trailCanvas.clientHeight;
        if (trailCanvas.width !== w * dpr || trailCanvas.height !== h * dpr) {
            trailCanvas.width = w * dpr;
            trailCanvas.height = h * dpr;
        }
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        ctx.clearRect(0, 0, w, h);
        ctx.globalCompositeOperation = "lighter";

        for (let i = particles.length - 1; i >= 0; i--) {
            const p = particles[i];
            p.life -= 0.022;
            if (p.life <= 0) {
                particles.splice(i, 1);
                continue;
            }
            p.x += p.vx;
            p.y += p.vy;
            const r = p.size * (0.4 + p.life);
            const g = ctx.createRadialGradient(p.x, p.y, 0, p.x, p.y, r);
            g.addColorStop(0, `rgba(255,255,255,${0.55 * p.life})`);
            g.addColorStop(1, "rgba(255,255,255,0)");
            ctx.fillStyle = g;
            ctx.beginPath();
            ctx.arc(p.x, p.y, r, 0, Math.PI * 2);
            ctx.fill();
        }

        trailFrame = particles.length ? requestAnimationFrame(paintTrail) : 0;
    }

    function onMove(e: PointerEvent) {
        const rect = stage.getBoundingClientRect();
        const px = e.clientX - rect.left;
        const py = e.clientY - rect.top;
        pointer.x = px / rect.width;
        pointer.y = 1 - py / rect.height;

        if (!trail || reducedMotion) return;
        for (let i = 0; i < 2; i++) {
            particles.push({
                x: px + (Math.random() - 0.5) * 6,
                y: py + (Math.random() - 0.5) * 6,
                vx: (Math.random() - 0.5) * 0.6,
                vy: (Math.random() - 0.5) * 0.6 - 0.15,
                life: 1,
                size: 10 + Math.random() * 14,
            });
        }
        if (!trailFrame) trailFrame = requestAnimationFrame(paintTrail);
    }

    function onDown(e: PointerEvent) {
        if (!rippleOn || reducedMotion) return;
        const rect = stage.getBoundingClientRect();
        ripple.x = (e.clientX - rect.left) / rect.width;
        ripple.y = 1 - (e.clientY - rect.top) / rect.height;
        ripple.id += 1;
    }

    const toggles = $derived([
        { key: "parallax", label: t.demo.parallax, on: parallax },
        { key: "spotlight", label: t.demo.spotlight, on: spotlight },
        { key: "trail", label: t.demo.trail, on: trail },
        { key: "ripple", label: t.demo.ripple, on: rippleOn },
    ]);

    function flip(key: string) {
        if (key === "parallax") parallax = !parallax;
        else if (key === "spotlight") spotlight = !spotlight;
        else if (key === "trail") trail = !trail;
        else rippleOn = !rippleOn;
    }
</script>

<figure class="wrap">
    <div
        class="stage"
        bind:this={stage}
        onpointermove={onMove}
        onpointerdown={onDown}
        role="img"
        aria-label={t.hero.demoNote}
    >
        <Shader {preset} {parallax} {spotlight} {pointer} {ripple} {reducedMotion} />
        <canvas class="trail" bind:this={trailCanvas}></canvas>

        <div class="menubar">
            <span class="apple" aria-hidden="true"></span>
            <strong>{t.demo.appName}</strong>
            {#each t.demo.menu as item (item)}
                <span class="menu-item">{item}</span>
            {/each}
            <span class="spacer"></span>
            <span class="clock">{clock}</span>
        </div>

        <aside class="panel" onpointermove={(e) => e.stopPropagation()}>
            <header>
                <img src="{asset('icon.png')}" alt="" width="22" height="22" />
                <span>{t.demo.appName}</span>
            </header>

            <p class="label">{t.demo.wallpapers}</p>
            <div class="swatches" role="radiogroup" aria-label={t.demo.wallpapers}>
                {#each presets as p, i (p.id)}
                    <button
                        type="button"
                        role="radio"
                        aria-checked={preset === i}
                        class:active={preset === i}
                        onclick={() => (preset = i)}
                    >
                        <span
                            class="chip"
                            style="background: linear-gradient(135deg, {p.stops
                                .map((c) => `rgb(${c.map((v) => Math.round(v * 255)).join(',')})`)
                                .join(',')})"
                        ></span>
                        <span class="name">{t.demo.presets[p.id as keyof typeof t.demo.presets]}</span>
                    </button>
                {/each}
            </div>

            <p class="label effects">{t.demo.effects}</p>
            <ul class="toggles">
                {#each toggles as item (item.key)}
                    <li>
                        <span>{item.label}</span>
                        <button
                            type="button"
                            role="switch"
                            aria-checked={item.on}
                            aria-label={item.label}
                            class="switch"
                            class:on={item.on}
                            onclick={() => flip(item.key)}
                        ></button>
                    </li>
                {/each}
            </ul>
        </aside>

        <div class="dock" aria-hidden="true">
            <span class="app a1"></span>
            <span class="app a2"></span>
            <img class="app self" src="{asset('icon.png')}" alt="" />
            <span class="app a3"></span>
            <span class="app a4"></span>
        </div>
    </div>
    <figcaption>{t.hero.demoNote}</figcaption>
</figure>

<style>
    .wrap {
        margin: 0;
    }

    .stage {
        position: relative;
        overflow: hidden;
        aspect-ratio: 16 / 10;
        border-radius: 18px;
        border: 1px solid var(--line-strong);
        background: #000;
        box-shadow:
            0 40px 120px -20px rgb(0 0 0 / 0.7),
            0 0 0 1px rgb(255 255 255 / 0.04) inset;
        cursor: crosshair;
        touch-action: pan-y;
        isolation: isolate;
    }

    .trail {
        position: absolute;
        inset: 0;
        width: 100%;
        height: 100%;
        pointer-events: none;
    }

    .menubar {
        position: absolute;
        inset: 0 0 auto 0;
        display: flex;
        align-items: center;
        gap: 18px;
        height: 26px;
        padding: 0 14px;
        font-size: 12px;
        color: rgb(255 255 255 / 0.92);
        background: rgb(0 0 0 / 0.18);
        backdrop-filter: blur(18px) saturate(1.4);
        pointer-events: none;
        user-select: none;
    }

    .apple {
        width: 11px;
        height: 13px;
        border-radius: 50% 50% 46% 46%;
        background: currentColor;
        opacity: 0.9;
    }

    .spacer {
        flex: 1;
    }

    .clock {
        font-variant-numeric: tabular-nums;
    }

    .panel {
        position: absolute;
        top: 44px;
        right: 16px;
        width: 232px;
        padding: 14px;
        border-radius: 14px;
        border: 1px solid rgb(255 255 255 / 0.16);
        background: rgb(20 22 28 / 0.55);
        backdrop-filter: blur(28px) saturate(1.6);
        box-shadow: 0 20px 50px -10px rgb(0 0 0 / 0.5);
        color: #fff;
        cursor: default;
    }

    .panel header {
        display: flex;
        align-items: center;
        gap: 8px;
        margin-bottom: 12px;
        font-size: 13px;
        font-weight: 600;
    }

    .panel header img {
        border-radius: 6px;
    }

    .label {
        margin: 12px 0 6px;
        font-size: 11px;
        letter-spacing: 0.04em;
        color: rgb(255 255 255 / 0.55);
    }

    .swatches {
        display: grid;
        grid-template-columns: repeat(3, 1fr);
        gap: 6px;
    }

    .swatches button {
        display: grid;
        gap: 5px;
        padding: 5px;
        border: 1px solid transparent;
        border-radius: 10px;
        background: rgb(255 255 255 / 0.06);
        color: inherit;
        font: inherit;
        font-size: 11px;
        cursor: pointer;
        transition:
            background 0.2s,
            border-color 0.2s;
    }

    .swatches button:hover {
        background: rgb(255 255 255 / 0.12);
    }

    .swatches button.active {
        border-color: rgb(255 255 255 / 0.85);
    }

    .chip {
        display: block;
        aspect-ratio: 4 / 3;
        border-radius: 6px;
    }

    .toggles {
        display: grid;
        gap: 8px;
        margin: 0;
        padding: 0;
        list-style: none;
    }

    .toggles li {
        display: flex;
        align-items: center;
        justify-content: space-between;
        font-size: 12px;
    }

    .switch {
        position: relative;
        width: 34px;
        height: 20px;
        padding: 0;
        border: 0;
        border-radius: 999px;
        background: rgb(255 255 255 / 0.22);
        cursor: pointer;
        transition: background 0.2s;
    }

    .switch::after {
        content: "";
        position: absolute;
        top: 2px;
        left: 2px;
        width: 16px;
        height: 16px;
        border-radius: 50%;
        background: #fff;
        box-shadow: 0 1px 3px rgb(0 0 0 / 0.3);
        transition: transform 0.2s;
    }

    .switch.on {
        background: var(--accent);
    }

    .switch.on::after {
        transform: translateX(14px);
    }

    .dock {
        position: absolute;
        bottom: 12px;
        left: 50%;
        display: flex;
        gap: 10px;
        padding: 8px 10px;
        border-radius: 20px;
        border: 1px solid rgb(255 255 255 / 0.18);
        background: rgb(255 255 255 / 0.14);
        backdrop-filter: blur(24px) saturate(1.5);
        transform: translateX(-50%);
        pointer-events: none;
    }

    .app {
        width: clamp(26px, 5vw, 44px);
        aspect-ratio: 1;
        border-radius: 22%;
        object-fit: cover;
    }

    .a1 {
        background: linear-gradient(160deg, #ffd166, #ef476f);
    }

    .a2 {
        background: linear-gradient(160deg, #8ecae6, #3a86ff);
    }

    .a3 {
        background: linear-gradient(160deg, #b8f2e6, #3bb273);
    }

    .a4 {
        background: linear-gradient(160deg, #cdb4db, #6a4c93);
    }

    figcaption {
        margin-top: 14px;
        text-align: center;
        font-size: 13px;
        color: var(--muted);
    }

    @media (max-width: 780px) {
        .stage {
            aspect-ratio: 4 / 5;
        }

        .panel {
            top: auto;
            right: 10px;
            bottom: 70px;
            left: 10px;
            width: auto;
        }

        .menu-item,
        .effects,
        .toggles {
            display: none;
        }
    }
</style>
