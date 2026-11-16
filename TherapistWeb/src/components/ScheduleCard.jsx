import { Card, SectionLabel, Stepper } from './PlanControls.jsx';

function addDays(dateString, days) {
  if (!dateString) return null;
  const date = new Date(`${dateString}T00:00:00`);
  if (Number.isNaN(date.getTime())) return null;
  date.setDate(date.getDate() + Number(days || 0));
  return date;
}

function formatDate(date, lang) {
  if (!date) return '—';
  return new Intl.DateTimeFormat(lang === 'th' ? 'th-TH' : 'en-US', {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  }).format(date);
}

export default function ScheduleCard({ lang, plan, onPatch }) {
  const th = lang === 'th';
  const endDate = addDays(plan.startDate, plan.durationDays);
  const weekCount = Math.max(1, Math.ceil(plan.durationDays / 7));
  return (
    <Card className="schedule-card" data-testid="schedule-card">
      <SectionLabel icon="calendar" detail={th ? 'กำหนดความถี่และช่วงโปรแกรม' : 'Set cadence and program span'}>
        {th ? 'ตารางเวลา' : 'Schedule'}
      </SectionLabel>

      <div className="sub-label">{th ? 'ความถี่' : 'Cadence'}</div>
      <div className="schedule-row">
        <span className="field-title">{th ? 'ครั้ง / วัน' : 'Times / day'}</span>
        <Stepper compact min={1} max={6} value={plan.freqPerDay} onChange={(freqPerDay) => onPatch({ freqPerDay })} />
      </div>

      <div className="sub-label">{th ? 'ช่วงเวลา' : 'Timeframe'}</div>
      <label className="schedule-row date-row">
        <span className="field-title">{th ? 'วันที่เริ่ม' : 'Start date'}</span>
        <input required type="date" value={plan.startDate} onChange={(event) => onPatch({ startDate: event.target.value })} />
      </label>
      <div className="schedule-row">
        <span className="field-title">{th ? 'ระยะเวลา' : 'Length'}</span>
        <div className="duration-control">
          <Stepper compact min={1} max={365} value={plan.durationDays} onChange={(durationDays) => onPatch({ durationDays })} />
          <span>{th ? 'วัน' : 'days'}</span>
        </div>
      </div>

      <div className="timeline">
        <div className="timeline-heading">
          <span className="eyebrow">{th ? 'ช่วงโปรแกรม' : 'Program span'}</span>
          <strong>{weekCount} {th ? 'สัปดาห์' : weekCount === 1 ? 'week' : 'weeks'}</strong>
        </div>
        <div className="timeline-track" aria-hidden="true">
          <span className="timeline-fill" />
          <span className="timeline-cap start" />
          <span className="timeline-cap end" />
        </div>
        <div className="timeline-dates">
          <span><small>{th ? 'เริ่ม' : 'Start'}</small>{formatDate(addDays(plan.startDate, 0), lang)}</span>
          <span><small>{th ? 'สิ้นสุด' : 'Ends'}</small>{formatDate(endDate, lang)}</span>
        </div>
      </div>
    </Card>
  );
}
