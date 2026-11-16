'use client';

import { useEffect, useMemo, useRef, useState } from 'react';
import Icon from './components/Icon.jsx';
import Topbar from './components/Topbar.jsx';

const dateFormatter = new Intl.DateTimeFormat('th-TH', { dateStyle: 'medium', timeStyle: 'short' });

function durationLabel(seconds) {
  const total = Math.max(0, Number(seconds) || 0);
  const minutes = Math.floor(total / 60);
  const remainder = total % 60;
  return minutes ? `${minutes}:${String(remainder).padStart(2, '0')} นาที` : `${remainder} วินาที`;
}

function SessionRecordingReview({ session, exerciseTitle, onClose }) {
  const [manifest, setManifest] = useState(null);
  const [error, setError] = useState('');
  const [isLoading, setIsLoading] = useState(true);
  const [segmentIndex, setSegmentIndex] = useState(0);

  useEffect(() => {
    const controller = new AbortController();
    setIsLoading(true);
    fetch(`/api/session-media?mediaSessionId=${encodeURIComponent(session.media_session_id)}`, {
      credentials: 'same-origin',
      signal: controller.signal,
    })
      .then(async (response) => {
        const body = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(body.error || 'โหลดวิดีโอไม่สำเร็จ');
        return body;
      })
      .then((body) => setManifest(body.manifest ?? body))
      .catch((nextError) => {
        if (nextError.name !== 'AbortError') setError(nextError.message);
      })
      .finally(() => setIsLoading(false));
    return () => controller.abort();
  }, [session.media_session_id]);

  useEffect(() => {
    const closeOnEscape = (event) => { if (event.key === 'Escape') onClose(); };
    document.addEventListener('keydown', closeOnEscape);
    return () => document.removeEventListener('keydown', closeOnEscape);
  }, [onClose]);

  const segments = manifest?.segments ?? [];
  const segment = segments[segmentIndex] ?? null;

  return (
    <div className="recording-review-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }} role="presentation">
      <section aria-labelledby="recording-review-title" aria-modal="true" className="recording-review" role="dialog">
        <header>
          <div>
            <span>วิดีโอ Session</span>
            <h2 id="recording-review-title">{exerciseTitle}</h2>
            <time dateTime={session.ended_at}>{dateFormatter.format(new Date(session.ended_at))}</time>
          </div>
          <button aria-label="ปิดหน้าต่างวิดีโอ" className="recording-review-close" onClick={onClose} type="button"><Icon name="close" size={20} /></button>
        </header>

        <div className="recording-review-player">
          {isLoading ? <div className="recording-review-state"><span className="recording-review-spinner" />กำลังโหลดข้อมูลวิดีโอ…</div> : null}
          {!isLoading && error ? <div className="recording-review-state error"><Icon name="video" size={28} />เปิดวิดีโอไม่สำเร็จ<br /><small>{error}</small></div> : null}
          {!isLoading && !error && manifest?.status !== 'ready' ? <div className="recording-review-state"><Icon name="video" size={28} />กำลังอัปโหลดวิดีโอจาก iPhone<br /><small>กลับมาตรวจสอบอีกครั้งเมื่ออัปโหลดเสร็จ</small></div> : null}
          {!isLoading && !error && manifest?.status === 'ready' && !segment ? <div className="recording-review-state"><Icon name="video" size={28} />Session นี้ไม่มีไฟล์วิดีโอ</div> : null}
          {segment ? (
            <video
              controls
              key={segment.playbackUrl}
              onEnded={() => { if (segmentIndex + 1 < segments.length) setSegmentIndex(segmentIndex + 1); }}
              playsInline
              preload="metadata"
              src={segment.playbackUrl}
            >เบราว์เซอร์นี้ไม่รองรับการเล่นวิดีโอ</video>
          ) : null}
        </div>

        {segments.length > 1 ? (
          <footer>
            <span>ช่วงที่ {segmentIndex + 1} จาก {segments.length}</span>
            <div>{segments.map((item, index) => <button aria-label={`เปิดวิดีโอช่วงที่ ${index + 1}`} className={index === segmentIndex ? 'active' : ''} key={item.index} onClick={() => setSegmentIndex(index)} type="button">{index + 1}</button>)}</div>
          </footer>
        ) : null}
      </section>
    </div>
  );
}

