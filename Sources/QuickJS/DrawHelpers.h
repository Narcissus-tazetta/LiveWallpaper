#ifndef LWJS_DRAW_HELPERS_H
#define LWJS_DRAW_HELPERS_H
#define LWJS_DRAW_HELPERS \
    "globalThis.fract=x=>x-Math.floor(x);" \
    "globalThis.mod=(x,n)=>((x%n)+n)%n;" \
    "globalThis.mapRange=(v,a,b,c,d)=>lerp(c,d,(v-a)/(b-a));" \
    "globalThis.pingPong=x=>1-Math.abs(mod(x,2)-1);" \
    "globalThis.triangle=x=>1-4*Math.abs(fract(x)-0.5);" \
    "globalThis.pulse=(x,duty=0.5)=>fract(x)<duty?1:0;" \
    "globalThis.hash=s=>{let h=2166136261;for(const c of String(s))h=Math.imul(h^c.codePointAt(0),16777619);return h>>>0;};" \
    "globalThis.ease=(t,kind='smooth')=>{t=clamp(t,0,1);switch(kind){" \
    "case 'linear':return t;case 'smooth':return t*t*(3-2*t);case 'smoother':return t*t*t*(t*(t*6-15)+10);" \
    "case 'inQuad':return t*t;case 'outQuad':return 1-(1-t)**2;case 'inOutQuad':return t<0.5?2*t*t:1-(-2*t+2)**2/2;" \
    "case 'inCubic':return t*t*t;case 'outCubic':return 1-(1-t)**3;case 'inOutCubic':return t<0.5?4*t*t*t:1-(-2*t+2)**3/2;" \
    "case 'inOutSine':return (1-Math.cos(Math.PI*t))/2;case 'outBack':return 1+2.70158*(t-1)**3+1.70158*(t-1)**2;" \
    "case 'outElastic':return t===0||t===1?t:2**(-10*t)*Math.sin((t*10-0.75)*(2*Math.PI/3))+1;" \
    "case 'outBounce':{const n=7.5625,d=2.75;if(t<1/d)return n*t*t;if(t<2/d)return n*(t-=1.5/d)*t+0.75;" \
    "if(t<2.5/d)return n*(t-=2.25/d)*t+0.9375;return n*(t-=2.625/d)*t+0.984375;}" \
    "default:throw new Error('Unknown easing: '+kind);}};" \
    "globalThis.vec={of:(x=0,y=0)=>({x,y}),add:(a,b)=>({x:a.x+b.x,y:a.y+b.y}),sub:(a,b)=>({x:a.x-b.x,y:a.y-b.y})," \
    "mul:(a,n)=>({x:a.x*n,y:a.y*n}),dot:(a,b)=>a.x*b.x+a.y*b.y,length:a=>Math.hypot(a.x,a.y)," \
    "distance:(a,b)=>Math.hypot(a.x-b.x,a.y-b.y),normalize:a=>{let n=Math.hypot(a.x,a.y);return n?{x:a.x/n,y:a.y/n}:{x:0,y:0};}," \
    "rotate:(a,degrees)=>{let r=degrees*Math.PI/180,c=Math.cos(r),s=Math.sin(r);return {x:a.x*c-a.y*s,y:a.x*s+a.y*c};}," \
    "mix:(a,b,t)=>({x:lerp(a.x,b.x,t),y:lerp(a.y,b.y,t)})};" \
    "globalThis.path={circle:(t,r=1)=>({x:Math.cos(t*2*Math.PI)*r,y:Math.sin(t*2*Math.PI)*r})," \
    "ellipse:(t,rx=1,ry=0.5)=>({x:Math.cos(t*2*Math.PI)*rx,y:Math.sin(t*2*Math.PI)*ry})," \
    "lissajous:(t,a=3,b=2,offset=0.25)=>({x:wave(t,a,offset),y:wave(t,b)})," \
    "bezier:(a,b,c,d,t)=>{let ab=vec.mix(a,b,t),bc=vec.mix(b,c,t),cd=vec.mix(c,d,t);return vec.mix(vec.mix(ab,bc,t),vec.mix(bc,cd,t),t);}," \
    "polyline:(points,t)=>{if(points.length<2)throw new Error('path.polyline needs at least two points');" \
    "let x=clamp(t,0,1)*(points.length-1),i=Math.min(Math.floor(x),points.length-2);return vec.mix(points[i],points[i+1],x-i);}};" \
    "globalThis.color={rgb:(red,green,blue,alpha=1)=>({red,green,blue,alpha}),hsv," \
    "hex:s=>{s=String(s).replace(/^#/,'');if(!/^(?:[0-9a-f]{6}|[0-9a-f]{8})$/i.test(s))throw new Error('Use #RRGGBB or #RRGGBBAA');" \
    "return {red:parseInt(s.slice(0,2),16)/255,green:parseInt(s.slice(2,4),16)/255,blue:parseInt(s.slice(4,6),16)/255,alpha:s.length===8?parseInt(s.slice(6,8),16)/255:1};}," \
    "mix:(a,b,t)=>({red:lerp(a.red,b.red,t),green:lerp(a.green,b.green,t),blue:lerp(a.blue,b.blue,t),alpha:lerp(a.alpha,b.alpha,t)})," \
    "alpha:(c,alpha)=>({...c,alpha})};" \
    "globalThis.noise2=(x,y,seed=0)=>{let ix=Math.floor(x),iy=Math.floor(y),u=ease(fract(x)),v=ease(fract(y));" \
    "const r=(a,b)=>random(seed,Math.imul(a,73856093)^Math.imul(b,19349663));return lerp(lerp(r(ix,iy),r(ix+1,iy),u),lerp(r(ix,iy+1),r(ix+1,iy+1),u),v);};" \
    "globalThis.fbm2=(x,y,seed=0,octaves=4)=>{if(!Number.isInteger(octaves)||octaves<1||octaves>8)throw new Error('fbm2 octaves must be 1..8');" \
    "let value=0,total=0,amplitude=1;for(let i=0;i<octaves;i++){value+=noise2(x,y,seed+i)*amplitude;total+=amplitude;x*=2;y*=2;amplitude*=0.5;}return value/total;};" \
    "globalThis.curve=(t,keys)=>{if(keys.length<2)throw new Error('curve needs at least two keys');" \
    "for(let i=0;i<keys.length;i++){let k=keys[i];if(!Number.isFinite(k.time)||!Number.isFinite(k.value)||(i&&k.time<=keys[i-1].time))throw new Error('curve keys must have finite values and increasing times');}" \
    "if(t<=keys[0].time)return keys[0].value;for(let i=1;i<keys.length;i++){let a=keys[i-1],b=keys[i];if(t<=b.time)return lerp(a.value,b.value,ease((t-a.time)/(b.time-a.time),a.ease||'linear'));}return keys[keys.length-1].value;};"
#endif
