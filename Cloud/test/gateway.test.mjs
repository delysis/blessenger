import {test} from 'node:test';import assert from 'node:assert/strict';
import {Miniflare} from 'miniflare';import fs from 'node:fs';
const hash=async text=>Buffer.from(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(text))).toString('hex');
test('Worker rejects unauthenticated traffic and requires authentication, streams with credits, and recovers after host disconnect',async()=>{
 const root=new URL('../',import.meta.url);
 const mf=new Miniflare({workers:[{name:'test',modules:[{type:'ESModule',path:'worker.mjs',contents:fs.readFileSync(new URL('worker.mjs',root),'utf8')},{type:'ESModule',path:'policy.mjs',contents:fs.readFileSync(new URL('policy.mjs',root),'utf8')}],compatibilityDate:'2026-10-20',durableObjects:{GATEWAY:{className:'Gateway',useSQLite:true}},bindings:{HOST_HASH:await hash('host-test'),INVITE_HASH:await hash('invite-test'),SESSION_HASH:await hash('session-test')}}]});
 try{
 const request=async(path,options={})=>{console.log('request',path);const r=await mf.dispatchFetch('https://unit.test'+path,options);console.log('response',path,r.status);return r;};
 assert.equal((await request('/api/state')).status,401);
 assert.equal((await request('/host',{headers:{Upgrade:'websocket'}})).status,401);
 assert.equal((await request('/api/pair',{method:'POST',headers:{Origin:'https://evil.test'},body:'{}'})).status,403);
 const auth={Cookie:'blessenger=session-test'};
 assert.equal((await request('/api/state',{headers:auth})).status,503);
 const connected=await request('/host',{headers:{Upgrade:'websocket',Authorization:'Bearer host-test'}});
 assert.equal(connected.status,101);const ws=connected.webSocket;ws.accept();
 assert.equal((await request('/host',{headers:{Upgrade:'websocket',Authorization:'Bearer host-test'}})).status,409);
 assert.equal((await request('/api/pair',{method:'POST',headers:{Origin:'https://unit.test','Content-Type':'application/json'},body:JSON.stringify({invite:'wrong'})})).status,401);
 const frames=[];let wake;
 ws.addEventListener('message',event=>{const f=JSON.parse(event.data);console.log('frame',f.type);frames.push(f);wake?.();});
 async function next(){while(!frames.length)await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('Host frame timeout')),5000);wake=()=>{clearTimeout(timer);resolve();};});return frames.shift();}
 const pending=request('/api/state',{headers:auth});
 console.log('waiting for host request');const frame=await next();console.log('host request received');assert.equal(frame.type,'request');assert.equal(frame.path,'/api/state');
 ws.send(JSON.stringify({type:'head',id:frame.id,status:200,headers:{'content-type':'application/json'}}));
 const response=await pending;assert.equal(response.status,200);
 const text=response.text();
 const credit=await next();assert.equal(credit.type,'pull');assert.equal(credit.count,8);
 ws.send(JSON.stringify({type:'chunk',id:frame.id,body:Buffer.from('{"ready":true}').toString('base64')}));
 assert.equal((await next()).type,'pull');ws.send(JSON.stringify({type:'end',id:frame.id}));
 assert.equal(await text,'{"ready":true}');
 const disconnected=request('/api/state',{headers:auth});await next();ws.close();assert.equal((await disconnected).status,502);
 const reconnected=await request('/host',{headers:{Upgrade:'websocket',Authorization:'Bearer host-test'}});
 assert.equal(reconnected.status,101);const replacement=reconnected.webSocket;replacement.accept();
 let activeID;
 replacement.addEventListener('message',event=>{
  const f=JSON.parse(event.data);
  if(f.type==='request'){activeID=f.id;replacement.send(JSON.stringify({type:'head',id:f.id,status:200,headers:{}}));}
  else if(f.type==='pull')replacement.send(JSON.stringify({type:'end',id:f.id}));
 });
 const recovered=await request('/api/state',{headers:auth});assert.equal(recovered.status,200);assert.equal(await recovered.text(),'');
 assert.notEqual(activeID,frame.id,'Reconnect must not replay the earlier request');replacement.close();
 }catch(e){console.error('TEST FAILURE',e);throw e;}finally{await mf.dispose();}
});
