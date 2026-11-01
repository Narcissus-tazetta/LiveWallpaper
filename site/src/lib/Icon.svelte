<script lang="ts">
    let { name, size = 22 }: { name: string; size?: number } = $props();
</script>

<svg viewBox="0 0 24 24" width={size} height={size} fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
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
    {:else if name === "power"}
        <rect x="2" y="7" width="17" height="10" rx="2" /><path d="M22 10v4" /><path d="m11 10-2 2h3l-2 2" />
    {:else if name === "control"}
        <path d="m7 9-3 3 3 3M17 9l3 3-3 3M14 7l-4 10" />
    {:else if name === "screensaver"}
        <rect x="3" y="4" width="18" height="12" rx="2" /><path d="M8 20h8M12 16v4" /><path d="M14.5 7.5a3 3 0 1 0 1.5 4.5 3.5 3.5 0 0 1-1.5-4.5z" />
    {:else if name === "playlist"}
        <path d="M4 6h11M4 11h11M4 16h7" /><path d="m15 14 5 2.5-5 2.5z" />
    {:else if name === "language"}
        <circle cx="12" cy="12" r="8.5" /><path d="M3.5 12h17M12 3.5c2.5 2.6 3.5 5.5 3.5 8.5s-1 5.9-3.5 8.5c-2.5-2.6-3.5-5.5-3.5-8.5s1-5.9 3.5-8.5z" />
    {:else if name === "update"}
        <path d="M20 12a8 8 0 1 1-2.3-5.7" /><path d="M20 4v4.5h-4.5" /><path d="M12 8v5l3 1.5" />
    {:else}
        <path d="M4 9.5 5.5 5h13L20 9.5" /><path d="M4 9.5a2.7 2.7 0 0 0 5.3 0 2.7 2.7 0 0 0 5.4 0 2.7 2.7 0 0 0 5.3 0V19H4z" />
    {/if}
</svg>
