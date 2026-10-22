import { connectRemoteAudio } from '/remote-audio.mjs';
const status=document.querySelector('#status'),run=document.querySelector('#run');
async function post(path,value){const response=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(value)});if(!response.ok)throw Error('Signaling '+response.status);return response.json();}
run.onclick=async()=>{
  run.disabled=true;let context,peer,tone,stream;const renderTasks=[];const rendering=new AbortController();
  try{
    context=new AudioContext();await context.resume();
    await context.audioWorklet.addModule('/measure.js');
    const measured=[];
    const meter=new AudioWorkletNode(context,'measure');meter.port.onmessage=event=>measured.push(event.data);
    meter.connect(context.destination);
    const outgoing=context.createMediaStreamDestination();
    tone=context.createOscillator();tone.frequency.value=440;
    const gain=context.createGain();gain.gain.value=6000/32768;
    tone.connect(gain).connect(outgoing);tone.start();stream=outgoing.stream;
    peer=new RTCPeerConnection();
    let echo=false;
    peer.ondatachannel=event=>{event.channel.onmessage=message=>{if(message.data==='blessenger-probe'){echo=true;event.channel.send(message.data);}};};
    peer.ontrack=event=>{const task=connectRemoteAudio({context,track:event.track,destination:meter,signal:rendering.signal});task.catch(()=>{});renderTasks.push(task);};
    for(const track of stream.getTracks())peer.addTrack(track,stream);
    status.textContent='Connecting';
    await peer.setRemoteDescription(await post('/start',{}));
    await peer.setLocalDescription(await peer.createAnswer());
    if(peer.iceGatheringState!=='complete')await new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>reject(Error('ICE gathering timeout')),5000);
      peer.onicegatheringstatechange=()=>{if(peer.iceGatheringState==='complete'){clearTimeout(timer);resolve();}};
    });
    await post('/answer',peer.localDescription.toJSON());
    let native=null;
    for(let i=0;i<150&&!native;i++){await new Promise(resolve=>setTimeout(resolve,100));native=await(await fetch('/result')).json();}
    await Promise.all(renderTasks);
    const browser=measured.at(-1);
    const stats=Array.from((await peer.getStats()).values()).filter(x=>['inbound-rtp','outbound-rtp','media-source'].includes(x.type));
    const passed=Boolean(native?.passed&&echo&&browser&&browser.rms>.02&&browser.amplitude>.03&&browser.amplitude>browser.ownAmplitude*10);
    status.textContent=JSON.stringify({passed,native,browser,dataChannelEcho:echo,windows:measured.length,measured,stats,userAgent:navigator.userAgent,
      scope:'Browser/native host-ICE Opus in both directions and data-channel echo. Generated tones, muted output; no microphone, TURN or app integration.'},null,2);
  }catch(error){status.textContent=JSON.stringify({passed:false,error:String(error),stack:error.stack},null,2);}
  finally{rendering.abort();tone?.stop();stream?.getTracks().forEach(track=>track.stop());peer?.close();await context?.close();run.disabled=false;}
};
