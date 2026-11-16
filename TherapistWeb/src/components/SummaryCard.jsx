import Icon from './Icon.jsx';
import { Card } from './PlanControls.jsx';

export default function SummaryCard({ isSaving, lang, plan, patient, onSave }) {
  const th = lang === 'th';
  const exerciseCount = plan.items.length;
  const totalSessions = exerciseCount * plan.freqPerDay * plan.durationDays;
  const empty = exerciseCount === 0;
  return (
    <Card className={`summary-card${empty ? ' empty' : ''}`} data-testid="summary-card">
      <div className="summary-accent" />
      <div className="eyebrow">{th ? 'โปรแกรม' : 'Program'}</div>
      <div className="summary-hero">
        <strong>{empty ? '—' : totalSessions}</strong>
        <span>
          <b>{th ? 'เซสชัน' : 'sessions'}</b>
          <small>{empty ? (th ? 'ยังไม่มีโปรแกรม' : 'Nothing scheduled yet') : `${th ? 'ภายใน' : 'over'} ${plan.durationDays} ${th ? 'วัน' : 'days'}`}</small>
        </span>
      </div>
      {empty ? (
        <p className="summary-hint">{th ? 'เพิ่มท่าฝึกเพื่อสร้างโปรแกรม จำนวนรวมจะอัปเดตให้อัตโนมัติ' : 'Add exercises to build the program. The total updates automatically.'}</p>
      ) : (
        <div className="summary-chips">
          <span><b>{exerciseCount}</b> {th ? 'ท่า' : 'exercises'}</span>
          <span><b>{plan.freqPerDay}</b> {th ? 'ครั้ง/วัน' : '× / day'}</span>
          <span>{patient?.caseCode}</span>
        </div>
      )}
      <button className="button primary save-button" disabled={empty || isSaving} onClick={onSave} type="button">
        <Icon name="save" size={17} />
        {isSaving ? (th ? 'กำลังส่งไป iPhone…' : 'Sending to iPhone…') : (th ? 'บันทึกและส่งไป iPhone' : 'Save and send to iPhone')}
      </button>
      {plan.updatedAt ? (
        <small className="saved-at">{th ? 'บันทึกล่าสุด' : 'Last saved'} · {new Intl.DateTimeFormat(th ? 'th-TH' : 'en-US', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(plan.updatedAt))}</small>
      ) : null}
    </Card>
  );
}
