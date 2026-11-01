<script lang="ts">
    let { name }: { name: string } = $props();
</script>

<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    {#if name === "media"}
        <rect x="3" y="5" width="18" height="14" rx="3" /><path d="m10 9.5 5 2.5-5 2.5z" />
    {:else if name === "multi"}
        <rect x="2.5" y="4" width="11" height="8" rx="1.5" /><rect x="10.5" y="9" width="11" height="8" rx="1.5" /><path d="M7 20h6" />
    {:else if name === "auto"}
        <circle cx="12" cy="12" r="8.5" /><path d="M12 7v5l3 2" />
    {:else if name === "edit"}
        <path d="M7 4v16M17 4v16M3 8h4M3 16h4M17 8h4M17 16h4" /><path d="M7 12h10" />
    {:else if name === "cursor"}
        <path d="m5 4 6.5 15 2.2-6.3L20 10.5z" />
    {:else if name === "playlist"}
        <path d="M4 7h11M4 12h11M4 17h6" /><path d="m18 14 3 2-3 2z" />
    {:else if name === "saver"}
        <rect x="3" y="4" width="18" height="12" rx="2" /><path d="M9 20h6M12 16v4" />
    {:else}
        <path d="M4 9.5 5.5 5h13L20 9.5" /><path d="M4 9.5a2.7 2.7 0 0 0 5.3 0 2.7 2.7 0 0 0 5.4 0 2.7 2.7 0 0 0 5.3 0V19H4z" />
    {/if}
</svg>
