import assert from 'node:assert/strict';
import { SpeechPlayback } from '../Browser/PocketTTS/playback.mjs';

const messages = [];
let active = 0, maxActive = 0;
const seeds = [];
const tts = { stream(text, { signal, seed }) {
  seeds.push(seed);
  let finish;
  const done = new Promise(resolve => { finish = resolve; });
  const iterator = (async function* () {
    active++; maxActive = Math.max(active, maxActive);
    try {
      for (let i = 0; i < 20 && !signal.aborted; i++) {
        yield new Float32Array(1920).fill(text === 'old' ? .1 : .2);
      }
    } finally { active--; finish(); }
  })();
  iterator.done = done;
  return iterator;
} };
const rendered = [];
const playback = new SpeechPlayback(tts, { postMessage: value => messages.push(value) }, value => rendered.push(value));
const settle = () => new Promise(resolve => setImmediate(resolve));
playback.begin('old');
const old = playback.speak('old', 'voice', 'old', '0');
await settle();
assert.equal(playback.pending.size, 4, 'Synthesis must stop advancing at bounded playout lead');
playback.acknowledge({ epoch: 'old', played: 3 });
assert.equal(playback.pending.size, 4, 'Out-of-order receipt must not mark audio rendered');
assert.deepEqual(rendered, []);
playback.begin('new');
const cutoff = messages.length;
assert.equal(messages.at(-1).packets.length, 0, 'Cancellation clears renderer synchronously');
const next = playback.speak('new', 'voice', 'new', '18446744073709551615');
assert.equal((await old).cancelled, true);
await settle();
playback.acknowledge({ epoch: 'old', played: 0 });
assert.equal(playback.pending.size, 4, 'Old receipt cannot complete a new packet with reused sequence');
assert.deepEqual(rendered, [], 'Cancelled output cannot advance the heard journal');
let resolved = false;
next.then(() => { resolved = true; });
assert.equal(resolved, false, 'Synthesis completion is not rendering completion');
for (let i = 0; i < 20; i++) {
  playback.acknowledge({ epoch: 'new', played: i });
  await settle();
}
assert.deepEqual(await next, { cancelled: false, samples: 38400 });
assert.equal(maxActive, 1, 'Cancelled worker stream must drain before next clause starts');
assert(messages.slice(cutoff).every(message => message.epoch === 'new'), 'No cancelled PCM may arrive after clear');
assert.equal(playback.pending.size, 0);
assert.deepEqual(rendered, Array.from({ length: 20 }, (_, i) => ({ epoch: 'new', through: (i + 1) * 1920 })));
playback.acknowledge({ epoch: 'new', played: 19 });
assert.equal(rendered.length, 20, 'Duplicate receipt cannot advance the journal');
const secondClause = playback.speak('next clause', 'voice', 'new', '9007199254740993');
await settle();
for (let i = 20; i < 40; i++) {
  playback.acknowledge({ epoch: 'new', played: i });
  await settle();
}
await secondClause;
assert.deepEqual(rendered.at(-1), { epoch: 'new', through: 76800 }, 'Heard position spans clauses');
playback.begin('after-hangup');
assert.equal(playback.rendered, 0, 'New response resets heard position');

assert.deepEqual(seeds, [0n, 18446744073709551615n, 9007199254740993n]);
for (const seed of [undefined, 42, '-1', '01', '1.0', '18446744073709551616']) {
  await assert.rejects(playback.speak('invalid', 'voice', 'after-hangup', seed), /UInt64/);
}
assert.equal(seeds.length, 3, 'Invalid seeds must not start synthesis');

console.log('PASS bounded playout, ordered receipts, cancellation, serialized restart and exact UInt64 seeds');
