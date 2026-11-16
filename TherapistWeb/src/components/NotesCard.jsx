import { Card, SectionLabel } from './PlanControls.jsx';

export default function NotesCard({ lang, notes, onChange }) {
  const th = lang === 'th';
  return (
    <Card className="notes-card">
      <SectionLabel icon="note" detail={th ? 'ข้อความนี้จะแสดงให้ผู้ป่วยเห็น' : 'This message will be visible to the patient'}>
        {th ? 'คำแนะนำสำหรับผู้ป่วย' : 'Notes for patient'}
      </SectionLabel>
      <textarea
        aria-label={th ? 'คำแนะนำสำหรับผู้ป่วย' : 'Notes for patient'}
        onChange={(event) => onChange(event.target.value)}
        placeholder={th ? 'เช่น หยุดถ้าเจ็บแปลบ · พัก 30 วินาทีระหว่างเซ็ต' : 'e.g. Stop if you feel sharp pain. Rest 30s between sets.'}
        rows={4}
        value={notes}
      />
    </Card>
  );
}
