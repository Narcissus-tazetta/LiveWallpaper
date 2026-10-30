import Foundation

enum LocalWebHostScript {
    static func json(_ value: some Encodable) -> String {
        do {
            return try String(data: JSONEncoder().encode(value), encoding: .utf8)!
        } catch { preconditionFailure("Invalid internal web payload: \(error)") }
    }

    struct State: Encodable {
        var paused: Bool
        var audioEnabled: Bool
        var volume: Float
        var fps: Double
        var language: String

        var json: String {
            LocalWebHostScript.json(self)
        }
    }

    static func bootstrap(
        state: State,
        properties: [String: WebPropertyValue] = [:],
        assets: [String] = []
    ) -> String {
        let values = json(properties)
        let assetsJSON = json(assets)
        return "window.__liveWallpaperPropertyAssets = \(assetsJSON);window.__liveWallpaperState = \(state.json);window.__liveWallpaperPropertyValues = \(values);\n" +
            runtime
    }

    static let runtime = #"""
    (() => {
        const state = window.__liveWallpaperState;
        function propertyValues(values) {
            const result = {...values};
            for (const [key, value] of Object.entries(result)) {
                if (window.__liveWallpaperPropertyAssets.includes(key) && typeof value === 'string' && value.startsWith('.livewallpaper-assets/')) {
                    result[key] = location.origin + '/' + location.pathname.split('/')[1] + '/' + value;
                }
            }
            return result;
        }
        window.__liveWallpaperPropertyValues = propertyValues(window.__liveWallpaperPropertyValues || {});
        window.__liveWallpaperSetProperties = (values, assets) => {
            window.__liveWallpaperPropertyAssets = assets;
            window.__liveWallpaperPropertyValues = propertyValues(values);
            window.dispatchEvent(new CustomEvent('livewallpaper:properties', {detail:window.__liveWallpaperPropertyValues}));
        };
        window.__liveWallpaperSubscribe = feature => window.webkit.messageHandlers.liveWallpaper.postMessage(feature);
        // Hand-written pages read their current values here; the events carry later changes.
        window.liveWallpaper = Object.freeze({
            get properties() { return window.__liveWallpaperPropertyValues; },
            get state() { return {...state}; },
            get media() { return window.__liveWallpaperMediaState?.value || null; },
            get directories() { return window.__liveWallpaperDirectoryFiles; },
            subscribe: feature => {
                if (feature !== 'spectrum' && feature !== 'media') throw new RangeError('Unknown feature: ' + feature);
                window.__liveWallpaperSubscribe(feature);
            }
        });

        // Folder listings: the host sends each property's whole listing ([file, modified] pairs)
        // and the page hears what was added, changed or removed.
        const directoryDates = {};
        window.__liveWallpaperDirectoryFiles = {};
        window.__liveWallpaperSetDirectory = (property, entries) => {
            const previous = directoryDates[property] || {};
            const next = Object.fromEntries(entries);
            const added = entries.filter(([file, date]) => previous[file] !== date).map(([file]) => file);
            const removed = Object.keys(previous).filter(file => !(file in next));
            directoryDates[property] = next;
            window.__liveWallpaperDirectoryFiles[property] = Object.keys(next);
            if (added.length || removed.length) window.dispatchEvent(new CustomEvent('livewallpaper:directory', {detail:{property, added, removed}}));
        };
        // Pages load listed files as file:///Z:/… (or file:///Z%3A/…), which a page served over
        // http may not read, so those go to the local server, which serves only the chosen folders.
        const userFile = /^file:\/{2,3}z(?::|%3a)(\/[^?#]*)/i;
        const userFileBase = location.origin + '/' + location.pathname.split('/')[1] + '/_userdir';
        function servedURL(value) {
            const match = typeof value === 'string' ? userFile.exec(value.trim()) : null;
            if (!match) return value;
            let path;
            try { path = decodeURIComponent(match[1]); } catch { return value; }
            return userFileBase + path.split('/').map(encodeURIComponent).join('/');
        }
        // The page keeps reading back the address it set, as it would in the original.
        const requested = new WeakMap();
        for (const type of [HTMLImageElement, HTMLMediaElement, HTMLSourceElement]) {
            const descriptor = Object.getOwnPropertyDescriptor(type.prototype, 'src');
            Object.defineProperty(type.prototype, 'src', {
                configurable: true,
                enumerable: descriptor.enumerable,
                get() {
                    const value = descriptor.get.call(this);
                    const original = requested.get(this);
                    return original && original.resolved === value ? original.value : value;
                },
                set(value) {
                    const text = String(value), served = servedURL(text);
                    descriptor.set.call(this, served);
                    if (served === text) requested.delete(this);
                    else requested.set(this, {value: text, attribute: served, resolved: descriptor.get.call(this)});
                }
            });
        }
        const nativeSetAttribute = Element.prototype.setAttribute;
        const nativeGetAttribute = Element.prototype.getAttribute;
        const servesSource = element => element instanceof HTMLImageElement || element instanceof HTMLMediaElement || element instanceof HTMLSourceElement;
        Element.prototype.setAttribute = function(name, value) {
            if (servesSource(this) && String(name).toLowerCase() === 'src') { this.src = value; return; }
            return nativeSetAttribute.call(this, name, value);
        };
        Element.prototype.getAttribute = function(name) {
            const value = nativeGetAttribute.call(this, name);
            if (!servesSource(this) || String(name).toLowerCase() !== 'src') return value;
            const original = requested.get(this);
            return original && original.attribute === value ? original.value : value;
        };
        const nativeFetch = window.fetch.bind(window);
        window.fetch = (input, init) => nativeFetch(typeof input === 'string' || input instanceof URL ? servedURL(String(input)) : input, init);
        const nativeOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(method, url, ...rest) {
            return nativeOpen.call(this, method, typeof url === 'string' || url instanceof URL ? servedURL(String(url)) : url, ...rest);
        };
        window.webkit?.messageHandlers?.liveWallpaper?.postMessage('directories');
        window.__liveWallpaperSpectrum = values => window.dispatchEvent(new CustomEvent('livewallpaper:spectrum', {detail:values}));
        window.__liveWallpaperMedia = (value, enabled, artworkUnchanged) => {
            if (artworkUnchanged) value.artwork = window.__liveWallpaperMediaState?.value.artwork || '';
            window.__liveWallpaperMediaState = {value, enabled};
            window.dispatchEvent(new CustomEvent('livewallpaper:media', {detail:{value, enabled}}));
        };
        // The original runs frames at the display's rate whatever its frame rate setting, and
        // only stops them while paused.
        const nativeRAF = window.requestAnimationFrame.bind(window);
        const nativeCancel = window.cancelAnimationFrame.bind(window);
        const callbacks = new Map();
        let nextID = 1, scheduled = null;
        function schedule() {
            if (!state.paused && callbacks.size && scheduled === null) scheduled = nativeRAF(tick);
        }
        function tick(time) {
            scheduled = null;
            if (state.paused) return;
            const ready = [...callbacks.keys()];
            for (const id of ready) {
                const callback = callbacks.get(id);
                callbacks.delete(id);
                if (callback) {
                    try { callback(time); } catch (error) { console.error('Wallpaper frame failed', error); }
                }
            }
            schedule();
        }
        window.requestAnimationFrame = callback => {
            const id = nextID++;
            callbacks.set(id, callback);
            schedule();
            return id;
        };
        window.cancelAnimationFrame = id => { callbacks.delete(id); };

        // The original also holds the page's own timers while paused and runs each one that
        // came due once on resume, however many times an interval elapsed. Workers keep
        // running, so only this window's timers are wrapped.
        const heldTimers = new Map();
        function holdWhilePaused(callback, args, id) {
            return () => {
                if (state.paused) heldTimers.set(id(), () => callback(...args));
                else callback(...args);
            };
        }
        for (const [set, clear] of [['setTimeout', 'clearTimeout'], ['setInterval', 'clearInterval']]) {
            const nativeSet = window[set].bind(window);
            const nativeClear = window[clear].bind(window);
            window[set] = (callback, delay, ...args) => {
                if (typeof callback !== 'function') return nativeSet(callback, delay, ...args);
                let timer;
                timer = nativeSet(holdWhilePaused(callback, args, () => timer), delay);
                return timer;
            };
            window[clear] = id => {
                heldTimers.delete(id);
                nativeClear(id);
            };
        }
        function releaseTimers() {
            const due = [...heldTimers.values()];
            heldTimers.clear();
            for (const run of due) {
                try { run(); } catch (error) { console.error('Wallpaper timer failed', error); }
            }
        }

        const contexts = new Set();
        const gains = new WeakMap();
        const resumes = new WeakMap();
        const suspendedByHost = new Set();
        const nativeConnect = window.AudioNode && AudioNode.prototype.connect;
        if (nativeConnect) {
            AudioNode.prototype.connect = function(destination, ...args) {
                const gain = gains.get(this.context);
                if (gain && this !== gain && destination === this.context.destination) {
                    nativeConnect.call(this, gain, ...args);
                    return destination;
                }
                return nativeConnect.call(this, destination, ...args);
            };
            const nativeDisconnect = AudioNode.prototype.disconnect;
            AudioNode.prototype.disconnect = function(...args) {
                const gain = gains.get(this.context);
                if (gain && this !== gain && args[0] === this.context.destination) args[0] = gain;
                return nativeDisconnect.apply(this, args);
            };
        }
        function configureContext(context) {
            contexts.add(context);
            const resume = context.resume.bind(context);
            resumes.set(context, resume);
            const gain = context.createGain();
            gain.gain.value = state.audioEnabled ? state.volume : 0;
            nativeConnect.call(gain, context.destination);
            gains.set(context, gain);
            context.resume = () => {
                if (state.paused || !state.audioEnabled) {
                    suspendedByHost.add(context);
                    return Promise.resolve();
                }
                return resume();
            };
            const close = context.close.bind(context);
            context.close = () => {
                contexts.delete(context);
                suspendedByHost.delete(context);
                return close();
            };
            updateContext(context);
            return context;
        }
        const OriginalContext = window.AudioContext || window.webkitAudioContext;
        if (OriginalContext) {
            const WrappedContext = new Proxy(OriginalContext, {
                construct(target, args, newTarget) { return configureContext(Reflect.construct(target, args, newTarget)); }
            });
            window.AudioContext = WrappedContext;
            if (window.webkitAudioContext) window.webkitAudioContext = WrappedContext;
        }
        function updateContext(context) {
            if (context.state === 'closed') return;
            gains.get(context).gain.value = state.audioEnabled ? state.volume : 0;
            if (state.paused || !state.audioEnabled) {
                if (context.state === 'running') {
                    suspendedByHost.add(context);
                    context.suspend().catch(error => console.error('Wallpaper audio suspend failed', error));
                }
            } else if (suspendedByHost.delete(context)) {
                resumes.get(context)().catch(error => console.error('Wallpaper audio resume failed', error));
            }
        }
        // Pages often play through `new Audio()`, which is never attached to the document, so a
        // DOM query alone cannot see it. Elements are collected where they are created or played.
        const trackedMedia = new WeakSet();
        const mediaRefs = [];
        const mutedDescriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'muted');
        function trackMedia(media) {
            if (trackedMedia.has(media)) return media;
            trackedMedia.add(media);
            mediaRefs.push(new WeakRef(media));
            if (!state.audioEnabled) mutedDescriptor.set.call(media, true);
            return media;
        }
        // The page unmutes its elements itself right before playing them.
        Object.defineProperty(HTMLMediaElement.prototype, 'muted', {
            configurable: true,
            enumerable: mutedDescriptor.enumerable,
            get() { return mutedDescriptor.get.call(this); },
            set(value) { mutedDescriptor.set.call(this, state.audioEnabled ? value : true); }
        });
        const nativePlay = HTMLMediaElement.prototype.play;
        HTMLMediaElement.prototype.play = function(...args) {
            trackMedia(this);
            return nativePlay.apply(this, args);
        };
        const nativeCreateElement = Document.prototype.createElement;
        Document.prototype.createElement = function(...args) {
            const element = nativeCreateElement.apply(this, args);
            return element instanceof HTMLMediaElement ? trackMedia(element) : element;
        };
        window.Audio = new Proxy(window.Audio, {
            construct(target, args, newTarget) { return trackMedia(Reflect.construct(target, args, newTarget)); }
        });
        function allMedia() {
            const media = new Set(document.querySelectorAll('audio,video'));
            for (let i = mediaRefs.length - 1; i >= 0; i--) {
                const element = mediaRefs[i].deref();
                if (element) media.add(element);
                else mediaRefs.splice(i, 1);
            }
            return media;
        }
        const pausedMedia = new Set();
        function updateMedia() {
            allMedia().forEach(media => {
                mutedDescriptor.set.call(media, !state.audioEnabled);
                // A page's own detached elements keep the volume the page chose.
                if (media.isConnected) media.volume = state.volume;
                if (state.paused && !media.paused) {
                    pausedMedia.add(media);
                    media.pause();
                }
            });
            if (!state.paused) {
                for (const media of pausedMedia) {
                    media.play().catch(error => console.error('Wallpaper media resume failed', error));
                }
                pausedMedia.clear();
            }
        }
        new MutationObserver(updateMedia).observe(document, {childList: true, subtree: true});
        document.addEventListener('play', updateMedia, true);
        window.__liveWallpaperUpdate = value => {
            Object.assign(state, value);
            if (state.paused && scheduled !== null) { nativeCancel(scheduled); scheduled = null; }
            if (!state.paused) schedule();
            contexts.forEach(updateContext);
            updateMedia();
            window.dispatchEvent(new CustomEvent('livewallpaper:state', {detail: {...state}}));
            // After the event, so that the page hears setPaused(false) before its timers run,
            // as in the original.
            if (!state.paused) releaseTimers();
        };
    })();
    """#
}
