import { PhononTTS } from './index.js';

// Require explicit PocketTTS artifacts: upstream's default is a different model.
// The contact ID, not a display name, identifies each saved voice.
export async function loadBlessengerSpeech(model, options = {}) {
  if (!model || typeof model !== 'object' || !model.config || !model.tokenizer ||
      !model.weights?.f32 || !model.voices || Object.keys(model.voices).length !== 14) {
    throw Error('PocketTTS requires explicit weights, configuration, tokenizer and fourteen contact voices');
  }
  const wasm = new URL('./wasm/phonon_tts_bg.wasm', import.meta.url).href;
  return PhononTTS.load({
    model, lang: 'none', quant: 'f32', device: 'cpu', threads: 1,
    // This build contains baseline SIMD only; Safari does not need relaxed SIMD.
    wasmUrl: wasm, simdWasmUrl: wasm,
    voices: Object.keys(model.voices), onProgress: options.onProgress,
  });
}
