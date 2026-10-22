import { loadBrowserSpeech, loadBrowserVAD } from '/runtime.js';
const run = document.querySelector('#run'), result = document.querySelector('#result');
run.onclick = async () => {
  run.disabled = true;
  const receipt = { scope: 'Paired browser WASM synthesis; no microphone or acoustic verification', phases: [] };
  const show = () => { result.textContent = JSON.stringify(receipt, null, 2); };
  let tts;
  try {
    const started = performance.now();
    receipt.phases.push('loading'); show();
    tts = await loadBrowserSpeech();
    receipt.loadMs = Math.round(performance.now() - started);
    receipt.phases.push('synthesizing'); show();
    let frames = 0, peak = 0; const chunks = [];
    const speech = tts.stream('Thank you.', { temperature: .7, seed: 42 });
    for await (const pcm of speech) {
      for (const sample of pcm) {
        if (!Number.isFinite(sample)) throw Error('Nonfinite speech output');
        peak = Math.max(peak, Math.abs(sample));
      }
      frames += pcm.length; chunks.push(pcm.slice());
    }
    receipt.stats = await speech.done;
    if (!frames || peak < 0.0001) throw Error('Empty or silent speech output');
    receipt.frames = frames; receipt.peak = peak;
    receipt.phases.push('voice-detection'); show();
    const vad = await loadBrowserVAD();
    const offline = new OfflineAudioContext(1, Math.ceil(frames * 16000 / speech.sampleRate), 16000);
    const buffer = offline.createBuffer(1, frames, speech.sampleRate);
    let offset = 0; for (const chunk of chunks) { buffer.copyToChannel(chunk, 0, offset); offset += chunk.length; }
    const input = offline.createBufferSource(); input.buffer = buffer; input.connect(offline.destination); input.start();
    const pcm16 = (await offline.startRendering()).getChannelData(0);
    const predict = () => {
      const values = [];
      for (let i = 0; i + 256 <= pcm16.length; i += 256) values.push(vad.predict(pcm16.subarray(i, i + 256)));
      return values;
    };
    const probabilities = predict(); vad.reset(); const repeated = predict();
    const resetEqual = probabilities.length === repeated.length && probabilities.every((p, i) => p === repeated[i]);
    if (!resetEqual || !probabilities.length) throw Error('Voice detector reset mismatch');
    const maxSpeechProbability = Math.max(...probabilities);
    if (maxSpeechProbability < .5) throw Error('Detector did not recognize synthesized speech');
    receipt.vad = { frames: probabilities.length, maxSpeechProbability, resetEqual };
    receipt.passed = true;
    receipt.phases.push('complete');
  } catch (error) {
    receipt.passed = false; receipt.error = String(error);
  } finally {
    tts?.dispose(); show(); run.disabled = false;
  }
};
