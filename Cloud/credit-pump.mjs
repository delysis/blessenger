// Serialize iterator reads while retaining bounded credits arriving during I/O.
export class CreditPump {
  constructor(iterator, {chunk, end, error}, limit = 8) {
    this.iterator = iterator;
    this.callbacks = {chunk, end, error};
    this.limit = limit;
    this.credits = 0;
    this.running = false;
    this.stopped = false;
  }
  grant(count = 1) {
    if (this.stopped) return;
    if (!Number.isInteger(count) || count < 1 || this.credits + count > this.limit) {
      throw Error('Invalid transfer credit');
    }
    this.credits += count;
    void this.drain();
  }
  cancel() { this.stopped = true; this.credits = 0; }
  async drain() {
    if (this.running || this.stopped) return;
    this.running = true;
    try {
      while (this.credits && !this.stopped) {
        const {value, done} = await this.iterator.next();
        if (this.stopped) return;
        this.credits--;
        if (done) { this.cancel(); this.callbacks.end(); return; }
        this.callbacks.chunk(value);
      }
    } catch (error) {
      if (!this.stopped) { this.cancel(); this.callbacks.error(error); }
    } finally { this.running = false; }
  }
}

// Socket/TLS read boundaries are unrelated to transport chunk boundaries.
// Coalesce small reads without accumulating the entire response.
export async function* fixedChunks(source, size = 49152) {
  let buffer = Buffer.allocUnsafe(size), used = 0;
  for await (const input of source) {
    for (let offset = 0; offset < input.length;) {
      const count = Math.min(size - used, input.length - offset);
      input.copy(buffer, used, offset, offset + count);
      used += count; offset += count;
      if (used === size) { yield buffer; buffer = Buffer.allocUnsafe(size); used = 0; }
    }
  }
  if (used) yield buffer.subarray(0, used);
}