function SessionReviewDialog({ initialAIReview, initialTherapistReview, session, exerciseTitle, onClose, onTherapistReviewSaved }) {
  const [result, setResult] = useState(initialAIReview ?? null);
  const [error, setError] = useState('');
  const [isLoading, setIsLoading] = useState(true);
  const [isGeneratingAIReview, setIsGeneratingAIReview] = useState(false);
  const [therapistBody, setTherapistBody] = useState(initialTherapistReview?.body ?? '');
  const [therapistError, setTherapistError] = useState('');
  const [therapistSaved, setTherapistSaved] = useState(Boolean(initialTherapistReview));
  const [isSavingTherapistReview, setIsSavingTherapistReview] = useState(false);

  useEffect(() => {
    const controller = new AbortController();
    setIsLoading(true);
    setError('');
    fetch(`/api/session-reviews?sessionId=${encodeURIComponent(session.id)}`, {
      method: 'GET',
      credentials: 'same-origin',
      signal: controller.signal,
    })
      .then(async (response) => {
        const body = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(body.error || 'โหลด AI review ไม่สำเร็จ');
        return body;
      })
      .then(setResult)
      .catch((nextError) => {
        if (nextError.name !== 'AbortError') setError(nextError.message);
      })
      .finally(() => setIsLoading(false));
    return () => controller.abort();
  }, [session.id]);

  useEffect(() => {
    const closeOnEscape = (event) => { if (event.key === 'Escape') onClose(); };
    document.addEventListener('keydown', closeOnEscape);
    return () => document.removeEventListener('keydown', closeOnEscape);
  }, [onClose]);

  const isProcessing = result?.status === 'processing';
  const isFailed = result?.status === 'failed';

  const generateAIReview = async () => {
    setIsGeneratingAIReview(true);
    setError('');
    try {
      const response = await fetch('/api/session-reviews', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ sessionId: session.id }),
      });
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(payload.error || 'สร้าง AI review ไม่สำเร็จ');
      setResult(payload);
    } catch (nextError) {
      setError(nextError.message);
      setResult(null);
    } finally {
      setIsGeneratingAIReview(false);
    }
  };

  const saveTherapistReview = async (event) => {
    event.preventDefault();
    const body = therapistBody.trim();
    if (!body) {
      setTherapistError('กรุณาเขียน Therapist review ก่อนบันทึก');
      return;
    }
    setIsSavingTherapistReview(true);
    setTherapistError('');
    setTherapistSaved(false);
    try {
      const response = await fetch('/api/therapist-reviews', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ sessionId: session.id, body }),
      });
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(payload.error || 'บันทึก Therapist review ไม่สำเร็จ');
      setTherapistBody(payload.review.body);
      setTherapistSaved(true);
      onTherapistReviewSaved(payload.review);
    } catch (nextError) {
      setTherapistError(nextError.message);
    } finally {
      setIsSavingTherapistReview(false);
    }
  };

  return (
    <div className="recording-review-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget) onClose(); }} role="presentation">
      <section aria-labelledby="session-review-title" aria-modal="true" className="recording-review session-review" role="dialog">
        <header>
          <div>
            <span>SESSION REVIEW</span>
            <h2 id="session-review-title">{exerciseTitle}</h2>
            <time dateTime={session.ended_at}>{dateFormatter.format(new Date(session.ended_at))}</time>
          </div>
          <button aria-label="ปิดหน้าต่าง Session review" className="recording-review-close" onClick={onClose} type="button"><Icon name="close" size={20} /></button>
        </header>
        <div className="session-review-content">
          <section className="therapist-review-panel">
            <div className="session-review-section-heading"><span>1</span><div><h3>Therapist review</h3><p>ข้อความจากนักกายภาพจะปรากฏใน Session history ของ patient บน iPhone</p></div></div>
            <form onSubmit={saveTherapistReview}>
              <label htmlFor={`therapist-review-${session.id}`} className="sr-only">Therapist review</label>
              <textarea
                id={`therapist-review-${session.id}`}
                maxLength={4000}
                onChange={(event) => { setTherapistBody(event.target.value); setTherapistSaved(false); }}
                placeholder="เขียนข้อสังเกต คำแนะนำ หรือสิ่งที่ต้องโฟกัสในครั้งถัดไป"
                rows={5}
                value={therapistBody}
              />
              <div className="therapist-review-actions">
                <span>{therapistError || (therapistSaved ? 'บันทึกแล้ว · patient สามารถเปิดดูได้' : `${therapistBody.length.toLocaleString('th-TH')} / 4,000`)}</span>
                <button className="history-ai-button" disabled={isSavingTherapistReview} type="submit">{isSavingTherapistReview ? 'กำลังบันทึก…' : 'บันทึก Therapist review'}</button>
              </div>
            </form>
          </section>

          <section className="ai-review-panel">
            <div className="session-review-section-heading"><span>2</span><div><h3>AI review</h3><p>สร้างอัตโนมัติจาก JSON สรุป session โดยไม่ส่งวิดีโอ</p></div></div>
            {isLoading ? <div className="ai-review-state compact"><span className="recording-review-spinner" />กำลังโหลด AI review…</div> : null}
            {!isLoading && error ? <div className="ai-review-state compact error"><strong>ยังไม่มี AI review</strong><span>{error}</span><button className="history-ai-button" disabled={isGeneratingAIReview} onClick={generateAIReview} type="button">{isGeneratingAIReview ? 'กำลังสร้าง…' : 'สร้าง AI review ตอนนี้'}</button></div> : null}
            {!isLoading && isProcessing ? <div className="ai-review-state compact"><span className="recording-review-spinner" />กำลังสรุป session นี้อัตโนมัติ…</div> : null}
            {!isLoading && isFailed ? <div className="ai-review-state compact error"><strong>AI review ยังไม่พร้อม</strong><span>ข้อมูล session ถูกบันทึกแล้ว แต่การสรุปอัตโนมัติทำไม่สำเร็จ</span><button className="history-ai-button" disabled={isGeneratingAIReview} onClick={generateAIReview} type="button">{isGeneratingAIReview ? 'กำลังสร้าง…' : 'ลองสร้าง AI review ใหม่'}</button></div> : null}
            {!isLoading && result?.status === 'ready' ? (
              <div className="ai-review-result">
                <div className="ai-review-summary"><h4>สรุป</h4><p>{result.review.summary}</p></div>
                <div><h4>ข้อสังเกตจากข้อมูล</h4><ul>{result.review.observations.map((item) => <li key={item}>{item}</li>)}</ul></div>
                <div><h4>โฟกัสครั้งถัดไป</h4><ul>{result.review.focusNextSession.map((item) => <li key={item}>{item}</li>)}</ul></div>
                <p className="ai-review-disclaimer">{result.review.disclaimer}</p>
              </div>
            ) : null}
          </section>
        </div>
        <footer className="session-review-footer">
          <span>Review ทั้งสองส่วนผูกกับ session นี้และเปิดดูย้อนหลังได้</span>
        </footer>
      </section>
    </div>
  );
}

