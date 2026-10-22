// Load from the paired Mac's versioned runtime, never an implicit third-party
// TTS model. Large model files are cached by the speech worker's page-side cache.
async function runtimeBase() {
  const response = await fetch('/api/runtime');
  if (!response.ok) throw Error('Browser runtime unavailable');
  const descriptor = await response.json();
  if (!/^\/runtime\/[a-f0-9]{64}\/$/.test(descriptor.base)) throw Error('Invalid runtime address');
  return new URL(descriptor.base, location.origin);
}

export async function loadBrowserSpeech(onProgress) {
  const base = await runtimeBase();
  const speech = new URL('PocketTTS/', base);
  const response = await fetch(new URL('model/voices.json', speech));
  if (!response.ok) throw Error('Contact voices unavailable');
  const catalog = await response.json();
  if (!Array.isArray(catalog.voices) || catalog.voices.length !== 14 ||
      catalog.voices.some(voice => !/^[a-f0-9-]{36}$/.test(voice.contact)) ||
      new Set(catalog.voices.map(voice => voice.contact)).size !== 14) {
    throw Error('Invalid contact voice catalog');
  }
  const voices = Object.fromEntries(catalog.voices.map(voice =>
    [voice.contact, new URL(`model/voices/${voice.contact}.safetensors`, speech).href]));
  const { loadBlessengerSpeech } = await import(new URL('blessenger-speech.mjs', speech).href);
  return loadBlessengerSpeech({
    weights: { f32: new URL('model/model.safetensors', speech).href },
    config: new URL('model/config.json', speech).href,
    tokenizer: new URL('model/tokenizer.json', speech).href,
    voices, defaultVoice: catalog.voices[0].contact,
  }, { onProgress });
}

export async function loadBrowserVAD() {
  const base = await runtimeBase();
  const { Earshot } = await import(new URL('Earshot/earshot.mjs', base).href);
  return Earshot.load(new URL('Earshot/earshot.wasm', base).href);
}
