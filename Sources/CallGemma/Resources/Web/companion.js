import { CompanionRTC } from '/rtc.js';
const $=id=>document.getElementById(id);
const canCapture = window.isSecureContext && !!navigator.mediaDevices;
for (const id of ['call','record']) if (!canCapture) { $(id).title = 'Voice requires trusted HTTPS'; $(id).setAttribute('aria-description', 'Voice requires trusted HTTPS'); }
let state={contacts:[],threads:[],messages:[],generating:[]},selected=null,recipients=[],composing=false,lastMessages='',sending=false;
function fail(error){$('error').textContent=error.message||String(error);$('error').hidden=false;setTimeout(()=>$('error').hidden=true,8000)}
async function api(path,body){const response=await fetch(path,{method:body?'POST':'GET',headers:body?{'Content-Type':'application/json'}:{},body:body?JSON.stringify(body):undefined,cache:'no-store'});const value=await response.json();if(!response.ok)throw Error(value.error||'Connection unavailable');return value}
function avatar(id){return state.contacts.find(c=>c.id===id)?.avatar}
function image(id){const img=document.createElement('img');img.className='portrait';img.alt='';const src=avatar(id);if(src)img.src=src;return img}
function open(id){if(mediaBusy())return;selected=id;composing=false;lastMessages='';$('recipients').hidden=true;document.body.classList.add('chat-open');render()}
function render() {
  const query = $('search').value.toLocaleLowerCase();
  $('threads').replaceChildren();
  for (const thread of state.threads.filter(t => t.title.toLocaleLowerCase().includes(query))) {
    const row = document.createElement('button');
    row.classList.toggle('selected', thread.id === selected);
    row.append(image(thread.participants[0]));
    const name = document.createElement('span');
    name.className = 'thread-name'; name.textContent = thread.title;
    row.append(name); row.onclick = () => open(thread.id); $('threads').append(row);
  }
  const thread = state.threads.find(t => t.id === selected);
  $('title').textContent = composing ? 'New Message' : thread?.title || 'Blessenger';
  const src = avatar(thread?.participants[0]);
  if (src) $('avatar').src = src; else $('avatar').removeAttribute('src');
  const messages = state.messages.filter(m => m.thread === selected);
  const signature = JSON.stringify([selected, messages, state.generating.includes(selected)]);
  if (signature !== lastMessages) {
    const list = $('messages');
    const atEnd = list.scrollHeight - list.scrollTop - list.clientHeight < 80;
    lastMessages = signature;
    const visible = new Set(messages.map(m => m.id));
    for (const node of [...list.children]) {
      if (!visible.has(node.dataset.message)) { node.querySelector('audio')?.pause(); node.remove(); }
    }
    for (const message of messages) {
      let bubble = [...list.children].find(node => node.dataset.message === message.id);
      if (bubble) continue; // Preserve active audio and its playback position during polling.
      bubble = document.createElement('article');
      bubble.dataset.message = message.id;
      bubble.className = 'message' + (message.sender ? '' : ' own');
      if (message.sender && thread?.participants.length > 1) {
        const who = document.createElement('div'); who.className = 'sender';
        who.textContent = state.contacts.find(c => c.id === message.sender)?.name || '';
        bubble.append(who);
      }
      const text = document.createElement('span'); text.textContent = message.text; bubble.append(text);
      for (const attachment of message.attachments) {
        if (attachment.kind === 'audio') bubble.append(voiceAttachment(attachment));
        else { const link = document.createElement('a'); link.textContent = attachment.name; link.href = attachment.url; bubble.append(link); }
      }
      list.append(bubble);
    }
    if (state.generating.includes(selected)) {
      const pending = document.createElement('div'); pending.className = 'pending';
      pending.textContent = '•••'; pending.setAttribute('aria-label','Replying'); list.append(pending);
    }
    if (atEnd || messages.length < 3) list.scrollTop = list.scrollHeight;
  }
  $('record').disabled = !selected && !recipients.length;
  $('call').disabled = !selected && !call && !recipients.length;
  updateSend();
}
function voiceAttachment(attachment) {
  const row = document.createElement('div'); row.className = 'voice-message';
  const audio = document.createElement('audio'); audio.src = attachment.url; audio.preload = 'metadata'; audio.hidden = true;
  const play = document.createElement('button'); play.textContent = '▶'; play.setAttribute('aria-label','Play voice note');
  play.onclick = () => audio.paused ? audio.play().catch(fail) : audio.pause();
  const canvas = document.createElement('canvas'); canvas.width = 320; canvas.height = 40;
  canvas.tabIndex = 0; canvas.setAttribute('role','slider'); canvas.setAttribute('aria-label','Voice note position');
  canvas.setAttribute('aria-valuemin','0'); canvas.setAttribute('aria-valuemax','100');
  let peaks = Array(50).fill(.04), frame;
  function draw() {
    cancelAnimationFrame(frame);
    const ctx = canvas.getContext('2d'), progress = Number.isFinite(audio.duration) ? audio.currentTime/audio.duration : 0;
    ctx.clearRect(0,0,320,40);
    peaks.forEach((peak,i) => { const height = Math.max(3,peak*36); ctx.fillStyle = i/peaks.length < progress ? (row.closest('.own') ? '#fff' : '#007aff') : '#a4b5cc'; ctx.fillRect(i*6.4,20-height/2,3,height); });
    canvas.setAttribute('aria-valuenow',String(Math.round(progress*100)));
    if (!audio.paused) frame = requestAnimationFrame(draw);
  }
  canvas.onpointerdown = event => { if (Number.isFinite(audio.duration)) { const rect = canvas.getBoundingClientRect(); audio.currentTime = Math.max(0,Math.min(1,(event.clientX-rect.left)/rect.width))*audio.duration; draw(); } };
  canvas.onkeydown = event => { if (['ArrowLeft','ArrowRight'].includes(event.key) && Number.isFinite(audio.duration)) { event.preventDefault(); audio.currentTime = Math.max(0,Math.min(audio.duration,audio.currentTime+(event.key==='ArrowRight'?5:-5))); draw(); } };
  audio.onplay = () => { play.textContent = 'Ⅱ'; play.setAttribute('aria-label','Pause voice note'); cancelAnimationFrame(frame); draw(); };
  audio.onpause = () => { play.textContent = '▶'; play.setAttribute('aria-label','Play voice note'); cancelAnimationFrame(frame); draw(); };
  audio.onseeked = () => { cancelAnimationFrame(frame); draw(); };
  fetch(attachment.url).then(r=>{if(!r.ok)throw Error('Voice note unavailable');return r.arrayBuffer()}).then(data=>new OfflineAudioContext(1,1,24000).decodeAudioData(data)).then(buffer=>{
    const samples=buffer.getChannelData(0); peaks=peaks.map((_,i)=>{let peak=0;for(let j=Math.floor(i*samples.length/50);j<Math.floor((i+1)*samples.length/50);j++)peak=Math.max(peak,Math.abs(samples[j]));return peak});
    const maximum=Math.max(.01,...peaks);peaks=peaks.map(p=>p/maximum);draw();
  }).catch(fail);
  row.append(play,canvas,audio);draw();return row;
}
function mediaBusy() { return !!(call || callStarting || callEnding || recording || note || sending); }
function updateSend() {
  const busy = mediaBusy();
  $('back').disabled = busy;
  $('compose').disabled = busy;
  $('call').disabled = !call && (!canCapture || busy || (!selected && !recipients.length));
  $('record').disabled = !canCapture || busy || (!selected && !recipients.length);
  $('send').disabled = busy || !$('draft').value.trim() || (!selected && !recipients.length);
  $('recipient').disabled = busy;
}
function suggest(){const query=$('recipient').value.toLocaleLowerCase();$('suggestions').replaceChildren();for(const contact of state.contacts.filter(c=>!recipients.includes(c.id)&&c.name.toLocaleLowerCase().includes(query))){const button=document.createElement('button');button.setAttribute('role','option');button.append(image(contact.id),document.createTextNode(contact.name));button.onclick=()=>{recipients.push(contact.id);$('recipient').value='';chips();suggest();updateSend();$('recipient').focus()};$('suggestions').append(button)}}
function chips(){$('chips').replaceChildren();for(const id of recipients){const button=document.createElement('button');button.textContent=state.contacts.find(c=>c.id===id).name+' ×';button.onclick=()=>{recipients=recipients.filter(x=>x!==id);chips();suggest();updateSend()};$('chips').append(button)}}
$('compose').onclick=()=>{selected=null;recipients=[];composing=true;lastMessages='';$('recipients').hidden=false;document.body.classList.add('chat-open');chips();suggest();render();$('recipient').focus()};$('back').onclick=()=>document.body.classList.remove('chat-open');$('search').oninput=render;$('recipient').oninput=suggest;$('recipient').onkeydown=event=>{if(['Enter','Tab'].includes(event.key)&&$('suggestions').firstElementChild){event.preventDefault();$('suggestions').firstElementChild.click()}};$('draft').oninput=()=>{updateSend();$('draft').style.height='auto';$('draft').style.height=Math.min($('draft').scrollHeight,140)+'px'};$('draft').onkeydown=event=>{if(event.key==='Enter'&&!event.shiftKey&&!event.isComposing&&matchMedia('(pointer:fine)').matches){event.preventDefault();$('composer').requestSubmit()}};
$('composer').onsubmit=async event=>{event.preventDefault();if($('send').disabled)return;const text=$('draft').value;sending=true;updateSend();try{if(!selected){const created=await api('/api/chats',{contacts:recipients});selected=created.id;composing=false;$('recipients').hidden=true}await api('/api/send',{thread:selected,text});$('draft').value='';await refresh()}catch(error){fail(error)}finally{sending=false;updateSend()}};
async function refresh(){state=await api('/api/state');$('connection').className='online';$('connection').setAttribute('aria-label','Connected');render()}
async function start(){const invite=location.hash.slice(1);if(invite){history.replaceState(null,'',location.pathname);await api('/api/pair',{invite})}await refresh();if('serviceWorker'in navigator)await navigator.serviceWorker.register('/sw.js')}
start().catch(fail);setInterval(()=>refresh().catch(()=>{$('connection').className='';$('connection').setAttribute('aria-label','Disconnected')}),1800);
let recording = null, note = null, noteURL = null, preview = null, noteDestination = null;
function destination() { return { thread: selected, contacts: [...recipients] }; }
async function destinationThread(target) {
  return target.thread || (await api('/api/chats', { contacts: target.contacts })).id;
}
async function releaseCapture(current) {
  clearInterval(current?.timer);
  const closing = current?.rtc?.close();
  current?.stream?.getTracks().forEach(track => track.stop());
  if (current) current.stream = null;
  if (current?.context && current.context.state !== 'closed') await current.context.close();
  await closing;
}
function wave(samples,color='#8e8e93'){const canvas=$('wave'),ctx=canvas.getContext('2d');ctx.clearRect(0,0,canvas.width,canvas.height);ctx.fillStyle=color;for(let x=0;x<canvas.width;x+=6){const start=Math.floor(x/canvas.width*samples.length),end=Math.max(start+1,Math.floor((x+6)/canvas.width*samples.length));let peak=0;for(let j=start;j<end;j++)peak=Math.max(peak,Math.abs(samples[j]||0));const height=Math.max(3,Math.min(40,peak*100));ctx.fillRect(x,(44-height)/2,3,height)}}
async function discard() {
  const previous = recording;
  recording = null; // Invalidate ownership before any asynchronous cleanup.
  preview?.pause(); preview = null;
  if (noteURL) URL.revokeObjectURL(noteURL);
  noteURL = null; note = null; noteDestination = null;
  $('voice').hidden = true; $('composer').hidden = false;
  updateSend();
  await releaseCapture(previous);
}
$('discard').onclick = () => { if (!sending) discard().catch(fail); };
$('record').onclick = async () => {
  if (mediaBusy() || (!selected && !recipients.length)) return;
  const current = { destination: destination(), chunks: [], frames: 0 };
  recording = current;
  updateSend();
  try {
    if (!window.isSecureContext || !navigator.mediaDevices) throw Error('Microphone access requires trusted HTTPS.');
    current.stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, channelCount: 1 } });
    if (recording !== current) { await releaseCapture(current); return; }
    current.context = new AudioContext();
    await current.context.audioWorklet.addModule('/recorder.js');
    if (recording !== current) return;
    const source = current.context.createMediaStreamSource(current.stream);
    const node = current.node = new AudioWorkletNode(current.context, 'recorder');
    const gain = current.context.createGain(); gain.gain.value = 0;
    source.connect(node).connect(gain).connect(current.context.destination);
    node.port.onmessage = ({ data }) => {
      if (recording !== current) return;
      if (data.flushed) { current.flush?.(); return; }
      current.chunks.push(data); current.frames += data.length;
      wave(data, '#ff3b30');
    };
    await current.context.resume();
    if (recording !== current) return;
    current.start = Date.now();
    current.timer = setInterval(() => {
      const seconds = Math.floor((Date.now() - current.start) / 1000);
      $('elapsed').textContent = Math.floor(seconds / 60) + ':' + String(seconds % 60).padStart(2, '0');
      if (seconds >= 59) $('stop').click();
    }, 250);
    $('elapsed').textContent = '0:00';
    $('voice').hidden = false; $('composer').hidden = true;
    $('stop').hidden = false; $('preview').hidden = true; $('send-note').hidden = true;
  } catch (error) {
    if (recording === current) { await discard(); fail(error); }
  } finally {
    if (recording !== current) await releaseCapture(current);
  }
};
function wav(pcm) {
  const data = new ArrayBuffer(44 + pcm.length * 2), view = new DataView(data);
  function str(offset, text) { for (let i = 0; i < text.length; i++) view.setUint8(offset + i, text.charCodeAt(i)); }
  str(0, 'RIFF'); view.setUint32(4, data.byteLength - 8, true); str(8, 'WAVEfmt ');
  view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
  view.setUint32(24, 16000, true); view.setUint32(28, 32000, true); view.setUint16(32, 2, true);
  view.setUint16(34, 16, true); str(36, 'data'); view.setUint32(40, pcm.length * 2, true);
  for (let i = 0; i < pcm.length; i++) view.setInt16(44 + i * 2, Math.max(-32768, Math.min(32767, Math.round(pcm[i] * 32767))), true);
  return new Blob([data], { type: 'audio/wav' });
}
$('stop').onclick = async () => {
  const current = recording;
  if (!current?.node || current.stopping) return;
  current.stopping = true; clearInterval(current.timer);
  let timeout;
  try {
    await Promise.race([
      new Promise(resolve => { current.flush = resolve; current.node.port.postMessage({ flush: true }); }),
      new Promise((_, reject) => { timeout = setTimeout(() => reject(Error('Recording could not finish.')), 2000); })
    ]);
    if (recording !== current) return;
    await releaseCapture(current);
    if (recording !== current) return;
    if (!current.frames) { await discard(); return; }
    const offline = new OfflineAudioContext(1, Math.ceil(current.frames * 16000 / current.context.sampleRate), 16000);
    const buffer = offline.createBuffer(1, current.frames, current.context.sampleRate);
    let offset = 0;
    for (const chunk of current.chunks) { buffer.copyToChannel(chunk, 0, offset); offset += chunk.length; }
    const source = offline.createBufferSource(); source.buffer = buffer; source.connect(offline.destination); source.start();
    const pcm = (await offline.startRendering()).getChannelData(0);
    if (recording !== current) return;
    note = wav(pcm); noteDestination = current.destination;
    recording = null;
    noteURL = URL.createObjectURL(note); preview = new Audio(noteURL); wave(pcm);
    $('stop').hidden = true; $('preview').hidden = false; $('send-note').hidden = false;
    updateSend();
  } catch (error) {
    if (recording === current) { await discard(); fail(error); }
  } finally { clearTimeout(timeout); }
};
$('preview').onclick = () => { if (preview) { if (preview.paused) preview.play().catch(fail); else preview.pause(); } };
$('send-note').onclick = async () => {
  if (!note || sending) return;
  const payload = note, target = noteDestination;
  sending = true; $('send-note').disabled = true; $('discard').disabled = true; updateSend();
  try {
    const thread = await destinationThread(target);
    const response = await fetch('/api/note', { method: 'POST', headers: { 'Content-Type': 'audio/wav', 'X-Blessenger-Thread': thread }, body: payload });
    if (!response.ok) throw Error((await response.json()).error || 'Voice note failed');
    selected = thread; composing = false; $('recipients').hidden = true;
    await discard(); await refresh();
  } catch (error) { fail(error); }
  finally { sending = false; $('send-note').disabled = false; $('discard').disabled = false; updateSend(); }
};
let call = null, callStarting = false, callEnding = false;
async function endCall() {
  const previous = call;
  call = null;
  if (previous) callEnding = true;
  $('call').textContent = '☎'; $('call').setAttribute('aria-label', 'Call'); updateSend();
  if (!previous) return;
  try {
    await releaseCapture(previous);
    if (previous.id) await api('/api/call/end', { id: previous.id }).catch(fail);
  } finally { callEnding = false; updateSend(); }
}
$('call').onclick = async () => {
  if (call) { await endCall(); return; }
  if (mediaBusy() || (!selected && !recipients.length)) return;
  const current = { destination: destination(), input: [], ack: [], lastReceived: -1, sequence: 0 };
  call = current; callStarting = true;
  $('call').textContent = '×'; $('call').setAttribute('aria-label', 'Hang up'); updateSend();
  try {
    const thread = await destinationThread(current.destination);
    if (call !== current) return;
    selected = thread; composing = false; $('recipients').hidden = true;
    current.stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true, channelCount: 1 } });
    if (call !== current) return;
    const context = current.context = new AudioContext();
    await context.audioWorklet.addModule('/call-audio.js');
    if (call !== current) return;
    const node = current.node = new AudioWorkletNode(context, 'call-audio');
    node.connect(context.destination);
    await context.resume();
    if (call !== current) return;
    current.rtc = new CompanionRTC(api, result => {
      if (call !== current || !current.id) return;
      if (result.closed) { endCall(); return; }
      if (result.id !== current.id || typeof result.epoch !== 'string' || !Array.isArray(result.packets) || result.packets.length > 1) throw Error('Invalid call response');
      if (result.epoch !== current.epoch) { current.epoch = result.epoch; current.ack = []; current.lastReceived = -1; }
      const packets = result.packets.filter(packet => packet.sequence > current.lastReceived);
      for (const packet of packets) {
        if (!Number.isInteger(packet.sequence) || !Array.isArray(packet.samples) || packet.samples.length > 1920 || !packet.samples.every(Number.isFinite)) throw Error('Invalid playback packet');
        current.lastReceived = packet.sequence;
      }
      node.port.postMessage({ epoch: current.epoch, packets });
    }, error => { if (call === current) { fail(error); endCall(); } });
    await current.rtc.open(current.stream);
    if (call !== current) return;
    Object.assign(current, await api('/api/call', { thread, rtc: current.rtc.id }));
    if (call !== current) {
      await api('/api/call/end', { id: current.id });
      return;
    }
    node.port.onmessage = ({ data }) => {
      if (call !== current) return;
      if (data.played !== undefined && data.epoch === current.epoch) current.ack.push(data.played);
    };
    current.timer = setInterval(() => {
      if (call !== current) return;
      try { current.rtc.send({ epoch: current.epoch, acknowledged: current.ack.splice(0) }); }
      catch (error) { fail(error); endCall(); }
    }, 25);

  } catch (error) {
    if (call === current) { fail(error); await endCall(); }
  } finally {
    try { if (call !== current) await releaseCapture(current); }
    finally { callStarting = false; updateSend(); }
  }
};
window.addEventListener('pagehide', () => {
  discard().catch(() => {});
  const previous = call; call = null;
  if (previous) {
    releaseCapture(previous).catch(() => {});
    if (previous.id) fetch('/api/call/end', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id: previous.id }), keepalive: true }).catch(() => {});
  }
});

function sizeViewport(){if(window.visualViewport)$('app').style.height=window.visualViewport.height+'px'}
window.visualViewport?.addEventListener('resize',sizeViewport);sizeViewport();

$('recipient').addEventListener('focus',()=>{$('suggestions').hidden=false});
$('recipients').addEventListener('focusout',()=>requestAnimationFrame(()=>{if(document.activeElement!==$('recipient')&&!$('suggestions').contains(document.activeElement))$('suggestions').hidden=true}));
