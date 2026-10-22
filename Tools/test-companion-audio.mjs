import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const root = new URL('../Sources/CallGemma/Resources/Web/', import.meta.url);
function processor(file, rate = 48000) {
  let Registered;
  const events=[];
  const context=vm.createContext({sampleRate:rate,Float32Array,AudioWorkletProcessor:class {constructor(){this.port={postMessage:value=>events.push(value)}}},registerProcessor:(_,type)=>Registered=type});
  vm.runInContext(fs.readFileSync(new URL(file,root),'utf8'),context);
  return {node:new Registered(),events};
}
const capture=processor('companion-recorder.js');
capture.node.process([[new Float32Array(128).fill(.2)]]);
capture.node.port.onmessage({data:{flush:true}});
assert.equal(capture.events[0].length,128,'Short final microphone block must not be clipped');
assert.equal(capture.events[1].flushed,true);
const call=processor('companion-call-audio.js');
call.node.port.onmessage({data:{epoch:'old',packets:[{sequence:0,samples:Array(1920).fill(.5)}]}});
const output=new Float32Array(128);
call.node.process([[new Float32Array(128)]],[[output]]);
assert(output.every(x=>x===.5));
assert.equal(call.events.filter(e=>e.played!==undefined).length,0,'Do not acknowledge queued sound');
call.node.port.onmessage({data:{epoch:'new',packets:[]}});
call.node.process([[new Float32Array(128)]],[[output]]);
assert(output.every(x=>x===0),'Cancellation must discard old queued sound');
call.node.port.onmessage({data:{epoch:'new',packets:[{sequence:1,samples:Array(1920).fill(.25)}]}});
for(let i=0;i<30;i++)call.node.process([[new Float32Array(128)]],[[output]]);
assert.equal(call.events.filter(e=>e.played===0).length,0);
assert.equal(call.events.filter(e=>e.played===1&&e.epoch==='new').length,1);
console.log('PASS final capture block preserved; playback acknowledges rendering; cancellation drops old audio without acknowledging it.');

for (const rate of [44100, 48000]) {
  function tone(frequency) {
    const instance = processor('companion-call-audio.js', rate);
    for (let start = 0; start < rate; start += 128) {
      const block = Float32Array.from({length: Math.min(128, rate-start)}, (_, i) => Math.sin(2*Math.PI*frequency*(start+i)/rate));
      instance.node.process([[block]], [[new Float32Array(block.length)]]);
    }
    const samples = instance.events.filter(e => e.input).flatMap(e => Array.from(e.input));
    samples.push(...instance.node.input);
    assert.equal(samples.length, 16000, 'One second must retain exactly 16000 input frames');
    const settled = samples.slice(100);
    return Math.sqrt(settled.reduce((sum,x)=>sum+x*x,0)/settled.length);
  }
  const speech = tone(1000), alias = tone(12000);
  assert(Math.abs(speech - Math.SQRT1_2) < .01, 'Preserve speech-band amplitude');
  assert(alias / speech < .01, 'Reject out-of-band audio by at least 40 dB before downsampling');
}
console.log('PASS 44.1/48 kHz microphone resampling preserves duration and speech amplitude, rejects 12 kHz aliasing.');
