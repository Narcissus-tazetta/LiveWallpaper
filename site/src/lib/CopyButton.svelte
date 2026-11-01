<script lang="ts">
    let { text, label, done }: { text: string; label: string; done: string } = $props();

    let copied = $state(false);
    let timer: ReturnType<typeof setTimeout> | undefined;

    async function copy() {
        await navigator.clipboard.writeText(text);
        copied = true;
        clearTimeout(timer);
        timer = setTimeout(() => (copied = false), 1800);
    }
</script>

<button type="button" class="copy" class:copied onclick={copy} aria-live="polite">
    {copied ? done : label}
</button>

<style>
    .copy {
        flex: none;
        padding: 6px 12px;
        border: 1px solid var(--line-strong);
        border-radius: 8px;
        background: rgb(255 255 255 / 0.06);
        color: var(--fg);
        font: inherit;
        font-size: 12px;
        cursor: pointer;
        transition:
            background 0.2s,
            border-color 0.2s;
    }

    .copy:hover {
        background: rgb(255 255 255 / 0.12);
    }

    .copy.copied {
        border-color: var(--fg);
        color: var(--fg);
    }
</style>
