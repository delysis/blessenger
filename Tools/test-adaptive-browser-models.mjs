import assert from 'node:assert/strict';
import { offlineModels, offlineCandidates, loadCandidates } from '../Browser/Gemma/adaptive-models.mjs';
const roomy = { maxStorageBufferBindingSize: 256 * 1024 ** 2, maxBufferSize: 256 * 1024 ** 2,
  deviceMemoryGB: 8, availableStorageBytes: 5 * 1024 ** 3 };
const ids = input => offlineCandidates(input).map(m => m.modelID);
assert.deepEqual(ids(roomy), offlineModels.map(m => m.modelID));
assert.deepEqual(ids({ ...roomy, deviceMemoryGB: undefined }), [offlineModels[2].modelID]);
assert.deepEqual(ids({ ...roomy, maxStorageBufferBindingSize: 128 * 1024 ** 2 }), [offlineModels[2].modelID]);
// Qwen 2B has a larger single tensor than E2B despite lower total memory.
assert.deepEqual(ids({ ...roomy, maxBufferSize: 220 * 1024 ** 2 }), [offlineModels[0].modelID, offlineModels[2].modelID]);
assert.deepEqual(ids({ ...roomy, deviceMemoryGB: 4 }), [offlineModels[2].modelID]);
assert.deepEqual(ids({ ...roomy, deviceMemoryGB: 2 }), []);
assert.deepEqual(ids({ ...roomy, availableStorageBytes: 0 }), []);
assert.deepEqual(ids({ ...roomy, availableStorageBytes: 0, cached: [offlineModels[0].modelID] }), [offlineModels[0].modelID]);
assert.deepEqual(ids({ ...roomy, maxBufferSize: undefined }), []);
assert.deepEqual(ids({ ...roomy, availableStorageBytes: NaN }), []);
let active = 0, maximum = 0;
const attempted = [], failures = [];
const loaded = await loadCandidates(offlineModels, async model => {
  active++; maximum = Math.max(maximum, active); attempted.push(model.modelID);
  try {
    await new Promise(resolve => setImmediate(resolve));
    if (model !== offlineModels[2]) throw Error('Allocation failed');
    return { engine: 'ready' };
  } finally { active--; }
}, (model, error) => failures.push([model.modelID, error.message]));
assert.equal(maximum, 1);
assert.deepEqual(attempted, offlineModels.map(m => m.modelID));
assert.equal(failures.length, 2);
assert.equal(loaded.model, offlineModels[2]);
assert.equal(loaded.engine, 'ready');
await assert.rejects(loadCandidates([], () => assert.fail()), AggregateError);
await assert.rejects(loadCandidates([offlineModels[2]], async () => { throw Error('Unavailable'); }),
  error => error instanceof AggregateError && error.errors.length === 1);
console.log('PASS GPU limits, unknown RAM, storage exhaustion, cached weights and sequential load failure fallback');
