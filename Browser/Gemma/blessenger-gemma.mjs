import { CreateWebWorkerMLCEngine, prebuiltAppConfig, hasModelInCache } from './web-llm.js';
import { offlineModels, offlineCandidates, loadCandidates } from './adaptive-models.mjs';

export function gemmaModel(precision = 'fp32') {
  if (!['fp32', 'fp16'].includes(precision)) throw Error('Unsupported E2B compute precision');
  return precision === 'fp32'
    ? { modelID: 'gemma-4-E2B-it-q4f32_1-MLC', modelRevision: 'db5bcb53aa58acb27777ba02a891ff5c95d26ccf' }
    : { modelID: 'gemma-4-E2B-it-q4f16_1-MLC', modelRevision: '633df598b7a473759367855273c63912c9e2bc9a' };
}
const libraryRevision = '00fe7a40e57e5e8eb9fef87526a4bf28ad5846c0';

function pinnedConfig({ modelID, modelRevision }) {
  const record = prebuiltAppConfig.model_list.find(model => model.model_id === modelID);
  if (!record) throw Error('Pinned runtime lacks offline model');
  return { model_list: [{ ...record,
    model: `https://huggingface.co/mlc-ai/${modelID}/resolve/${modelRevision}/`,
    model_lib: record.model_lib.replace('/main/', `/${libraryRevision}/`),
  }] };
}

async function loadModel(model, onProgress) {
  const appConfig = pinnedConfig(model);
  const worker = new Worker(new URL('./worker.mjs', import.meta.url), { type: 'module' });
  try {
    const engine = await CreateWebWorkerMLCEngine(worker, model.modelID, {
      initProgressCallback: onProgress, appConfig,
    }, { context_window_size: 4096, temperature: 1 });
    return { engine, dispose: async () => {
      try { await engine.unload(); } finally { worker.terminate(); }
    } };
  } catch (error) { worker.terminate(); throw error; }
}

export async function loadAdaptiveBlessengerModel(onProgress, onFailure) {
  const adapter = await navigator.gpu?.requestAdapter();
  if (!adapter) throw Error('WebGPU unavailable');
  const storage = await navigator.storage?.estimate().catch(() => ({})) ?? {};
  const cached = [];
  for (const model of offlineModels) {
    // A tensor cache only avoids reserving the download twice. Successful
    // engine loading, not this flag, establishes that offline use is possible.
    if (await hasModelInCache(model.modelID, pinnedConfig(model)).catch(() => false)) cached.push(model.modelID);
  }
  const candidates = offlineCandidates({
    maxStorageBufferBindingSize: adapter.limits.maxStorageBufferBindingSize,
    maxBufferSize: adapter.limits.maxBufferSize,
    deviceMemoryGB: navigator.deviceMemory,
    availableStorageBytes: storage.quota - storage.usage, cached,
  });
  return loadCandidates(candidates, model => loadModel(model, onProgress), onFailure);
}

// Both variants have 4-bit weights. Default to float32 arithmetic because the
// float16 build failed six of eight existing audio-content fixtures on this Mac.
// fp16 remains selectable for diagnostic comparison, never as an automatic fallback.
export async function loadBlessengerGemma(onProgress, precision = 'fp32') {
  const { modelID, modelRevision } = gemmaModel(precision);
  const adapter = await navigator.gpu?.requestAdapter();
  if (!adapter) throw Error('WebGPU unavailable');
  if (precision === 'fp16' && !adapter.features.has('shader-f16')) throw Error('WebGPU float16 unavailable');
  if (adapter.limits.maxStorageBufferBindingSize < 201326592) {
    throw Error('WebGPU storage buffer limit is too small for E2B');
  }
  return loadModel({ modelID, modelRevision }, onProgress);
}
