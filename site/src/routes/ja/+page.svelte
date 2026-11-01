<script lang="ts">
    import Landing from "#lib/Landing.svelte";

    let { data } = $props();
</script>

<Landing lang="ja" release={data.release} />
