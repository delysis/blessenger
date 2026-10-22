import WebSocket from 'ws';
import {CreditPump,fixedChunks} from './credit-pump.mjs';
import https from 'node:https';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {POST,privateGet} from './policy.mjs';
const endpoint=new URL(process.env.BLESSENGER_GATEWAY_URL || 'https://blessenger.georgewalkeriv.workers.dev');
if(endpoint.protocol!=='https:')throw Error('Gateway requires HTTPS');
const root=path.join(os.homedir(),'Library/Application Support/Blessenger/Companion');
const config=JSON.parse(fs.readFileSync(path.join(root,'configuration.json')));
const token=execFileSync('/usr/bin/security',['find-generic-password','-s','Blessenger.CloudGateway','-a','host','-w'],{encoding:'utf8',stdio:['ignore','pipe','ignore']}).trim();
const ca=fs.readFileSync(path.join(root,'ca.pem'));
const authority=`${config.host}:${config.port}`.toLowerCase();
const sockets=new Set();let stopped=false,attempt=0,ws;
function send(frame){if(ws?.readyState===WebSocket.OPEN)ws.send(JSON.stringify(frame));}
async function connect(){
 const target=new URL('/host',endpoint);target.protocol='wss:';
 ws=new WebSocket(target,{headers:{Authorization:`Bearer ${token}`},maxPayload:3_000_000,handshakeTimeout:15000});
 const jobs=new Map();
 ws.on('open',()=>{attempt=0;console.log('Gateway connected');});
 const heartbeat=setInterval(()=>{if(ws.readyState===WebSocket.OPEN)ws.send('ping');},20000);
 ws.on('message',async data=>{
  if(data.toString()==='pong')return;
  let frame;try{frame=JSON.parse(data.toString());}catch{return ws.close(1003);}
  if(frame.type==='cancel'){jobs.get(frame.id)?.destroy();jobs.delete(frame.id);return;}
  if(frame.type==='pull'){
   const job=jobs.get(frame.id);if(!job?.pump)return;
   try{job.pump.grant(frame.count ?? 1);}catch{ws.close(1008,'Invalid credit');}
   return;
  }
  if(frame.type!=='request'||jobs.size>=8||jobs.has(frame.id)||typeof frame.id!=='string')return ws.close(1008);
  if(!((frame.method==='POST'&&POST.has(frame.path))||(frame.method==='GET'&&privateGet(frame.path))))return ws.close(1008);
  const body=Buffer.from(frame.body||'','base64');if(body.length>2_100_000)return ws.close(1009);
  const headers={Host:authority,'Content-Length':body.length};
  for(const key of ['cookie','content-type','x-blessenger-thread'])if(typeof frame.headers?.[key]==='string')headers[key]=frame.headers[key];
  if(frame.method==='POST')headers.Origin=`https://${authority}`;
  const request=https.request({host:'127.0.0.1',port:config.port,servername:config.host,ca,method:frame.method,path:frame.path,headers,timeout:30000},response=>{
   job.response=response;
   // Demand-driven fixed-size chunks: at most eight 48KiB response chunks are
   // outstanding per request. Pausing the browser stops reading the Mac socket.
   job.pump=new CreditPump(fixedChunks(response),{
    chunk:value=>send({type:'chunk',id:frame.id,body:value.toString('base64')}),
    end:()=>{send({type:'end',id:frame.id});jobs.delete(frame.id);job.destroy();},
    error:()=>{send({type:'error',id:frame.id});jobs.delete(frame.id);job.destroy();}
   });
   const forwarded={};for(const key of ['content-type','content-length','set-cookie','content-security-policy','permissions-policy']){const value=response.headers[key];if(value)forwarded[key]=Array.isArray(value)?value[0]:value;}
   send({type:'head',id:frame.id,status:response.statusCode,headers:forwarded});
  });
  const job={request,response:null,pump:null,destroy(){this.pump?.cancel();request.destroy();this.response?.destroy();sockets.delete(request);}};
  jobs.set(frame.id,job);sockets.add(request);
  request.on('timeout',()=>request.destroy(Error('timeout')));
  request.on('error',()=>{if(jobs.delete(frame.id))send({type:'error',id:frame.id});job.destroy();});
  request.end(body);
 });
 ws.on('error',()=>console.error('Gateway unavailable; reconnecting'));
 ws.on('close',()=>{clearInterval(heartbeat);for(const job of jobs.values())job.destroy();jobs.clear();if(!stopped)setTimeout(connect,Math.min(30000,1000*2**Math.min(attempt++,5))+Math.random()*500);});
}
function stop(){stopped=true;for(const request of sockets)request.destroy();ws?.close(1000,'Mac stopped');setTimeout(()=>process.exit(0),500).unref();}
process.on('SIGINT',stop);process.on('SIGTERM',stop);connect();
