import {test} from 'node:test';
import assert from 'node:assert/strict';
import {setImmediate as tick} from 'node:timers/promises';
import {CreditPump,fixedChunks} from '../credit-pump.mjs';
function fixture(){
 const reads=[];const sent=[];let ended=0,failed=0;
 const pump=new CreditPump({next:()=>new Promise(resolve=>reads.push(resolve))},{chunk:v=>sent.push(v),end:()=>ended++,error:()=>failed++});
 return {pump,reads,sent,status:()=>({ended,failed})};
}
test('credits arriving while a read is pending are retained and drained in order',async()=>{
 const f=fixture();f.pump.grant(4);f.pump.grant(4);
 assert.equal(f.reads.length,1,'Never run concurrent iterator reads');
 assert.throws(()=>f.pump.grant(1),/credit/);
 for(let n=0;n<8;n++){f.reads.shift()({value:n,done:false});await tick();}
 assert.deepEqual(f.sent,[0,1,2,3,4,5,6,7]);assert.equal(f.reads.length,0);
 f.pump.grant();f.reads.shift()({done:true});await tick();
 assert.deepEqual(f.status(),{ended:1,failed:0});f.pump.grant();assert.equal(f.reads.length,0);
});
test('cancel discards an in-flight read and all unused credits',async()=>{
 const f=fixture();f.pump.grant(8);f.pump.cancel();f.reads.shift()({value:'stale',done:false});await tick();
 assert.deepEqual(f.sent,[]);assert.equal(f.reads.length,0);assert.deepEqual(f.status(),{ended:0,failed:0});
});
test('invalid credits cannot create unbounded reads',()=>{
 for(const value of [0,-1,9,Infinity,0.5,'8'])assert.throws(()=>fixture().pump.grant(value),/credit/);
});

test('small TLS reads coalesce into bounded chunks with exact bytes',async()=>{
 const input=Buffer.from(Array.from({length:200003},(_,i)=>i%251));
 async function* source(){for(let i=0;i<input.length;i+=16384)yield input.subarray(i,i+16384);}
 const output=[];for await(const chunk of fixedChunks(source()))output.push(chunk);
 assert.deepEqual(output.map(b=>b.length),[49152,49152,49152,49152,3395]);
 assert.deepEqual(Buffer.concat(output),input);
});
