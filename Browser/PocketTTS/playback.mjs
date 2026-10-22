import { speechSeed } from './speech-seed.mjs';
// Serial synthesis, bounded playout lead, and explicit render acknowledgement.
// The port is the existing 24 kHz call AudioWorklet port. Receipt is not render.
export class SpeechPlayback {
  constructor(tts, port, onRendered = () => {}) {
    if (typeof onRendered !== 'function') throw Error('Render observer must be a function');
    this.tts = tts;
    this.port = port;
    this.epoch = '';
    this.sequence = 0;
    this.pending = new Map();
    this.tail = Promise.resolve();
    this.queued = 0;
    this.abort = null;
    this.onRendered = onRendered;
    this.rendered = 0;
  }

  begin(epoch) {
    if (typeof epoch !== 'string' || !epoch || epoch === this.epoch) {
      throw Error('A new speech epoch is required');
    }
    this.abort?.abort();
    for (const pending of this.pending.values()) pending.resolve(false);
    this.pending.clear();
    this.epoch = epoch;
    this.sequence = 0;
    this.rendered = 0;
    // Clear the renderer immediately, before awaiting worker cancellation.
    this.port.postMessage({ epoch, packets: [] });
  }

  acknowledge({ epoch, played }) {
    if (epoch !== this.epoch) return;
    const first = this.pending.keys().next().value;
    if (played !== first) return; // Stale, duplicate or out-of-order receipt.
    const pending = this.pending.get(played);
    if (!pending) return;
    this.pending.delete(played);
    this.rendered += pending.samples;
    // Response-wide 24 kHz frame position, advanced only by the renderer.
    // The host can journal exactly how much of this epoch was heard.
    try {
      this.onRendered({ epoch, through: this.rendered });
      pending.resolve(true);
    } catch (error) {
      pending.resolve(false);
      this.begin(crypto.randomUUID());
      throw error;
    }
  }

  speak(text, voice, epoch = this.epoch, seed) {
    if (!epoch || typeof text !== 'string' || !text.trim() || !voice) {
      return Promise.reject(Error('Speech requires text, voice and an active epoch'));
    }
    // JSON numbers cannot preserve UInt64 seeds. Require their decimal wire
    // representation and convert directly to BigInt, never through Number.
    let noise;
    try { noise = speechSeed(seed); } catch (error) { return Promise.reject(error); }
    if (this.queued >= 16) return Promise.reject(Error('Speech clause queue is full'));
    this.queued++;
    const result = this.tail.then(() => this.render(text, voice, epoch, noise));
    this.tail = result.catch(() => {}).finally(() => { this.queued--; });
    return result;
  }

  async render(text, voice, epoch, seed) {
    if (epoch !== this.epoch) return { cancelled: true };
    const abort = new AbortController();
    this.abort = abort;
    const stream = this.tts.stream(text, { voice, temperature: .7, seed, signal: abort.signal });
    let samples = 0;
    try {
      for await (const pcm of stream) {
        if (abort.signal.aborted || epoch !== this.epoch) break;
        if (!pcm.length || pcm.length > 1920 || !pcm.every(Number.isFinite)) throw Error('Invalid synthesized audio');
        // Upstream frames are 80 ms. At most four may wait in the renderer.
        while (this.pending.size >= 4 && epoch === this.epoch) {
          await this.pending.values().next().value.promise;
        }
        if (abort.signal.aborted || epoch !== this.epoch) break;
        const sequence = this.sequence++;
        let resolve;
        const promise = new Promise(done => { resolve = done; });
        this.pending.set(sequence, { promise, resolve, samples: pcm.length });
        samples += pcm.length;
        this.port.postMessage({ epoch, packets: [{ sequence, samples: pcm }] });
      }
      await stream.done;
      while (epoch === this.epoch && this.pending.size) {
        await this.pending.values().next().value.promise;
      }
      return { cancelled: epoch !== this.epoch || abort.signal.aborted, samples };
    } catch (error) {
      abort.abort();
      // Synthesis errors must not leave queued fragments playing afterwards.
      if (epoch === this.epoch) this.begin(crypto.randomUUID());
      throw error;
    } finally {
      // No subsequent clause may acquire the model before this stream drains.
      await stream.done.catch(() => {});
      if (this.abort === abort) this.abort = null;
    }
  }
}
