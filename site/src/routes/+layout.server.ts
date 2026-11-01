import { readFileSync } from "node:fs";
import { resolve } from "node:path";

// The Sparkle appcast is the release source of truth, so the page shows the same version the app updates to.
// Resolved from the working directory because this module is bundled elsewhere before prerendering runs.
const appcastPath = resolve("../docs/appcast.xml");

export function load() {
    const xml = readFileSync(appcastPath, "utf8");
    const version = xml.match(/<sparkle:shortVersionString>([^<]+)</)?.[1];
    const pubDate = xml.match(/<pubDate>([^<]+)</)?.[1];
    if (!version || !pubDate) throw new Error(`No release entry found in ${appcastPath}`);
    return { release: { version, date: new Date(pubDate).toISOString().slice(0, 10) } };
}
