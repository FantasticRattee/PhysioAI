'use client';

import { useEffect, useRef, useState } from 'react';
import { callMediaConstraints } from '../../utils/callMedia.js';
import { isCallEnded } from '../../utils/callLifecycle.js';
import { updateCallState } from '../../utils/callClient.js';
import Icon from './Icon.jsx';

async function sendSignal(callId, type, payload) {
  const response = await fetch('/api/cloudflare/signals', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ callId, type, payload }),
  });
  if (!response.ok) throw new Error(`signal_${response.status}`);
}

export default function WebRTCCall({ session, userId, onClose }) {
  const audioOnly = session.mediaType === 'audio';
  const localVideo = useRef(null);
  const remoteMedia = useRef(null);
  const [status, setStatus] = useState(audioOnly ? 'กำลังเปิดไมโครโฟน…' : 'กำลังเปิดกล้อง…');
  const [muted, setMuted] = useState(false);
  const streamRef = useRef(null);
  const stopRef = useRef(() => {});
  const closingRef = useRef(false);
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;

  useEffect(() => {
    let disposed = false;
    let pollTimer;
    let credentialTimer;
    let disconnectTimer;
    let reportedConnected = false;
    let peer;
    let remoteDescriptionReady = false;
    const processed = new Set();
    const queuedCandidates = [];

    function stopMedia() {
      disposed = true;
      window.clearTimeout(pollTimer);
      window.clearTimeout(credentialTimer);
      window.clearTimeout(disconnectTimer);
      if (peer) peer.onconnectionstatechange = null;
      peer?.close();
      streamRef.current?.getTracks().forEach((track) => track.stop());
      streamRef.current = null;
    }
    stopRef.current = stopMedia;

    function finishRemote() {
      if (disposed || closingRef.current) return;
      closingRef.current = true;
      stopMedia();
      onCloseRef.current();
    }

    async function applyCandidate(candidate) {
      if (!remoteDescriptionReady) {
        queuedCandidates.push(candidate);
        return;
      }
      await peer.addIceCandidate(candidate);
    }

    async function flushCandidates() {
      while (queuedCandidates.length) await peer.addIceCandidate(queuedCandidates.shift());
    }

    async function pollSignals() {
      if (disposed) return;
      try {
        const response = await fetch(`/api/cloudflare/signals?callId=${encodeURIComponent(session.callId)}`, { cache: 'no-store' });
        if (!response.ok) throw new Error(`signal_poll_${response.status}`);
        const { signals = [], call } = await response.json();
        if (disposed) return;
        if (isCallEnded(call)) { finishRemote(); return; }
        for (const signal of signals) {
          if (disposed) return;
          if (processed.has(signal.id) || signal.sender_id === userId) continue;
          processed.add(signal.id);
          if (signal.signal_type === 'offer' && !session.isInitiator) {
            await peer.setRemoteDescription(signal.payload);
            remoteDescriptionReady = true;
            await flushCandidates();
            const answer = await peer.createAnswer();
            await peer.setLocalDescription(answer);
            await sendSignal(session.callId, 'answer', { type: answer.type, sdp: answer.sdp });
          } else if (signal.signal_type === 'answer' && session.isInitiator && !remoteDescriptionReady) {
            await peer.setRemoteDescription(signal.payload);
            remoteDescriptionReady = true;
            await flushCandidates();
          } else if (signal.signal_type === 'ice') {
            await applyCandidate(signal.payload);
          } else if (signal.signal_type === 'hangup') {
            finishRemote();
            return;
          }
        }
      } catch (error) {
        if (!disposed) setStatus(`การเชื่อมต่อ signaling ขัดข้อง (${error.message})`);
      } finally {
        if (!disposed) pollTimer = window.setTimeout(pollSignals, 650);
      }
    }

    function scheduleCredentialRefresh(expiresIn) {
      const delay = Math.max(240_000, Number(expiresIn || 3600) * 800);
      credentialTimer = window.setTimeout(async () => {
        if (disposed) return;
        try {
          const response = await fetch('/api/cloudflare/calls', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ patientId: session.patientId, callId: session.callId }),
          });
          if (!response.ok) throw new Error(`credential_refresh_${response.status}`);
          const refreshed = await response.json();
          if (disposed) return;
          peer.setConfiguration({ iceServers: refreshed.iceServers });
          scheduleCredentialRefresh(refreshed.expiresIn);
        } catch {
          if (!disposed) setStatus('ต่ออายุการเชื่อมต่อไม่สำเร็จ กรุณาวางสายแล้วโทรใหม่');
        }
      }, delay);
    }

    async function connect() {
      try {
        const stream = await navigator.mediaDevices.getUserMedia(callMediaConstraints(session.mediaType));
        if (disposed) { stream.getTracks().forEach((track) => track.stop()); return; }
        streamRef.current = stream;
        if (localVideo.current) localVideo.current.srcObject = stream;
        peer = new RTCPeerConnection({ iceServers: session.iceServers });
        scheduleCredentialRefresh(session.expiresIn);
        stream.getTracks().forEach((track) => peer.addTrack(track, stream));
        peer.ontrack = ({ streams }) => {
          if (remoteMedia.current && streams[0]) remoteMedia.current.srcObject = streams[0];
        };
        peer.onicecandidate = ({ candidate }) => {
          if (candidate) sendSignal(session.callId, 'ice', candidate.toJSON()).catch(() => {});
        };
        peer.onconnectionstatechange = () => {
          if (disposed) return;
          window.clearTimeout(disconnectTimer);
          // Give the authoritative hang-up poll a chance to finish the call
          // before showing a transient ICE disconnect as a network problem.
          if (peer.connectionState === 'disconnected') {
            disconnectTimer = window.setTimeout(() => {
              if (!disposed) setStatus('สัญญาณขาดหาย กำลังเชื่อมใหม่…');
            }, 2000);
            return;
          }
          if (peer.connectionState === 'connected' && !reportedConnected) {
            reportedConnected = true;
            updateCallState(session.callId, 'live').then(({ call }) => {
              if (isCallEnded(call)) finishRemote();
            }).catch(() => { reportedConnected = false; });
          }
          const labels = {
            new: 'กำลังเตรียมสาย…', connecting: 'กำลังเชื่อมต่อ…', connected: 'เชื่อมต่อแล้ว · เข้ารหัส WebRTC',
            disconnected: 'สัญญาณขาดหาย กำลังเชื่อมใหม่…', failed: 'เชื่อมต่อไม่สำเร็จ', closed: 'วางสายแล้ว',
          };
          setStatus(labels[peer.connectionState] ?? peer.connectionState);
        };
        pollSignals();
        if (session.isInitiator) {
          const offer = await peer.createOffer();
          await peer.setLocalDescription(offer);
          await sendSignal(session.callId, 'offer', { type: offer.type, sdp: offer.sdp });
          if (!disposed) setStatus('กำลังรออีกฝ่ายรับสาย…');
        } else {
          setStatus('กำลังรับสาย…');
        }
      } catch (error) {
        if (!disposed) setStatus(error.name === 'NotAllowedError'
          ? (audioOnly ? 'ต้องอนุญาตไมโครโฟนก่อน' : 'ต้องอนุญาตกล้องและไมโครโฟนก่อน')
          : `เริ่ม${audioOnly ? 'โทรเสียง' : 'วิดีโอคอล'}ไม่สำเร็จ (${error.message})`);
      }
    }

    connect();
    return stopMedia;
  }, [session, userId, audioOnly]);

  function toggleMute() {
    const next = !muted;
    streamRef.current?.getAudioTracks().forEach((track) => { track.enabled = !next; });
    setMuted(next);
  }

  function hangUp() {
    if (closingRef.current) return;
    closingRef.current = true;
    stopRef.current();
    onCloseRef.current();
  }

  return (
    <div className="call-overlay" role="dialog" aria-label={audioOnly ? 'โทรด้วยเสียง' : 'วิดีโอคอล'} aria-modal="true">
      {audioOnly ? <>
        <audio ref={remoteMedia} autoPlay />
        <div className="audio-call-placeholder"><span><Icon name="phone" size={48} /></span><h2>โทรด้วยเสียง</h2><p>สนทนาผ่านอินเทอร์เน็ต · ไม่เปิดกล้อง</p></div>
      </> : <>
        <video className="remote-call-video" ref={remoteMedia} autoPlay playsInline />
        <video className="local-call-video" ref={localVideo} autoPlay muted playsInline />
      </>}
      <div className="call-status" role="status">{status}</div>
      <div className="call-controls">
        <button aria-pressed={muted} className="call-control" type="button" onClick={toggleMute}>{muted ? 'เปิดไมค์' : 'ปิดไมค์'}</button>
        <button className="call-close" type="button" onClick={hangUp}>วางสาย</button>
      </div>
    </div>
  );
}
