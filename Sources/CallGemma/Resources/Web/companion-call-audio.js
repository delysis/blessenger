class CallAudio extends AudioWorkletProcessor {
  constructor() {
    super();
    this.epoch = '';
    this.queue = [];
    this.phase = 0;
    this.inputPhase = 0;
    this.input = [];
    this.history = new Float32Array(64);
    this.cursor = 0;
    // Band-limit before reducing the microphone rate to 16 kHz. Dropping samples
    // directly folds high-frequency microphone noise into the speech band.
    // Fractional-delay phases also accommodate devices running at 44.1 kHz.
    this.filters = Array.from({ length: 128 }, (_, phase) => {
      const coefficients = new Float32Array(64);
      const cutoff = Math.min(7200 / sampleRate, 0.45);
      let total = 0;
      for (let i = 0; i < coefficients.length; i++) {
        const x = i - 31 - phase / 128;
        const sinc = Math.abs(x) < 1e-9 ? 2 * cutoff : Math.sin(2 * Math.PI * cutoff * x) / (Math.PI * x);
        const window = 0.42 - 0.5 * Math.cos(2 * Math.PI * i / 63) + 0.08 * Math.cos(4 * Math.PI * i / 63);
        coefficients[i] = sinc * window;
        total += coefficients[i];
      }
      for (let i = 0; i < coefficients.length; i++) coefficients[i] /= total;
      return coefficients;
    });
    this.port.onmessage = ({ data }) => {
      if (data.epoch !== this.epoch) {
        this.epoch = data.epoch;
        this.queue = [];
        this.phase = 0;
      }
      for (const packet of data.packets || []) this.queue.push({ sequence: packet.sequence, samples: packet.samples });
    };
  }
  process(inputs, outputs) {
    const input = inputs[0]?.[0], out = outputs[0]?.[0];
    if (input) {
      for (const sample of input) {
        this.history[this.cursor] = sample;
        this.inputPhase += 16000;
        if (this.inputPhase >= sampleRate) {
          this.inputPhase -= sampleRate;
          const filter = this.filters[Math.min(127, Math.floor(this.inputPhase / 16000 * 128))];
          let value = 0;
          for (let i = 0; i < filter.length; i++) value += this.history[(this.cursor - i + 64) % 64] * filter[i];
          this.input.push(Math.max(-1, Math.min(1, value)));
          if (this.input.length === 512) {
            this.port.postMessage({ input: this.input });
            this.input = [];
          }
        }
        this.cursor = (this.cursor + 1) % 64;
      }
    }
    if (out) {
      for (let i = 0; i < out.length; i++) {
        const packet = this.queue[0];
        if (!packet) { out[i] = 0; continue; }
        const index = Math.floor(this.phase), fraction = this.phase - index;
        out[i] = (packet.samples[index] || 0) * (1 - fraction) + (packet.samples[Math.min(index + 1, packet.samples.length - 1)] || 0) * fraction;
        this.phase += 24000 / sampleRate;
        if (this.phase >= packet.samples.length) {
          this.phase -= packet.samples.length;
          this.queue.shift();
          this.port.postMessage({ played: packet.sequence, epoch: this.epoch });
        }
      }
    }
    return true;
  }
}
registerProcessor('call-audio', CallAudio);
