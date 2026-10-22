import assert from 'node:assert/strict';
import { connectRemoteAudio } from '../Browser/RTC/remote-audio.mjs';
const elements=[];
globalThis.Audio=class {
  constructor(){elements.push(this);this.pauses=0;this.pending=new Promise((resolve,reject)=>{this.resolve=resolve;this.reject=reject;});}
  play(){return this.pending;}
  pause(){this.pauses++;}
};
globalThis.MediaStream=class {constructor(tracks){this.tracks=tracks;}};
const sources=[];
const context={createMediaStreamSource(){const source={connected:false,disconnected:0,connect(){this.connected=true;},disconnect(){this.disconnected++;}};sources.push(source);return source;}};
const args={context,track:{kind:'audio'},destination:{}};
const abort=new AbortController();
const cancelled=connectRemoteAudio({...args,signal:abort.signal});
assert.equal(elements[0].muted,true);assert.equal(elements[0].volume,0);
abort.abort();elements[0].resolve();
await assert.rejects(cancelled,{name:'AbortError'});
assert.equal(elements[0].srcObject,null);assert.equal(sources[0].disconnected,1);
const failed=connectRemoteAudio(args);elements[1].reject(Error('Playback admission denied'));
await assert.rejects(failed,/admission denied/);
assert.equal(elements[1].srcObject,null);assert.equal(sources[1].disconnected,1);
const success=connectRemoteAudio(args);elements[2].resolve();const connection=await success;
connection.close();connection.close();
assert.equal(sources[2].disconnected,1);assert.equal(elements[2].srcObject,null);
await assert.rejects(connectRemoteAudio({...args,signal:abort.signal}),{name:'AbortError'});
assert.equal(elements.length,3,'Already-cancelled connection must not create a media element');
console.log('PASS silent decoder consumer, cancellation during play admission, failed admission cleanup and idempotent teardown');
