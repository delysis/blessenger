import { DurableObject } from 'cloudflare:workers';
import { PUBLIC, POST, privateGet, matchesHash, sessionCookie, boundedBody, base64, unbase64 } from './policy.mjs';
const error=(message,status)=>Response.json({error:message},{status,headers:{'Cache-Control':'no-store'}});
export default {
 async fetch(request,env){
  const url=new URL(request.url);
  if(url.protocol!=='https:') return error('HTTPS required',403);
  if(url.pathname==='/host'){
   if(request.headers.get('Upgrade')?.toLowerCase()!=='websocket' || !await matchesHash(request.headers.get('Authorization')?.replace(/^Bearer /,''),env.HOST_HASH))return error('Unauthorized',401);
   return env.GATEWAY.get(env.GATEWAY.idFromName('mac')).fetch(request);
  }
  if(request.method==='GET' && PUBLIC.has(url.pathname))return env.ASSETS.fetch(request);
  if(!((request.method==='POST'&&POST.has(url.pathname))||(request.method==='GET'&&privateGet(url.pathname))))return error('Not found',404);
  if(request.method==='POST'&&request.headers.get('Origin')!==url.origin)return error('Origin rejected',403);
  if(url.pathname==='/api/pair'){
   let body;try{body=await boundedBody(request,1024);const obj=JSON.parse(new TextDecoder().decode(body));if(!await matchesHash(obj.invite,env.INVITE_HASH))return error('Pairing link is invalid',401);}catch{return error('Invalid request',400);}
   request=new Request(request,{body});
  }else if(!await matchesHash(sessionCookie(request.headers),env.SESSION_HASH))return error('Scan the Mac’s pairing code',401);
  return env.GATEWAY.get(env.GATEWAY.idFromName('mac')).fetch(request);
 }
};
export class Gateway extends DurableObject {
 constructor(ctx,env){super(ctx,env);this.pending=new Map();}
 host(){return this.ctx.getWebSockets('host')[0];}
 async fetch(request){
  if(new URL(request.url).pathname==='/host'){
   // Only the outer Worker can reach this object; it validated HOST_HASH.
   if(this.host())return error('Mac already connected',409);
   const pair=new WebSocketPair();this.ctx.acceptWebSocket(pair[1],['host']);
   this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair('ping','pong'));
   return new Response(null,{status:101,webSocket:pair[0]});
  }
  const host=this.host();if(!host)return error('Mac is offline',503);
  if(this.pending.size>=8)return error('Mac is busy',429);
  // Reserve before awaiting the bounded upload to enforce the concurrency cap.
  const id=crypto.randomUUID(), item={host,resolve:null,controller:null,timer:null,credit:0};this.pending.set(id,item);
  try{
   const body=await boundedBody(request);
   if(this.host()!==host)throw Error('Mac disconnected');
   const headers={};for(const key of ['cookie','content-type','x-blessenger-thread']){const value=request.headers.get(key);if(value&&value.length<8192)headers[key]=value;}
   const response=new Promise(resolve=>{item.resolve=resolve;});
   this.touch(id);
   request.signal.addEventListener('abort',()=>this.fail(id,'Request cancelled'),{once:true});
   host.send(JSON.stringify({type:'request',id,path:new URL(request.url).pathname,method:request.method,headers,body:base64(body)}));
   return await response;
  }catch{this.fail(id,'Gateway request failed');return error('Gateway request failed',502);}
 }
 touch(id){const item=this.pending.get(id);if(!item)return;clearTimeout(item.timer);item.timer=setTimeout(()=>this.fail(id,'Mac response timed out'),30000);}
 fail(id,message){const item=this.pending.get(id);if(!item)return;clearTimeout(item.timer);this.pending.delete(id);item.resolve?.(error(message,502));try{item.controller?.error(Error(message));item.host.send(JSON.stringify({type:'cancel',id}));}catch{}}
 webSocketMessage(ws,message){
  if(typeof message!=='string'||message.length>70000){ws.close(1009,'Frame too large');this.webSocketClose(ws);return;}
  let frame;try{frame=JSON.parse(message);}catch{ws.close(1003,'Invalid frame');this.webSocketClose(ws);return;}
  const item=this.pending.get(frame.id);if(!item||item.host!==ws)return;
  this.touch(frame.id);
  try{
   if(frame.type==='head'){
    if(item.controller||!Number.isInteger(frame.status)||frame.status<200||frame.status>599)throw Error('Invalid headers');
    const headers=new Headers({'Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer'});
    for(const key of ['content-type','content-length','set-cookie','content-security-policy','permissions-policy']){const value=frame.headers?.[key];if(typeof value==='string'&&value.length<8192)headers.set(key,value);}
    const stream=new ReadableStream({start:controller=>{item.controller=controller;},pull:()=>{const count=Math.max(0,Math.min(8,Math.floor(item.controller.desiredSize))-item.credit);if(count){item.credit+=count;ws.send(JSON.stringify({type:'pull',id:frame.id,count}));}},cancel:()=>this.fail(frame.id,'Client disconnected')},{highWaterMark:8});
    item.resolve(new Response(stream,{status:frame.status,headers}));item.resolve=null;
   }else if(frame.type==='chunk'){
    if(!item.controller||item.credit<1||typeof frame.body!=='string'||frame.body.length>65536)throw Error('Unrequested data');
    item.credit--;item.controller.enqueue(unbase64(frame.body));
   }else if(frame.type==='end'){
    if(!item.controller)throw Error('Missing headers');clearTimeout(item.timer);this.pending.delete(frame.id);item.controller.close();
   }else if(frame.type==='error'){this.fail(frame.id,'Mac request failed');}else throw Error('Invalid frame');
  }catch{this.fail(frame.id,'Invalid Mac response');}
 }
 webSocketClose(ws){for(const [id,item]of this.pending)if(item.host===ws)this.fail(id,'Mac disconnected');try{ws.close();}catch{}}
 webSocketError(ws){this.webSocketClose(ws);}
}
