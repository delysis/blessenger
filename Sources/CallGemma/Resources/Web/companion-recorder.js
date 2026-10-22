class Recorder extends AudioWorkletProcessor {
  constructor(){super();this.chunk=new Float32Array(2048);this.used=0;this.port.onmessage=()=>{if(this.used)this.port.postMessage(this.chunk.slice(0,this.used));this.used=0;this.port.postMessage({flushed:true})}}
  process(inputs){const input=inputs[0]?.[0];if(input)for(const sample of input){this.chunk[this.used++]=sample;if(this.used===this.chunk.length){this.port.postMessage(this.chunk);this.chunk=new Float32Array(2048);this.used=0}}return true}
}
registerProcessor('recorder',Recorder);
