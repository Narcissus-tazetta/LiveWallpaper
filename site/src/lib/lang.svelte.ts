import type { Lang } from "./i18n";

const storageKey = "lang";

export const current = $state<{ value: Lang }>({ value: "en" });

// Prerendered HTML is English, so this runs only after hydration.
export function initLang() {
    const saved = localStorage.getItem(storageKey);
    if (saved === "ja" || saved === "en") {
        current.value = saved;
        return;
    }
    const preferred = navigator.languages.find((tag) => /^(ja|en)\b/i.test(tag));
    current.value = preferred && /^ja\b/i.test(preferred) ? "ja" : "en";
}

export function setLang(lang: Lang) {
    current.value = lang;
    localStorage.setItem(storageKey, lang);
}
