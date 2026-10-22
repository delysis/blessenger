import { CompanionRTC } from '/rtc.js';
const button=document.querySelector('#start'), output=document.querySelector('#result');
async function api(path,body){const response=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});const value=await response.json();if(!response.ok)throw Error(value.error||`HTTP ${response.status}`);return value;}
button.onclick=async()=>{
 button.disabled=true;output.textContent='Connecting';
 let rtc,context,source,timer,call,failed,frames=0,rendered=0,last=-1,epoch='',lastPacket=0,firstPacket;
 const ack=[];const start=performance.now();
 try{
  const fixture=await api('/fixture',{});
  context=new AudioContext();await context.audioWorklet.addModule('/call-audio.js');
  const node=new AudioWorkletNode(context,'call-audio'),gain=context.createGain();gain.gain.value=0;node.connect(gain).connect(context.destination);
  const destination=context.createMediaStreamDestination();source=context.createConstantSource();source.offset.value=0;source.connect(destination);source.start();await context.resume();
  const lengths=new Map();
  node.port.onmessage=({data})=>{if(data.epoch===epoch&&data.played!==undefined){ack.push(data.played);rendered+=lengths.get(data.played)||0;lengths.delete(data.played);}};
  rtc=new CompanionRTC(api,result=>{
   if(!call)return;
   if(result.closed)throw Error('Call closed unexpectedly');
   if(result.epoch!==epoch){epoch=result.epoch;last=-1;ack.length=0;lengths.clear();}
   const packets=result.packets.filter(packet=>packet.sequence>last);
   for(const packet of packets){last=packet.sequence;frames+=packet.samples.length;lengths.set(last,packet.samples.length);firstPacket??=performance.now();lastPacket=performance.now();}
   node.port.postMessage({epoch,packets});
  },error=>{failed=error;});
  await rtc.open(destination.stream);const connectedMS=performance.now()-start;
  output.textContent='Connected; awaiting greeting';
  call=await api('/api/call',{thread:fixture.thread,rtc:rtc.id});epoch=call.epoch;
  timer=setInterval(()=>{try{rtc.send({epoch,acknowledged:ack.splice(0)});}catch(error){failed=error;}},25);
  while(performance.now()-start<45000){
   if(failed)throw failed;
   if(frames>12000&&rendered===frames&&performance.now()-lastPacket>1500)break;
   await new Promise(resolve=>setTimeout(resolve,50));
  }
  if(frames<=12000||rendered!==frames)throw Error('Greeting did not render completely');
  output.textContent=JSON.stringify({passed:true,connectedMS,firstPacketMS:firstPacket-start,frames,rendered,scope:'Actual app 12B, browser WebRTC microphone transport and muted AudioWorklet output; synthetic silence, not acoustic or iPhone acceptance'},null,2);
 }catch(error){output.textContent=JSON.stringify({passed:false,error:error.message,frames,rendered},null,2);}
 finally{clearInterval(timer);rtc?.close();source?.stop();await context?.close();if(call)await api('/api/call/end',{id:call.id}).catch(()=>{});button.disabled=false;}
};
