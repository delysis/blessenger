// Signaling uses paired HTTPS only during setup. Established audio and control
// use the peer connection, including when its selected path is a TURN relay.
export class CompanionRTC {
  constructor(api, onPacket, onFailure) {
    this.api = api; this.onPacket = onPacket; this.onFailure = onFailure;
    this.closed = false; this.connected = false; this.pending = []; this.cursor = 0;
  }
  async open(stream) {
    try {
      const setup = await this.api('/api/rtc/start', {
        echoCancellation: stream.getAudioTracks()[0]?.getSettings().echoCancellation === true,
      });
      this.id = setup.id;
      if (this.closed) { await this.disposeSignaling(); return; }
      const peer = this.peer = new RTCPeerConnection({ iceServers: setup.iceServers });
      for (const track of stream.getAudioTracks()) peer.addTrack(track, stream);
      const channel = this.channel = peer.createDataChannel('control', { ordered: true });
      const opened = new Promise((resolve, reject) => {
        this.rejectOpen = reject;
        this.openTimer = setTimeout(() => this.fail(Error('Peer connection timed out')), 12000);
        channel.onopen = () => { this.connected = true; clearTimeout(this.openTimer); resolve(); };
      });
      // Observe immediately: signaling may fail before code reaches await opened.
      opened.catch(() => {});
      channel.onmessage = event => {
        if (this.closed) return;
        try {
          if (typeof event.data !== 'string' || event.data.length > 65536) throw Error('Invalid peer control packet');
          this.onPacket(JSON.parse(event.data));
        } catch (error) { this.fail(error); }
      };
      channel.onclose = () => { if (!this.closed) this.fail(Error('Peer connection closed')); };
      channel.onerror = event => {
        const detail = event.error?.errorDetail;
        const cause = event.error?.sctpCauseCode;
        const suffix = [detail, Number.isInteger(cause) ? `SCTP ${cause}` : null].filter(Boolean).join('; ');
        if (this.id && !this.closed) {
          // Only protocol classifications and numeric codes leave the phone;
          // never send browser exception text, SDP, addresses, or audio here.
          const diagnostic = typeof detail === 'string' && /^[a-z-]{1,48}$/.test(detail) ? detail : 'unknown';
          this.api('/api/rtc/report', { id: this.id, detail: diagnostic,
            cause: Number.isInteger(cause) && cause >= 0 && cause <= 65535 ? cause : -1 }).catch(() => {});
        }
        this.fail(Error('Peer control failed' + (suffix ? ` (${suffix})` : '')));
      };
      peer.onconnectionstatechange = () => {
        clearTimeout(this.disconnectTimer);
        if (peer.connectionState === 'failed') this.fail(Error('Peer connection failed'));
        if (peer.connectionState === 'disconnected') {
          this.disconnectTimer = setTimeout(() => this.fail(Error('Peer connection lost')), 5000);
        }
      };
      peer.onicecandidate = ({ candidate }) => {
        if (!candidate || this.closed) return;
        if (this.pending.length >= 256) { this.fail(Error('Too many peer candidates')); return; }
        this.pending.push(candidate.toJSON());
      };
      await peer.setLocalDescription(await peer.createOffer());
      if (this.closed) return;
      const answer = await this.api('/api/rtc/offer', { id: this.id, sdp: peer.localDescription.sdp });
      if (this.closed) return;
      await peer.setRemoteDescription({ type: 'answer', sdp: answer.sdp });
      while (!this.closed && !this.connected) {
        const result = await this.api('/api/rtc/candidates', {
          id: this.id, cursor: this.cursor, candidates: this.pending.splice(0, 32),
        });
        if (this.closed) return;
        if (!Number.isInteger(result.cursor) || result.cursor < this.cursor ||
            !Array.isArray(result.candidates) || result.candidates.length > 256) throw Error('Invalid peer candidates');
        for (const candidate of result.candidates) await peer.addIceCandidate(candidate);
        this.cursor = result.cursor;
        if (!this.connected) await new Promise(resolve => setTimeout(resolve, 50));
      }
      await opened;
    } catch (error) { this.close(); throw error; }
  }
  send(value) {
    if (this.closed || this.channel?.readyState !== 'open') throw Error('Peer connection unavailable');
    const message = JSON.stringify(value);
    if (message.length > 65536 || this.channel.bufferedAmount > 524288) throw Error('Peer control is falling behind');
    this.channel.send(message);
  }
  fail(error) {
    if (this.closed) return;
    this.close(); this.onFailure(error);
  }
  close() {
    if (this.closed) return this.disposal;
    this.closed = true;
    clearTimeout(this.openTimer); clearTimeout(this.disconnectTimer);
    this.rejectOpen?.(Error('Peer connection closed'));
    if (this.channel?.readyState === 'open') {
      try { this.channel.send(JSON.stringify({ end: true })); } catch {}
    }
    this.channel?.close(); this.peer?.close();
    this.pending = [];
    return this.disposeSignaling();
  }
  disposeSignaling() {
    if (!this.id) return Promise.resolve();
    // Keep one completion promise so the UI cannot admit a retry before the
    // server has acknowledged teardown. A late start response also uses this.
    return this.disposal ||= this.api('/api/rtc/end', { id: this.id }).catch(() => {});
  }
}
