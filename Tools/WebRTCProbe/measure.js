class Measure extends AudioWorkletProcessor {
  constructor() { super(); this.count=0; this.power=0; this.re=0; this.im=0; this.ownRe=0; this.ownIm=0; }
  process(inputs,outputs) {
    outputs[0]?.[0]?.fill(0); // Silent diagnostic output, never route the tone to hardware.
    for(const x of inputs[0]?.[0]??[]) {
      this.power+=x*x;
      this.re+=x*Math.cos(2*Math.PI*880*this.count/sampleRate);
      this.im+=x*Math.sin(2*Math.PI*880*this.count/sampleRate);
      this.ownRe+=x*Math.cos(2*Math.PI*440*this.count/sampleRate);
      this.ownIm+=x*Math.sin(2*Math.PI*440*this.count/sampleRate);
      if(++this.count===sampleRate) {
        const amplitude=2*Math.hypot(this.re,this.im)/this.count, ownAmplitude=2*Math.hypot(this.ownRe,this.ownIm)/this.count;
        this.port.postMessage({samples:this.count,rms:Math.sqrt(this.power/this.count),amplitude,ownAmplitude});
        this.count=0;this.power=0;this.re=0;this.im=0;this.ownRe=0;this.ownIm=0;
      }
    }
    return true;
  }
}
registerProcessor('measure',Measure);
