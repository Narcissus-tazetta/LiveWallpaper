import type { Handle } from "@sveltejs/kit/hooks";

// The two languages share one template, so the document language is stamped per page at prerender time.
export const handle: Handle = ({ event, resolve }) => {
    const lang = /\/ja\/?$/.test(event.url.pathname) ? "ja" : "en";
    return resolve(event, {
        transformPageChunk: ({ html }: { html: string }) => html.replaceAll("%lang%", lang),
    });
};
