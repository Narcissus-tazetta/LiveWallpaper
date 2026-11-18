<script lang="ts">
    import { asset } from "$app/paths";

    let { label }: { label: string } = $props();

    let video: HTMLVideoElement;

    $effect(() => {
        const preview = video;
        const query = window.matchMedia("(prefers-reduced-motion: reduce)");
        let isVisible = false;
        function updatePlayback() {
            if (query.matches || !isVisible) {
                preview.pause();
                return;
            }
            void preview.play().catch((error: unknown) => {
                // Pausing while playback starts rejects the pending play request.
                if (error instanceof DOMException && error.name === "AbortError") return;
                console.warn("Could not play the wallpaper preview:", error);
            });
        }
        query.addEventListener("change", updatePlayback);

        // Pausing off-screen keeps the page itself from costing battery.
        const observer = new IntersectionObserver(([entry]) => {
            isVisible = entry.isIntersecting;
            updatePlayback();
        });
        observer.observe(preview);

        return () => {
            query.removeEventListener("change", updatePlayback);
            observer.disconnect();
            preview.pause();
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
