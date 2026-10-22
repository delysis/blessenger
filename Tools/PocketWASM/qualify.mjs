import fs from 'node:fs';
import assert from 'node:assert/strict';
import {performance} from 'node:perf_hooks';
import init,{Model} from '../../Browser/PocketTTS/wasm/phonon_tts.js';
import {encodeWav} from '../../Browser/PocketTTS/wav.js';
const base=new URL('../../Browser/PocketTTS/',import.meta.url);
const out=process.argv[2]; if(!out)throw Error('Receipt/output directory required');fs.mkdirSync(out,{recursive:true});
const read=name=>fs.readFileSync(new URL(name,base));
await init({module_or_path:read('wasm/phonon_tts_bg.wasm')});
const model=await Model.load(read('model/model.safetensors'),read('model/tokenizer.json'),read('model/config.json'),'f32','none',undefined,undefined,'cpu');
const voices=JSON.parse(read('model/voices.json')).voices;
assert.equal(voices.length,14);
const results=[];
for(const voice of voices){
 const index=model.add_voice(read(`model/voices/${voice.contact}.safetensors`));
 const begin=performance.now(),chunks=[];let firstMS;
 model.start_generation(index,'Thank you.',0.7,42n);
 while(model.next_chunk()!==undefined){
  for(let n=0;n<400;n++){
   const pcm=await model.generation_step();if(pcm===undefined)break;
   firstMS??=performance.now()-begin;
   assert(pcm.every(Number.isFinite),'Nonfinite generated audio');chunks.push(pcm);
   if(n===399)throw Error('EOS not reached within 400 frames');
  }
 }
 const count=chunks.reduce((n,x)=>n+x.length,0),audio=new Float32Array(count);let offset=0;
 for(const chunk of chunks){audio.set(chunk,offset);offset+=chunk.length;}
 const energy=audio.reduce((n,x)=>n+x*x,0)/Math.max(1,count);
 assert(count>0&&energy>1e-8,'Empty or silent voice');
 const wav=encodeWav(audio,model.sample_rate());fs.writeFileSync(`${out}/${voice.contact}.wav`,Buffer.from(await wav.arrayBuffer()));
 // Cancel a partly generated reply, then repeat from the same voice and seed.
 model.start_generation(index,'This reply should be interrupted.',0.7,42n);model.next_chunk();await model.generation_step();model.stop_generation();
 model.start_generation(index,'Thank you.',0.7,42n);model.next_chunk();
 const restarted=await model.generation_step();assert.deepEqual(restarted,chunks[0],'Cancelled generation contaminated the next reply');model.stop_generation();
 results.push({contact:voice.contact,frames:count,sampleRate:model.sample_rate(),firstMS,totalMS:performance.now()-begin,energy,cancelRestartFirstFrameEqual:true});
 console.log('PASS',voice.contact,count);
}
model.free();
fs.writeFileSync(`${out}/receipt.json`,JSON.stringify({results,scope:'Real WASM synthesis in Node on this Mac; output validity and cancellation-state test, not listening/Safari/iPhone qualification'},null,2)+'\n');
