const CACHE='blessenger-shell-v2';
const SHELL=['/','/app.js','/rtc.js','/style.css','/icon.png','/manifest.webmanifest'];
self.addEventListener('install',event=>event.waitUntil(caches.open(CACHE).then(cache=>cache.addAll(SHELL))));
self.addEventListener('activate',event=>event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k.startsWith('blessenger-shell-')&&k!==CACHE).map(k=>caches.delete(k))))));
// Never persist private messages, authentication responses, voice or avatars.
self.addEventListener('fetch',event=>{const url=new URL(event.request.url);if(event.request.method!=='GET'||url.origin!==location.origin||!SHELL.includes(url.pathname))return;event.respondWith(fetch(event.request).catch(()=>caches.match(event.request)))});
