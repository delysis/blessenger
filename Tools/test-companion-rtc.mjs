import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = await readFile(new URL('../Sources/CallGemma/Resources/Web/companion-rtc.js', import.meta.url), 'utf8');
const { CompanionRTC } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
let lastPeer;
class Peer {
  constructor() { lastPeer = this; this.connectionState = 'new'; }
  addTrack() {}
  createDataChannel() { return this.channel = { readyState: 'connecting', bufferedAmount: 0, sent: [], send(value) { this.sent.push(value); }, close() { this.readyState = 'closed'; this.onclose?.(); } }; }
  async createOffer() { return { type: 'offer', sdp: 'v=0\r\n' }; }
  async setLocalDescription(value) { this.localDescription = value; this.onicecandidate({ candidate: { toJSON: () => ({ candidate: 'local' }) } }); }
  async setRemoteDescription() {}
  async addIceCandidate() { this.channel.readyState = 'open'; this.channel.onopen(); }
  close() { this.connectionState = 'closed'; }
}
globalThis.RTCPeerConnection = Peer;
const stream = { getAudioTracks: () => [{ getSettings: () => ({ echoCancellation: true }) }] };
const calls = [];
const api = async (path, body) => {
  calls.push([path, body]);
  if (path.endsWith('/start')) return { id: 'session', iceServers: [] };
  if (path.endsWith('/offer')) return { sdp: 'v=0\r\n' };
  if (path.endsWith('/candidates')) return { cursor: 1, candidates: [{ candidate: 'remote' }] };
  return { closed: true };
};
let packets = 0, failures = 0;
const rtc = new CompanionRTC(api, () => packets++, () => failures++);
await rtc.open(stream);
assert(rtc.connected);
assert.equal(calls.find(([p]) => p.endsWith('/candidates'))[1].candidates.length, 1);
rtc.send({ epoch: 'epoch', acknowledged: [] });
lastPeer.channel.onmessage({ data: '{}' });
assert.equal(packets, 1);
lastPeer.channel.bufferedAmount = 524289;
assert.throws(() => rtc.send({}), /falling behind/);
rtc.close(); rtc.close();
assert.equal(failures, 0);
assert.equal(lastPeer.channel.sent.filter(value => JSON.parse(value).end).length, 1);
assert.throws(() => rtc.send({}), /unavailable/);
// Cancellation while the authenticated start request is still pending must
// dispose the eventual server session and must never open a peer afterwards.
let resolveStart;
const lateCalls = [];
const late = new CompanionRTC(async (path) => {
  lateCalls.push(path);
  if (path.endsWith('/start')) return await new Promise(resolve => { resolveStart = resolve; });
  return {};
}, () => assert.fail(), () => assert.fail());
const opening = late.open(stream); late.close(); resolveStart({ id: 'late', iceServers: [] });
await opening;
assert.deepEqual(lateCalls, ['/api/rtc/start', '/api/rtc/end']);
// Preserve the browser's failure classification for actual-device diagnosis.
let observedError;
const broken = new CompanionRTC(api, () => {}, error => { observedError = error; });
await broken.open(stream);
lastPeer.channel.onerror({error:{errorDetail:'sctp-failure',sctpCauseCode:12}});
assert.match(observedError.message, /sctp-failure; SCTP 12/);
assert(broken.closed);
assert.deepEqual(calls.find(([path]) => path.endsWith('/report'))[1], {id:'session',detail:'sctp-failure',cause:12});
assert.equal(lastPeer.connectionState, 'closed');
console.log('PASS: trickle signaling, control backpressure, cleanup, and cancellation during admission');

// The caller must be able to await server disposal, including a close that
// starts in the channel-error callback before the UI begins its own cleanup.
let resolveEnd, endCalls = 0;
const delayed = new CompanionRTC(async (path, body) => {
  if (path.endsWith('/end')) { endCalls++; return new Promise(resolve => { resolveEnd = resolve; }); }
  return api(path, body);
}, () => {}, () => {});
await delayed.open(stream);
lastPeer.channel.onerror({error:{errorDetail:'sctp-failure'}});
const closing = delayed.close();
assert(closing instanceof Promise);
assert.equal(closing, delayed.close(), 'Repeated close shares disposal completion');
let settled = false; closing.then(() => { settled = true; });
await Promise.resolve(); assert.equal(settled, false);
resolveEnd({closed:true}); await closing;
assert.equal(endCalls, 1); assert.equal(settled, true);
console.log('PASS channel failure and UI cleanup share acknowledged server disposal.');
