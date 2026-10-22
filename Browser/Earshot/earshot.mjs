// One instance per call/worker. reset() must run when the capture epoch changes.
export class Earshot {
  constructor(instance) { this.exports = instance.exports; this.exports.reset(); }
  static async load(url) {
    const response = await fetch(url);
    if (!response.ok) throw Error('Voice detector unavailable');
    const { instance } = await WebAssembly.instantiate(await response.arrayBuffer(), {});
    return new Earshot(instance);
  }
  reset() { this.exports.reset(); }
  predict(samples) {
    if (samples.length !== 256 || samples.some(value => !Number.isFinite(value))) {
      throw Error('Voice detector requires 256 finite samples');
    }
    const pointer = this.exports.frame_pointer();
    new Float32Array(this.exports.memory.buffer, pointer, 256).set(samples);
    const probability = this.exports.predict(256);
    if (!Number.isFinite(probability) || probability < 0 || probability > 1) throw Error('Invalid speech probability');
    return probability;
  }
}
