import fs from 'node:fs';
import assert from 'node:assert/strict';
import { Earshot } from '../Browser/Earshot/earshot.mjs';
const [wasmPath, pcmPath, referencePath, receiptPath] = process.argv.slice(2);
const { instance } = await WebAssembly.instantiate(fs.readFileSync(wasmPath), {});
const detector = new Earshot(instance);
const raw = fs.readFileSync(pcmPath);
const pcm = new Float32Array(raw.buffer.slice(raw.byteOffset,raw.byteOffset+raw.byteLength));
const reference = fs.readFileSync(referencePath,'utf8').trim().split('\n').map(Number);
function run() {
  const probabilities=[];
  for(let i=0;i+256<=pcm.length;i+=256) probabilities.push(detector.predict(pcm.subarray(i,i+256)));
  return probabilities;
}
const actual=run();
assert.equal(actual.length,reference.length);
const maxError=Math.max(...actual.map((value,i)=>Math.abs(value-reference[i])));
assert(maxError<0.0001,`Native/WASM probability drift: ${maxError}`);
detector.reset();
assert.throws(()=>detector.predict(new Float32Array(255)));
const invalid=new Float32Array(256);invalid[8]=NaN;
assert.throws(()=>detector.predict(invalid));
assert.deepEqual(run(),actual,'Reset and rejected frames must leave deterministic detector state');
fs.writeFileSync(receiptPath,JSON.stringify({frames:actual.length,maxProbabilityError:maxError,wasmBytes:fs.statSync(wasmPath).size,resetParity:true,invalidFramesRejected:true,scope:'WASM in Node versus native Rust on clinical-age speech; not Safari or microphone acceptance'},null,2)+'\n');
console.log(`PASS ${actual.length} speech frames; native/WASM max error ${maxError}; reset parity and input rejection.`);
