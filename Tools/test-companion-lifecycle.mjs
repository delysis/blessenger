import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const rtcSource = fs.readFileSync(new URL('../Sources/CallGemma/Resources/Web/companion-rtc.js', import.meta.url), 'utf8').replace('export class CompanionRTC', 'class CompanionRTC');
const source = fs.readFileSync(new URL('../Sources/CallGemma/Resources/Web/companion.js', import.meta.url), 'utf8')
  .replace("import { CompanionRTC } from '/rtc.js';", rtcSource)
  .replace(/start\(\)\.catch\(fail\);setInterval\([^\n]+\n/, ''); // Explicitly drive the real handlers below; no polling/network bootstrap.
function deferred() { let resolve; const promise = new Promise(r => resolve = r); return { promise, resolve }; }
function fixture() {
  const permission = deferred(), rendered = deferred(), admitted = deferred();
  let endResponse = Promise.resolve({});
  let stopped = 0, closed = 0;
  const calls = [], nodes = new Map();
  function element(id) {
    if (!nodes.has(id)) nodes.set(id, { value:'', hidden:false, disabled:false, style:{}, addEventListener(){}, setAttribute(){}, getContext(){return { clearRect(){}, fillRect(){} };}, width:400, height:44 });
    return nodes.get(id);
  }
  const stream = { getTracks: () => [{ stop(){stopped++;} }], getAudioTracks: () => [{getSettings:()=>({echoCancellation:true})}] };
  class Context {
    constructor(){this.state='running';this.sampleRate=48000;this.audioWorklet={addModule:async()=>{}};}
    createMediaStreamSource(){return {connect(){return {connect(){return {connect(){}};}};}};}
    createGain(){return {gain:{value:0}};}
    async resume(){}
    async close(){this.state='closed';closed++;}
  }
  class Offline {
    createBuffer(){return {copyToChannel(){}};}
    createBufferSource(){return {connect(){},start(){}};}
    startRendering(){return rendered.promise;}
  }
  const context = vm.createContext({console, Float32Array, ArrayBuffer, DataView, Blob,
    URL:{createObjectURL:()=> 'blob:test',revokeObjectURL(){}}, Audio:class {pause(){}},
    AudioContext:Context,OfflineAudioContext:Offline,
    AudioWorkletNode:class {connect(){} constructor(){this.port={postMessage:()=>this.port.onmessage({data:{flushed:true}})}}},
    RTCPeerConnection:class {
      addTrack(){} createDataChannel(){return this.channel={readyState:'connecting',send(){},close(){}};}
      async createOffer(){return {sdp:'offer'};} async setLocalDescription(value){this.localDescription=value;}
      async setRemoteDescription(){this.channel.readyState='open';this.channel.onopen();} close(){}
    },
    document:{getElementById:element},window:{isSecureContext:true,addEventListener(){}},
    navigator:{mediaDevices:{getUserMedia:()=>permission.promise}},
    setInterval:()=>1,clearInterval(){},setTimeout,clearTimeout,requestAnimationFrame(){},
    fetch:async(path,options)=>{calls.push({path,body:JSON.parse(options.body)});return {ok:true,json:()=>path==='/api/call'?admitted.promise:path==='/api/rtc/start'?Promise.resolve({id:'rtc',iceServers:[]}):path==='/api/rtc/offer'?Promise.resolve({sdp:'answer'}):path==='/api/rtc/end'?endResponse:Promise.resolve({})};}
  });
  vm.runInContext(source,context);
  vm.runInContext("selected='original';",context);
  return {delayEnd(value){endResponse=value;},context,permission,rendered,admitted,stream,calls,element,get stopped(){return stopped;},get closed(){return closed;},run:s=>vm.runInContext(s,context)};
}
const tick = () => new Promise(resolve=>setImmediate(resolve));
{
  const f=fixture(); const start=f.element('record').onclick();
  await f.run('discard()'); f.permission.resolve(f.stream); await start;
  assert.equal(f.stopped,1,'Late microphone permission must release the cancelled capture');
  assert.equal(f.run('recording'),null);
}
{
  const f=fixture(); f.permission.resolve(f.stream); await f.element('record').onclick();
  f.run('recording.node.port.onmessage({data:new Float32Array(128)});');
  const stop=f.element('stop').onclick(); await tick();
  await f.run('discard()'); f.rendered.resolve({getChannelData:()=>new Float32Array(40)}); await stop;
  assert.equal(f.run('note'),null,'Cancelled asynchronous conversion must not resurrect a voice note');
  assert.equal(f.element('voice').hidden,true);
}
{
  const f=fixture(); f.permission.resolve(f.stream); await f.element('record').onclick();
  f.run("open('another');");
  assert.equal(f.run('selected'),'original','Recording cannot silently change recipient');
  f.run('recording.node.port.onmessage({data:new Float32Array(128)});');
  f.rendered.resolve({getChannelData:()=>new Float32Array(40)}); await f.element('stop').onclick();
  assert.equal(f.run('noteDestination.thread'),'original');
  await f.run('discard()');
}
{
  const f=fixture(); const start=f.element('call').onclick(); await tick();
  await f.run('endCall()'); f.permission.resolve(f.stream); await start;
  assert.equal(f.stopped,1); assert.equal(f.calls.length,0,'Cancelled permission cannot start a server call');
}
{
  const f=fixture(); f.permission.resolve(f.stream); const start=f.element('call').onclick(); await tick();
  assert(f.calls.some(c=>c.path==='/api/call')); await f.run('endCall()');
  assert.equal(f.element('call').disabled,true,'Pending call admission still owns the audio session after hang-up');
  const count=f.calls.length; await f.element('call').onclick();
  assert.equal(f.calls.length,count,'Retry cannot overtake late admission');
  f.admitted.resolve({id:'late-call',epoch:'epoch'}); await start;
  assert.equal(f.calls.find(c=>c.path==='/api/call/end').body.id,'late-call','A late admitted call must be ended by its own identity');
  assert.equal(f.run('call'),null);
}
console.log('PASS microphone permission cancellation, conversion cancellation, recipient ownership, and late call admission cleanup.');

{
  const f=fixture(); f.permission.resolve(f.stream); f.admitted.resolve({id:'call',epoch:'epoch'});
  await f.element('call').onclick();
  const released=deferred(); f.delayEnd(released.promise);
  const ending=f.run('endCall()'); await tick();
  assert.equal(f.element('call').disabled,true,'Retry stays disabled until server teardown completes');
  const count=f.calls.length; await f.element('call').onclick();
  assert.equal(f.calls.length,count,'Programmatic retry also cannot overlap teardown');
  released.resolve({}); await ending;
  assert.equal(f.element('call').disabled,false,'Retry becomes available after teardown');
}
console.log('PASS actual RTC lifecycle blocks retry until server teardown completes.');
