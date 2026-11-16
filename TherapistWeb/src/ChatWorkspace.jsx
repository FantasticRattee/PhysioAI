'use client';

import dynamic from 'next/dynamic';
import { useEffect, useMemo, useRef, useState } from 'react';
import { createClient } from '../utils/supabase/client.js';
import Icon from './components/Icon.jsx';
import Topbar from './components/Topbar.jsx';
import { callHistoryDetail, mergeCallHistory } from '../utils/callLifecycle.js';
import { updateCallState } from '../utils/callClient.js';

const WebRTCCall = dynamic(() => import('./components/WebRTCCall.jsx'), { ssr: false });

function mergeMessage(list, message) {
  if (list.some(({ id }) => id === message.id)) return list;
  return [...list, message].toSorted((a, b) => new Date(a.created_at) - new Date(b.created_at));
}

function formatTime(value) {
  return new Intl.DateTimeFormat('th-TH', { hour: '2-digit', minute: '2-digit' }).format(new Date(value));
}

export default function ChatWorkspace({ initialMessages, patients, therapist, onSignOut }) {
  const [selectedId, setSelectedId] = useState(patients[0]?.id ?? '');
  const [messagesByPatient, setMessagesByPatient] = useState(initialMessages);
  const [query, setQuery] = useState('');
  const [draft, setDraft] = useState('');
  const [notice, setNotice] = useState('');
  const [sending, setSending] = useState(false);
  const [callSession, setCallSession] = useState(null);
  const [incomingCall, setIncomingCall] = useState(null);
  const [startingCall, setStartingCall] = useState(false);
  const [callsByPatient, setCallsByPatient] = useState({});
  const timelineRef = useRef(null);
  const supabase = useMemo(() => createClient(), []);
  const selected = patients.find(({ id }) => id === selectedId) ?? null;
  const messages = messagesByPatient[selectedId] ?? [];
  const timeline = useMemo(() => [
    ...messages.map((message) => ({ id: `message-${message.id}`, at: message.created_at, message })),
    ...(callsByPatient[selectedId] ?? []).map((call) => ({ id: `call-${call.id}`, at: call.created_at, call })),
  ].sort((a, b) => new Date(a.at) - new Date(b.at) || a.id.localeCompare(b.id)), [messages, callsByPatient, selectedId]);
  const filteredPatients = patients.filter((patient) => patient.name.toLocaleLowerCase('th').includes(query.toLocaleLowerCase('th')));

  useEffect(() => {
    if (!therapist.id) return undefined;
    const channel = supabase
      .channel(`therapist-messages-${therapist.id}`)
      .on('postgres_changes', {
        event: 'INSERT', schema: 'public', table: 'communication_messages', filter: `therapist_id=eq.${therapist.id}`,
      }, ({ new: message }) => {
        setMessagesByPatient((current) => ({
          ...current,
          [message.patient_id]: mergeMessage(current[message.patient_id] ?? [], message),
        }));
      })
      .subscribe();
    return () => { supabase.removeChannel(channel); };
  }, [supabase, therapist.id]);

  useEffect(() => {
    let cancelled = false;
    async function refreshIncomingCall() {
      try {
      const response = await fetch('/api/cloudflare/calls');
      const result = await response.json().catch(() => ({}));
      if (!cancelled && response.ok) {
        const call = result.call;
        setIncomingCall(call && call.initiated_by !== therapist.id ? call : null);
      }
      } catch { /* Keep the last state while the network reconnects. */ }
    }
    refreshIncomingCall();
    const interval = window.setInterval(refreshIncomingCall, 3000);
    return () => { cancelled = true; window.clearInterval(interval); };
  }, [therapist.id]);

  useEffect(() => {
    if (!selectedId) return undefined;
    let cancelled = false;
    async function refreshHistory() {
      try {
        const response = await fetch(`/api/cloudflare/calls?history=true&patientId=${encodeURIComponent(selectedId)}`, { cache: 'no-store' });
        const result = await response.json();
        if (!cancelled && response.ok) setCallsByPatient((current) => ({ ...current,
          [selectedId]: mergeCallHistory(current[selectedId] ?? [], result.calls ?? []),
        }));
      } catch { /* A temporary history fetch failure must not clear saved cards. */ }
    }
    refreshHistory();
    const interval = window.setInterval(refreshHistory, 3000);
    return () => { cancelled = true; window.clearInterval(interval); };
  }, [selectedId]);

  useEffect(() => {
    timelineRef.current?.scrollTo({ top: timelineRef.current.scrollHeight, behavior: 'smooth' });
  }, [timeline.length, selectedId]);

  async function sendMessage(event) {
    event.preventDefault();
    const body = draft.trim();
    if (!selected || !body || sending) return;
    setSending(true);
    setNotice('');
    const { data, error } = await supabase
      .from('communication_messages')
      .insert({ patient_id: selected.id, therapist_id: therapist.id, sender_id: therapist.id, body })
      .select('id, patient_id, therapist_id, sender_id, body, created_at')
      .single();
    setSending(false);
    if (error) {
      setNotice(`ส่งข้อความไม่สำเร็จ: ${error.message}`);
      return;
    }
    setDraft('');
    setMessagesByPatient((current) => ({ ...current, [selected.id]: mergeMessage(current[selected.id] ?? [], data) }));
  }

  async function startVideoCall(mediaType = 'video') {
    if (!selected || startingCall) return;
    setStartingCall(true);
    setNotice('');
    try {
      const response = await fetch('/api/cloudflare/calls', {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ patientId: selected.id, mediaType }),
      });
      const result = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(result.error ?? String(response.status));
      if (mediaType === 'audio' && result.mediaType !== 'audio') throw new Error('เซิร์ฟเวอร์ยังไม่รองรับสายเสียง กรุณาอัปเดตเซิร์ฟเวอร์ก่อน');
      setCallSession(result);
    } catch (error) {
      setNotice(`เริ่ม${mediaType === 'audio' ? 'โทรเสียง' : 'วิดีโอคอล'}ไม่สำเร็จ: ${error.message}`);
    } finally {
      setStartingCall(false);
    }
  }

  async function joinIncomingVideoCall() {
    if (!incomingCall || startingCall) return;
    setSelectedId(incomingCall.patient_id);
    setStartingCall(true);
    setNotice('');
    try {
      const response = await fetch('/api/cloudflare/calls', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ patientId: incomingCall.patient_id, callId: incomingCall.id }),
      });
      const result = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(result.error ?? String(response.status));
      if (incomingCall.media_type === 'audio' && result.mediaType !== 'audio') throw new Error('ชนิดสายไม่ตรงกัน กรุณาโทรใหม่');
      setIncomingCall(null);
      setCallSession(result);
    } catch (error) {
      setNotice(`รับสายไม่สำเร็จ: ${error.message}`);
    } finally {
      setStartingCall(false);
    }
  }

  async function closeVideoCall() {
    const callId = callSession?.callId;
    setCallSession(null);
    setIncomingCall((current) => current?.id === callId ? null : current);
    if (!callId) return;
    try {
      const { call } = await updateCallState(callId, 'ended');
      if (call) setCallsByPatient((current) => ({ ...current,
        [call.patient_id]: mergeCallHistory(current[call.patient_id] ?? [], [call]),
      }));
    } catch {
      setNotice('ปิดไมค์และกล้องแล้ว แต่ส่งการวางสายไม่สำเร็จ กรุณาตรวจสอบอินเทอร์เน็ต');
    }
  }

  return (
    <div className="app-shell communication-shell" lang="th">
      <Topbar activeSection="messages" lang="th" onSignOut={onSignOut} therapist={therapist} />
      <main className="messenger-layout">
        <aside className="conversation-rail">
          <div className="rail-heading"><h1>ข้อความ</h1></div>
          <label className="conversation-search">
            <Icon name="search" size={20} />
            <span className="sr-only">ค้นหาผู้ป่วย</span>
            <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="ค้นหาผู้ป่วย" />
          </label>
          <div className="conversation-list">
            {filteredPatients.map((patient) => {
              const last = messagesByPatient[patient.id]?.at(-1);
              return (
                <button className={selectedId === patient.id ? 'conversation-row active' : 'conversation-row'} key={patient.id} onClick={() => setSelectedId(patient.id)} type="button">
                  <span className="patient-avatar"><Icon name="user" size={25} /></span>
                  <span className="conversation-copy"><strong>{patient.name}</strong><small>{last?.body ?? 'เริ่มการสนทนา'}</small></span>
                  <time>{last ? formatTime(last.created_at) : ''}</time>
                </button>
              );
            })}
          </div>
        </aside>
        {selected ? (
          <section className="conversation-panel">
            <header className="conversation-header">
              <div className="conversation-person"><span className="patient-avatar"><Icon name="user" size={25} /></span><div><h2>{selected.name}</h2><p><i />เชื่อมต่อกับคุณแล้ว</p></div></div>
              <div className="conversation-actions">
                <button aria-label="โทรด้วยเสียง" className="round-call-button" disabled={startingCall} onClick={() => startVideoCall('audio')} title="โทรด้วยเสียง ไม่เปิดกล้อง" type="button"><Icon name="phone" size={23} /></button>
                <button aria-label="เริ่มวิดีโอคอล" className="video-call-button" disabled={startingCall} onClick={() => startVideoCall('video')} type="button"><Icon name="video" size={22} /><span>{startingCall ? 'กำลังเชื่อม…' : 'วิดีโอคอล'}</span></button>
              </div>
            </header>
            <div className="message-timeline" ref={timelineRef}>
              {incomingCall?.patient_id === selected.id ? (
                <div className="incoming-call-banner" role="status">
                  <span><Icon name={incomingCall.media_type === 'audio' ? 'phone' : 'video'} size={20} />{incomingCall.media_type === 'audio' ? 'ผู้ป่วยกำลังโทรเสียง' : 'ผู้ป่วยกำลังวิดีโอคอล'}</span>
                  <button disabled={startingCall} onClick={joinIncomingVideoCall} type="button">รับสาย</button>
                </div>
              ) : null}
              <div className="date-divider"><span>วันนี้</span></div>
              {timeline.length ? timeline.map((entry) => {
                if (entry.call) {
                  const call = entry.call, own = call.initiated_by === therapist.id;
                  return <div className={own ? 'message-line own' : 'message-line'} key={entry.id}>
                    <div className="message-bubble call-history-card">
                      <span className="call-history-icon"><Icon name={call.media_type === 'audio' ? 'phone' : 'video'} size={26} /><small aria-label={own ? 'โทรออก' : 'สายเข้า'}>{own ? '↗' : '↙'}</small></span>
                      <span><strong>{call.media_type === 'audio' ? 'โทรเสียง' : 'วิดีโอคอล'}</strong><span className="call-history-detail">{callHistoryDetail(call, own)}</span></span>
                    </div><time>{formatTime(call.created_at)}</time>
                  </div>;
                }
                const message = entry.message;
                const own = message.sender_id === therapist.id;
                return <div className={own ? 'message-line own' : 'message-line'} key={entry.id}><div className="message-bubble">{message.body}</div><time>{formatTime(message.created_at)}{own ? ' ✓✓' : ''}</time></div>;
              }) : <div className="conversation-empty"><Icon name="message" size={30} /><strong>เริ่มคุยกับ {selected.name}</strong><span>ข้อความจะเห็นได้เฉพาะบัญชีที่เชื่อมต่อกัน</span></div>}
            </div>
            <form className="message-composer" onSubmit={sendMessage}>
              <button aria-label="แนบไฟล์ (ยังไม่เปิดใช้)" className="attachment-button" disabled type="button"><Icon name="attachment" size={24} /></button>
              <label><span className="sr-only">ข้อความ</span><textarea maxLength={4000} onChange={(event) => setDraft(event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); event.currentTarget.form?.requestSubmit(); } }} placeholder="พิมพ์ข้อความ…" rows={1} value={draft} /></label>
              <button aria-label="ส่งข้อความ" className="send-button" disabled={!draft.trim() || sending} type="submit"><Icon name="send" size={23} /></button>
            </form>
            {notice ? <p className="communication-notice" role="status">{notice}</p> : <p className="privacy-note">🔒 เฉพาะคุณและผู้ป่วยที่เชื่อมต่อกัน</p>}
          </section>
        ) : <section className="conversation-panel conversation-empty-page"><Icon name="message" size={34} /><h2>ยังไม่มีผู้ป่วยที่เชื่อมต่อ</h2><p>ต้อง assign Patient กับ Therapist ก่อนจึงจะเริ่มแชตได้</p></section>}
      </main>
      {callSession ? <WebRTCCall session={callSession} userId={therapist.id} onClose={closeVideoCall} /> : null}
    </div>
  );
}
