import type { Action } from "svelte/action";

// Hidden only after hydration so the prerendered page stays readable without JavaScript.
export const reveal: Action<HTMLElement, number | undefined> = (node, delay = 0) => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

    node.style.opacity = "0";
    node.style.transform = "translateY(24px)";
    node.style.transition = `opacity 0.8s cubic-bezier(0.2, 0.7, 0.2, 1) ${delay}ms, transform 0.8s cubic-bezier(0.2, 0.7, 0.2, 1) ${delay}ms`;

    const observer = new IntersectionObserver(
        ([entry]) => {
            if (!entry.isIntersecting) return;
            node.style.opacity = "1";
            node.style.transform = "none";
            observer.disconnect();
        },
        { threshold: 0.15 },
    );
    observer.observe(node);

    return { destroy: () => observer.disconnect() };
};
