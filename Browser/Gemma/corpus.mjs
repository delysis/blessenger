import { loadBlessengerGemma, gemmaModel } from './blessenger-gemma.mjs';
const precision = new URL(location.href).searchParams.get('precision') === 'fp16' ? 'fp16' : 'fp32';
const { modelID, modelRevision } = gemmaModel(precision);
const status = document.querySelector('#status'), run = document.querySelector('#run');
run.onclick = async () => {
  run.disabled = true;
  let runtime;
  const results = [];
  try {
    runtime = await loadBlessengerGemma(p => status.textContent = p.text, precision);
    const fixtures = await (await fetch('./fixtures/manifest.json')).json();
    for (const fixture of fixtures) {
      status.textContent = `Audio ${results.length + 1}/${fixtures.length}`;
      await runtime.engine.resetChat();
      const data = new Float32Array(await (await fetch(fixture.path)).arrayBuffer());
      const started = performance.now();
      const reply = await runtime.engine.chat.completions.create({
        messages: [{ role: 'user', content: [{ type: 'input_audio', input_audio: { data, format: 'pcm_f32', sample_rate: 16000 } }] }],
        temperature: 1, seed: 42, max_tokens: 96,
      });
      const text = reply.choices[0]?.message?.content ?? '';
      results.push({ fixture: fixture.path, text, totalMs: performance.now() - started, correct: new RegExp(fixture.answer, 'i').test(text) });
    }
    status.textContent = JSON.stringify({ passed: results.every(x => x.correct), modelID, modelRevision, temperature: 1, seed: 42, results,
      externalNetworkBlocked: true, scope: 'Existing synthetic audio-content corpus through browser WebGPU; not microphone or iPhone acceptance' }, null, 2);
  } catch (error) {
    status.textContent = JSON.stringify({ passed: false, error: String(error), results }, null, 2);
  } finally { await runtime?.dispose(); run.disabled = false; }
};
