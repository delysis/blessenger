export const PUBLIC = new Set(['/', '/app.js','/rtc.js','/style.css','/manifest.webmanifest','/sw.js','/recorder.js','/call-audio.js','/runtime.js','/speech-check','/speech-check.html','/speech-check.js','/icon.png']);
export const POST = new Set(['/api/pair','/api/send','/api/chats','/api/note','/api/call','/api/call/end','/api/rtc/start','/api/rtc/offer','/api/rtc/candidates','/api/rtc/end','/api/rtc/report']);
export function privateGet(path) {
 return ['/api/state','/api/runtime'].includes(path) || /^\/(avatar|attachment)\/[0-9a-f-]{36}$/i.test(path) || /^\/runtime\/[a-f0-9]{64}\/[a-zA-Z0-9_./-]+$/.test(path) && !path.includes('..');
}
export async function matchesHash(value, expected) {
 if (typeof value !== 'string' || value.length > 256 || !/^[a-f0-9]{64}$/.test(expected || '')) return false;
 const hash = [...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value)))].map(x=>x.toString(16).padStart(2,'0')).join('');
 return hash === expected;
}
export function sessionCookie(headers) {
 return (headers.get('cookie') || '').split(';').map(x=>x.trim()).find(x=>x.startsWith('blessenger='))?.slice(11);
}
export async function boundedBody(request, limit=2_100_000) {
 const reader=request.body?.getReader(); if(!reader) return new Uint8Array();
 const chunks=[];let size=0;
 for(;;){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>limit){await reader.cancel();throw Error('Request too large');}chunks.push(value);}
 const result=new Uint8Array(size);let offset=0;for(const chunk of chunks){result.set(chunk,offset);offset+=chunk.length;}return result;
}
export function base64(bytes){let s='';for(let i=0;i<bytes.length;i+=8192)s+=String.fromCharCode(...bytes.subarray(i,i+8192));return btoa(s);}
export function unbase64(text){return Uint8Array.from(atob(text),c=>c.charCodeAt(0));}
