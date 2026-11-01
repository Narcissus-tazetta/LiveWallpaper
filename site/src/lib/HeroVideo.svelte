<script lang="ts">
    import { asset } from "$app/paths";

    let { label }: { label: string } = $props();

    let video: HTMLVideoElement;
    let reducedMotion = $state(false);

    $effect(() => {
        const query = window.matchMedia("(prefers-reduced-motion: reduce)");
        reducedMotion = query.matches;
        const onChange = () => (reducedMotion = query.matches);
        query.addEventListener("change", onChange);

        // Pausing off-screen keeps the page itself from costing battery.
        const observer = new IntersectionObserver(([entry]) => {
            if (reducedMotion) return;
            if (entry.isIntersecting) void video.play();
            else video.pause();
        });
        observer.observe(video);

        return () => {
            query.removeEventListener("change", onChange);
            observer.disconnect();
        };
    });
</script>

<div class="frame">
    <video
        bind:this={video}
        src={asset("demo.mp4")}
        poster={asset("demo-poster.jpg")}
        aria-label={label}
        muted
        loop
        playsinline
        preload="metadata"
        width="1600"
        height="900"
    ></video>
</div>

<style>
    .frame {
        overflow: hidden;
        border: 1px solid var(--line-strong);
        border-radius: 16px;
        background: #000;
        box-shadow:
            0 40px 80px -24px rgb(0 0 0 / 0.7),
            0 0 0 1px rgb(255 255 255 / 0.03);
    }

    video {
        display: block;
        width: 100%;
        height: auto;
    }
</style>
