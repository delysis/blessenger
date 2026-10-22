// All weights are 4-bit; arithmetic stays fp32. Sizes come from the pinned
// publisher manifests and the bundled WebLLM catalog, not parameter counts.
export const offlineModels = Object.freeze([
  { modelID: 'gemma-4-E2B-it-q4f32_1-MLC', modelRevision: 'db5bcb53aa58acb27777ba02a891ff5c95d26ccf',
    downloadBytes: 2797577798, bufferBytes: 201326592, workingMB: 3863 },
  { modelID: 'Qwen3.5-2B-q4f32_1-MLC', modelRevision: 'd835e5c41aa56174d915e8a3940cde599d3f5a30',
    downloadBytes: 1059315328, bufferBytes: 254279680, workingMB: 2592 },
  { modelID: 'Qwen3.5-0.8B-q4f32_1-MLC', modelRevision: '4ed017713f04c91ffe55a9dca8c7ac853c41314d',
    downloadBytes: 423937664, bufferBytes: 127139840, workingMB: 1895 },
].map(Object.freeze));

// deviceMemory is coarse total RAM, not available RAM. Reserve half for the
// browser/OS/audio. When Safari omits it, begin with the smallest model rather
// than risking a tab kill to discover the memory limit. Loading can still fail.
export function offlineCandidates({ maxStorageBufferBindingSize, maxBufferSize,
  deviceMemoryGB, availableStorageBytes, cached = [] }) {
  if (![maxStorageBufferBindingSize, maxBufferSize].every(n => Number.isFinite(n) && n > 0)) return [];
  const memoryMB = Number.isFinite(deviceMemoryGB) && deviceMemoryGB > 0
    ? deviceMemoryGB * 1024 / 2 : offlineModels.at(-1).workingMB;
  const reserve = 128 * 1024 * 1024; // tokenizer, library and cache overhead
  return offlineModels.filter(model =>
    model.bufferBytes <= Math.min(maxStorageBufferBindingSize, maxBufferSize) &&
    model.workingMB <= memoryMB &&
    (cached.includes(model.modelID) || (Number.isFinite(availableStorageBytes) &&
      availableStorageBytes >= model.downloadBytes + reserve)));
}

// Loading is sequential. A failed attempt must release its worker before the
// next one starts; callers supply a loader that owns that cleanup. Never swap
// models inside an in-flight response or silently retry its generation.
export async function loadCandidates(candidates, load, onFailure = () => {}) {
  const failures = [];
  for (const candidate of candidates) {
    try { return { ...await load(candidate), model: candidate }; }
    catch (error) { failures.push(error); onFailure(candidate, error); }
  }
  throw new AggregateError(failures, 'No offline model could be loaded');
}
