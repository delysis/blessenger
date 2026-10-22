// Keep the remote WebRTC decoder pulling while routing its PCM through WebAudio.
// Chromium otherwise receives RTP but can deliver zero samples to the source node.
// The media element is always silent; destination owns the actual output path.
export async function connectRemoteAudio({ context, track, destination, signal }) {
  if (track.kind !== 'audio') throw Error('Expected a remote audio track');
  signal?.throwIfAborted();
  const element = new Audio();
  element.muted = true;
  element.volume = 0;
  element.srcObject = new MediaStream([track]);
  let source, closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    signal?.removeEventListener('abort', close);
    source?.disconnect();
    element.pause();
    element.srcObject = null;
  };
  signal?.addEventListener('abort', close, { once: true });
  try {
    source = context.createMediaStreamSource(element.srcObject);
    source.connect(destination);
    await element.play();
    // Cancellation can race the asynchronous play admission.
    if (closed || signal?.aborted) {
      element.pause();
      throw new DOMException('Remote audio was cancelled', 'AbortError');
    }
    return { close };
  } catch (error) { close(); throw error; }
}
