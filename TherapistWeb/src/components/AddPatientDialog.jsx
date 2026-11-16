import { useEffect, useRef, useState } from 'react';
import Icon from './Icon.jsx';

export default function AddPatientDialog({ lang, open, onClose, onCreate }) {
  const th = lang === 'th';
  const [name, setName] = useState('');
  const [caseCode, setCaseCode] = useState('');
  const nameInput = useRef(null);

  useEffect(() => {
    if (!open) return undefined;
    setName('');
    setCaseCode('');
    const focusTimer = window.setTimeout(() => nameInput.current?.focus(), 0);
    const closeOnEscape = (event) => {
      if (event.key === 'Escape') onClose();
    };
    window.addEventListener('keydown', closeOnEscape);
    return () => {
      window.clearTimeout(focusTimer);
      window.removeEventListener('keydown', closeOnEscape);
    };
  }, [onClose, open]);

  if (!open) return null;
  return (
    <div className="dialog-backdrop" role="presentation" onMouseDown={(event) => {
      if (event.target === event.currentTarget) onClose();
    }}>
      <section className="dialog" role="dialog" aria-modal="true" aria-labelledby="add-patient-title">
        <div className="dialog-heading">
          <div>
            <div className="eyebrow">{th ? 'รายชื่อผู้ป่วย' : 'Patient roster'}</div>
            <h2 id="add-patient-title">{th ? 'เพิ่มผู้ป่วยตัวอย่าง' : 'Add sample patient'}</h2>
          </div>
          <button className="dialog-close" type="button" onClick={onClose} aria-label={th ? 'ปิด' : 'Close'}><Icon name="close" /></button>
        </div>
        <form onSubmit={(event) => {
          event.preventDefault();
          if (!name.trim()) return;
          onCreate({ name: name.trim(), caseCode: caseCode.trim() || `PT-${Date.now().toString().slice(-4)}` });
        }}>
          <label>
            <span>{th ? 'ชื่อผู้ป่วย' : 'Patient name'}</span>
            <input ref={nameInput} value={name} onChange={(event) => setName(event.target.value)} placeholder={th ? 'ชื่อสำหรับแสดงผล' : 'Display name'} />
          </label>
          <label>
            <span>{th ? 'รหัสเคส' : 'Case code'}</span>
            <input value={caseCode} onChange={(event) => setCaseCode(event.target.value.toUpperCase())} placeholder="PT-0244" />
          </label>
          <p>{th ? 'ข้อมูลส่วนนี้เก็บใน browser ของเครื่องนี้เท่านั้น' : 'This data stays in this browser only.'}</p>
          <div className="dialog-actions">
            <button className="button ghost" type="button" onClick={onClose}>{th ? 'ยกเลิก' : 'Cancel'}</button>
            <button className="button primary" disabled={!name.trim()} type="submit"><Icon name="userPlus" size={17} />{th ? 'เพิ่มผู้ป่วย' : 'Add patient'}</button>
          </div>
        </form>
      </section>
    </div>
  );
}