export default function SessionHistoryWorkspace({ catalog, initialReviews, initialSessions, initialTherapistReviews = [], patients, therapist, onSignOut }) {
  const [patientId, setPatientId] = useState(patients[0]?.id ?? '');
  const [isPatientPickerOpen, setIsPatientPickerOpen] = useState(false);
  const [patientQuery, setPatientQuery] = useState('');
  const [reviewSession, setReviewSession] = useState(null);
  const [aiReviewSession, setAiReviewSession] = useState(null);
  const [therapistReviewBySessionId, setTherapistReviewBySessionId] = useState(() => new Map(initialTherapistReviews.map((item) => [item.session_id, item])));
  const patientPickerRef = useRef(null);
  const patientSearchRef = useRef(null);
  const exerciseById = useMemo(() => new Map(catalog.map((item) => [item.id, item])), [catalog]);
  const reviewBySessionId = useMemo(() => new Map(initialReviews.map((item) => [item.session_id, item])), [initialReviews]);
  const sessions = useMemo(
    () => initialSessions.filter((session) => session.patient_id === patientId),
    [initialSessions, patientId],
  );
  const patient = patients.find(({ id }) => id === patientId) ?? null;
  const normalizedPatientQuery = patientQuery.trim().toLocaleLowerCase();
  const filteredPatients = useMemo(() => (
    normalizedPatientQuery
      ? patients.filter((item) => `${item.name} ${item.caseCode}`.toLocaleLowerCase().includes(normalizedPatientQuery))
      : patients
  ), [normalizedPatientQuery, patients]);
  const totals = useMemo(() => sessions.reduce((result, session) => ({
    reps: result.reps + session.completed_reps,
    seconds: result.seconds + session.duration_seconds,
  }), { reps: 0, seconds: 0 }), [sessions]);

  useEffect(() => {
    if (!isPatientPickerOpen) return undefined;
    patientSearchRef.current?.focus();

    const closeOnOutsidePress = (event) => {
      if (!patientPickerRef.current?.contains(event.target)) setIsPatientPickerOpen(false);
    };
    const closeOnEscape = (event) => {
      if (event.key === 'Escape') setIsPatientPickerOpen(false);
    };

    document.addEventListener('pointerdown', closeOnOutsidePress);
    document.addEventListener('keydown', closeOnEscape);
    return () => {
      document.removeEventListener('pointerdown', closeOnOutsidePress);
      document.removeEventListener('keydown', closeOnEscape);
    };
  }, [isPatientPickerOpen]);

  const togglePatientPicker = () => {
    setIsPatientPickerOpen((current) => !current);
    setPatientQuery('');
  };

  const selectPatient = (nextPatientId) => {
    setPatientId(nextPatientId);
    setIsPatientPickerOpen(false);
    setPatientQuery('');
  };

  const saveTherapistReviewLocally = (review) => {
    setTherapistReviewBySessionId((current) => new Map(current).set(review.session_id, review));
  };

  return (
    <div className="app-shell history-shell" lang="th">
      <Topbar activeSection="history" lang="th" onSignOut={onSignOut} therapist={therapist} />
      <main className="history-page">
        <header className="history-heading">
          <div>
            <h1>ประวัติการฝึก</h1>
            <p>ติดตาม session ที่ผู้ป่วยทำเสร็จจากแอป iPhone</p>
          </div>
          <div className="history-patient-picker patient-plan-selector-control" ref={patientPickerRef}>
            <span id="history-patient-picker-label">ผู้ป่วย</span>
            <button
              aria-controls="history-patient-options"
              aria-expanded={isPatientPickerOpen}
              aria-haspopup="listbox"
              aria-labelledby="history-patient-picker-label history-patient-picker-value"
              className="patient-selector-trigger"
              onClick={togglePatientPicker}
              type="button"
            >
              <span id="history-patient-picker-value">
                {patient
                  ? <><strong>{patient.name}</strong><small>{patient.caseCode}</small></>
                  : '— เลือกผู้ป่วย —'}
              </span>
              <svg aria-hidden="true" className="patient-selector-caret" viewBox="0 0 20 20">
                <path d="m5 7.5 5 5 5-5" />
              </svg>
            </button>
            {isPatientPickerOpen ? (
              <div className="patient-selector-popover">
                <label className="patient-selector-search">
                  <Icon name="search" size={17} />
                  <span className="sr-only">ค้นหาผู้ป่วย</span>
                  <input
                    aria-controls="history-patient-options"
                    onChange={(event) => setPatientQuery(event.target.value)}
                    placeholder="ค้นหาชื่อหรือรหัสผู้ป่วย"
                    ref={patientSearchRef}
                    type="search"
                    value={patientQuery}
                  />
                </label>
                <div className="patient-selector-result-count" role="status">
                  พบ {filteredPatients.length.toLocaleString('th-TH')} คน
                </div>
                <div className="patient-selector-options" id="history-patient-options" role="listbox">
                  {filteredPatients.length ? filteredPatients.map((item) => {
                    const isSelected = item.id === patientId;
                    return (
                      <button
                        aria-selected={isSelected}
                        className={`patient-selector-option${isSelected ? ' selected' : ''}`}
                        key={item.id}
                        onClick={() => selectPatient(item.id)}
                        role="option"
                        type="button"
                      >
                        <span aria-hidden="true" className="patient-selector-avatar">
                          {item.name.trim().charAt(0).toLocaleUpperCase() || 'P'}
                        </span>
                        <span className="patient-selector-option-copy">
                          <strong>{item.name}</strong>
                          <small>{item.caseCode}</small>
                        </span>
                        {isSelected ? <Icon className="patient-selector-check" name="check" size={18} /> : null}
                      </button>
                    );
                  }) : <p className="patient-selector-empty">ไม่พบผู้ป่วยที่ตรงกับคำค้นหา</p>}
                </div>
              </div>
            ) : null}
          </div>
        </header>

        {patient ? (
          <>
            <section aria-label="สรุปประวัติ" className="history-summary">
              <div><span>Session ทั้งหมด</span><strong>{sessions.length.toLocaleString('th-TH')}</strong></div>
              <div><span>ทำสำเร็จรวม</span><strong>{totals.reps.toLocaleString('th-TH')} <small>ครั้ง</small></strong></div>
              <div><span>เวลาฝึกรวม</span><strong>{Math.round(totals.seconds / 60).toLocaleString('th-TH')} <small>นาที</small></strong></div>
              <div><span>ล่าสุด</span><strong className="history-latest">{sessions[0] ? dateFormatter.format(new Date(sessions[0].ended_at)) : '—'}</strong></div>
            </section>

            <section className="history-list" aria-label={`ประวัติการฝึกของ ${patient.name}`}>
              <div className="history-list-heading"><h2>{patient.name}</h2><span>{patient.caseCode}</span></div>
              {sessions.length ? sessions.map((session) => {
                const exercise = exerciseById.get(session.exercise_id);
                const review = reviewBySessionId.get(session.id);
                return (
                  <article className="history-row" key={session.id}>
                    <span className="history-row-icon"><Icon name="history" size={22} /></span>
                    <div className="history-row-main">
                      <strong>{exercise?.title_th ?? session.exercise_id}</strong>
                      <time dateTime={session.ended_at}>{dateFormatter.format(new Date(session.ended_at))}</time>
                    </div>
                    <dl>
                      <div><dt>ครั้ง</dt><dd>{session.completed_reps}</dd></div>
                      <div><dt>เซ็ต</dt><dd>{session.completed_sets}</dd></div>
                      <div><dt>เวลา</dt><dd>{durationLabel(session.duration_seconds)}</dd></div>
                      <div><dt>คะแนน</dt><dd>{session.overall_score == null ? '—' : `${session.overall_score}%`}</dd></div>
                    </dl>
                    <div className="history-row-actions">
                      <button className="history-ai-button" onClick={() => setAiReviewSession(session)} type="button">{therapistReviewBySessionId.has(session.id) ? 'เปิด Session review' : 'เขียน Review'}</button>
                      {session.media_session_id ? (
                        <button className="history-video-button" onClick={() => setReviewSession(session)} type="button">
                          <Icon name="video" size={17} /> ดูวิดีโอ
                        </button>
                      ) : <span className="history-video-unavailable">ไม่มีวิดีโอ</span>}
                    </div>
                  </article>
                );
              }) : (
                <div className="history-empty"><Icon name="history" size={34} /><strong>ยังไม่มีประวัติการฝึก</strong><span>รายการจะปรากฏเมื่อผู้ป่วยทำท่าฝึกจบในแอป iPhone</span></div>
              )}
            </section>
          </>
        ) : (
          <section className="history-empty standalone"><Icon name="user" size={34} /><strong>ยังไม่มีผู้ป่วยที่เชื่อมต่อ</strong><span>ต้องเชื่อม Patient กับ Therapist ก่อนจึงจะดูประวัติได้</span></section>
        )}
      </main>
      {reviewSession ? (
        <SessionRecordingReview
          exerciseTitle={exerciseById.get(reviewSession.exercise_id)?.title_th ?? reviewSession.exercise_id}
          onClose={() => setReviewSession(null)}
          session={reviewSession}
        />
      ) : null}
      {aiReviewSession ? (
        <SessionReviewDialog
          exerciseTitle={exerciseById.get(aiReviewSession.exercise_id)?.title_th ?? aiReviewSession.exercise_id}
          initialAIReview={reviewBySessionId.get(aiReviewSession.id)}
          initialTherapistReview={therapistReviewBySessionId.get(aiReviewSession.id)}
          onClose={() => setAiReviewSession(null)}
          onTherapistReviewSaved={saveTherapistReviewLocally}
          session={aiReviewSession}
        />
      ) : null}
    </div>
  );
}
