import { speechSeed } from './speech-seed.mjs';

// Recover alignment material without any connection to an audio renderer.
// The caller must release the live synthesis stream before acquiring the model.
export async function speechReference(tts, { text, voice, seed, prefixFrames, prefixSHA256 }) {
  const noise = speechSeed(seed);
  if (!Number.isSafeInteger(prefixFrames) || prefixFrames <= 0 || prefixFrames > 24000 * 60 ||
      !/^[a-f0-9]{64}$/.test(prefixSHA256) || typeof text !== 'string' || !text.trim() || !voice) {
    throw Error('Invalid speech reference request');
  }
  const abort = new AbortController();
  const stream = tts.stream(text, { voice, seed: noise, temperature: .7, signal: abort.signal });
  const chunks = []; let length = 0;
  try {
    for await (const chunk of stream) {
      if (!chunk.length || chunk.length > 1920 || !chunk.every(Number.isFinite) || length + chunk.length > 24000 * 60) {
        throw Error('Invalid reference PCM');
      }
      chunks.push(chunk.slice()); length += chunk.length;
    }
    await stream.done;
    if (length < prefixFrames) throw Error('Reference is shorter than the recorded audio');
    const samples = new Float32Array(length); let offset = 0;
    for (const chunk of chunks) { samples.set(chunk, offset); offset += chunk.length; }
    const hash = await crypto.subtle.digest('SHA-256', samples.subarray(0, prefixFrames));
    const actual = Array.from(new Uint8Array(hash), byte => byte.toString(16).padStart(2, '0')).join('');
    if (actual !== prefixSHA256) throw Error('Regenerated audio differs from the recorded prefix');
    return samples;
  } finally {
    abort.abort();
    await stream.done.catch(() => {});
  }
}
