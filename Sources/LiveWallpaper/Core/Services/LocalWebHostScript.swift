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
        const pausedMedia = new Set();
        function updateMedia() {
            document.querySelectorAll('audio,video').forEach(media => {
                media.muted = !state.audioEnabled;
                media.volume = state.volume;
                if (state.paused && !media.paused) {
                    pausedMedia.add(media);
                    media.pause();
                }
            });
            if (!state.paused) {
                for (const media of pausedMedia) {
                    if (media.isConnected) media.play().catch(error => console.error('Wallpaper media resume failed', error));
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
