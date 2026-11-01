<script lang="ts">
    import { untrack } from "svelte";
    import { presets } from "./presets";

    interface Props {
        preset: number;
        parallax: boolean;
        spotlight: boolean;
        pointer: { x: number; y: number };
        ripple: { x: number; y: number; id: number };
        reducedMotion: boolean;
        paused?: boolean;
    }

    let { preset, parallax, spotlight, pointer, ripple, reducedMotion, paused = false }: Props = $props();

    let resume = () => {};
    $effect(() => {
        if (!paused) resume();
    });

    let canvas: HTMLCanvasElement;
    const vertex = `attribute vec2 a;void main(){gl_Position=vec4(a,0.,1.);}`;

    const fragment = `
precision highp float;
uniform vec2 u_res;
uniform float u_time;
uniform vec2 u_mouse;
uniform float u_parallax;
uniform float u_spot;
uniform vec3 u_rip;
uniform float u_mix;
uniform vec3 a0,a1,a2,a3,b0,b1,b2,b3;

float hash(vec2 p){p=fract(p*vec2(123.34,456.21));p+=dot(p,p+45.32);return fract(p.x*p.y);}
float noise(vec2 p){
    vec2 i=floor(p),f=fract(p);
    float a=hash(i),b=hash(i+vec2(1,0)),c=hash(i+vec2(0,1)),d=hash(i+vec2(1,1));
    vec2 u=f*f*(3.-2.*f);
    return mix(a,b,u.x)+(c-a)*u.y*(1.-u.x)+(d-b)*u.x*u.y;
}
float fbm(vec2 p){
    float v=0.,s=.5;
    for(int i=0;i<4;i++){v+=s*noise(p);p=p*2.02+vec2(3.1,1.7);s*=.5;}
    return v;
}
vec3 ramp(vec3 c0,vec3 c1,vec3 c2,vec3 c3,float f){
    f=clamp(f,0.,1.)*3.;
    vec3 c=mix(c0,c1,smoothstep(0.,1.,f));
    c=mix(c,c2,smoothstep(1.,2.,f));
    return mix(c,c3,smoothstep(2.,3.,f));
}

void main(){
    vec2 uv=gl_FragCoord.xy/u_res;
    vec2 p=(gl_FragCoord.xy-.5*u_res)/u_res.y;
    vec2 mp=(u_mouse*u_res-.5*u_res)/u_res.y;
    vec2 p0=p;

    p+=(u_mouse-.5)*.07*u_parallax;

    float rt=u_time-u_rip.z;
    vec2 rc=(u_rip.xy*u_res-.5*u_res)/u_res.y;
    float d=length(p0-rc);
    float ring=exp(-pow((d-rt*.45)*12.,2.))*exp(-rt*1.7)*step(0.,rt);
    p+=normalize(p0-rc+1e-4)*ring*.035;

    float t=u_time*.05;
    vec2 q=vec2(fbm(p*1.5+t),fbm(p*1.5+vec2(5.2,1.3)-t));
    vec2 r=vec2(fbm(p*1.5+3.*q+vec2(1.7,9.2)+t*1.5),fbm(p*1.5+3.*q+vec2(8.3,2.8)-t));
    float f=fbm(p*1.3+3.*r);
    f=smoothstep(.15,.85,f*1.25+p.y*.12);

    vec3 col=mix(ramp(a0,a1,a2,a3,f),ramp(b0,b1,b2,b3,f),u_mix);
    col+=ring*.14;

    float sd=length(p0-mp);
    float lit=smoothstep(.62,.0,sd);
    col*=mix(1.,.16+.95*lit,u_spot);

    col*=1.-.55*dot(uv-.5,uv-.5);
    col+=(hash(gl_FragCoord.xy+u_time)-.5)/255.;
    gl_FragColor=vec4(col,1.);
}`;

    // The GL loop reads props from rAF on its own; tracking them here would rebuild the context on every change.
    $effect(() => untrack(setup));

    function setup() {
        const gl = canvas.getContext("webgl", { antialias: false, alpha: false, powerPreference: "low-power" });
        if (!gl) return;

        const compile = (type: number, src: string) => {
            const s = gl.createShader(type)!;
            gl.shaderSource(s, src);
            gl.compileShader(s);
            if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
                throw new Error(`shader compile failed: ${gl.getShaderInfoLog(s)}`);
            }
            return s;
        };

        const program = gl.createProgram()!;
        gl.attachShader(program, compile(gl.VERTEX_SHADER, vertex));
        gl.attachShader(program, compile(gl.FRAGMENT_SHADER, fragment));
        gl.linkProgram(program);
        if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
            throw new Error(`program link failed: ${gl.getProgramInfoLog(program)}`);
        }
        gl.useProgram(program);

        const buffer = gl.createBuffer();
        gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
        gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
        const loc = gl.getAttribLocation(program, "a");
        gl.enableVertexAttribArray(loc);
        gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);

        const u = (name: string) => gl.getUniformLocation(program, name);
        const uRes = u("u_res");
        const uTime = u("u_time");
        const uMouse = u("u_mouse");
        const uParallax = u("u_parallax");
        const uSpot = u("u_spot");
        const uRip = u("u_rip");
        const uMix = u("u_mix");

        let from = preset;
        let to = preset;
        let mixStart = -10;
        let mixValue = 0;
        const setStops = (prefix: "a" | "b", index: number) => {
            presets[index].stops.forEach((c, i) => gl.uniform3f(u(`${prefix}${i}`), c[0], c[1], c[2]));
        };
        setStops("a", from);
        setStops("b", to);

        let mx = pointer.x;
        let my = pointer.y;
        let par = 0;
        let spot = 0;
        let lastRipple = ripple.id;
        let rippleStart = -100;
        let rippleX = 0.5;
        let rippleY = 0.5;
        let visible = true;
        let frame = 0;
        let last = performance.now();
        let clock = 8;

        const resize = () => {
            const dpr = Math.min(window.devicePixelRatio || 1, 1.5);
            const w = Math.max(1, Math.round(canvas.clientWidth * dpr));
            const h = Math.max(1, Math.round(canvas.clientHeight * dpr));
            if (canvas.width !== w || canvas.height !== h) {
                canvas.width = w;
                canvas.height = h;
                gl.viewport(0, 0, w, h);
            }
        };

        const draw = (now: number) => {
            const dt = Math.min((now - last) / 1000, 0.1);
            last = now;
            if (!reducedMotion) clock += dt;

            if (preset !== to) {
                from = mixValue >= 0.5 ? to : from;
                to = preset;
                setStops("a", from);
                setStops("b", to);
                mixStart = now;
            }
            const k = reducedMotion ? 1 : Math.min((now - mixStart) / 1100, 1);
            mixValue = k * k * (3 - 2 * k);

            if (ripple.id !== lastRipple) {
                lastRipple = ripple.id;
                rippleStart = clock;
                rippleX = ripple.x;
                rippleY = ripple.y;
            }

            const ease = reducedMotion ? 1 : 1 - Math.exp(-dt * 7);
            mx += (pointer.x - mx) * ease;
            my += (pointer.y - my) * ease;
            par += ((parallax && !reducedMotion ? 1 : 0) - par) * ease;
            spot += ((spotlight ? 1 : 0) - spot) * ease;

            resize();
            gl.uniform2f(uRes, canvas.width, canvas.height);
            gl.uniform1f(uTime, clock);
            gl.uniform2f(uMouse, mx, my);
            gl.uniform1f(uParallax, par);
            gl.uniform1f(uSpot, spot);
            gl.uniform3f(uRip, rippleX, rippleY, rippleStart);
            gl.uniform1f(uMix, mixValue);
            gl.drawArrays(gl.TRIANGLES, 0, 3);
        };

        const loop = (now: number) => {
            draw(now);
            frame = paused ? 0 : requestAnimationFrame(loop);
        };

        const start = () => {
            if (!frame && !paused) {
                last = performance.now();
                frame = requestAnimationFrame(loop);
            }
        };
        const stop = () => {
            cancelAnimationFrame(frame);
            frame = 0;
        };

        // Off-screen or hidden tabs stop drawing, the same idea as the app pausing a covered wallpaper.
        const observer = new IntersectionObserver(([entry]) => {
            visible = entry.isIntersecting;
            if (visible && !document.hidden) start();
            else stop();
        });
        observer.observe(canvas);
        resume = () => {
            if (visible && !document.hidden) start();
        };
        const onVisibility = () => {
            if (!document.hidden && visible) start();
            else stop();
        };
        document.addEventListener("visibilitychange", onVisibility);

        if (reducedMotion) {
            draw(performance.now());
            const redraw = setInterval(() => draw(performance.now()), 200);
            return () => {
                clearInterval(redraw);
                observer.disconnect();
                document.removeEventListener("visibilitychange", onVisibility);
            };
        }

        start();
        return () => {
            stop();
            observer.disconnect();
            document.removeEventListener("visibilitychange", onVisibility);
        };
    }
</script>

<canvas bind:this={canvas}></canvas>

<style>
    canvas {
        position: absolute;
        inset: 0;
        width: 100%;
        height: 100%;
        display: block;
        background: linear-gradient(135deg, #04121f, #0b6e8a 55%, #2ee6a6);
    }
</style>
