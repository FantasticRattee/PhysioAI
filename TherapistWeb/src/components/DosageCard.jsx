import Icon from './Icon.jsx';
import { Card, SectionLabel, Stepper } from './PlanControls.jsx';

export default function DosageCard({ exercises, lang, items, onUpdate, onRemove }) {
  const th = lang === 'th';
  return (
    <Card className="dosage-card" data-testid="dosage-card">
      <SectionLabel icon="exercises" detail={items.length ? `${items.length} ${th ? 'ท่าในโปรแกรม' : 'exercises in plan'}` : ''}>
        {th ? 'ปริมาณการฝึก' : 'Exercise dosage'}
      </SectionLabel>
      {!items.length ? (
        <div className="empty-state">
          <span className="empty-icon"><Icon name="plus" size={20} /></span>
          <div>
            <strong>{th ? 'ยังไม่มีท่าฝึก' : 'No exercises yet'}</strong>
            <p>{th ? 'เลือกท่าจากด้านบนเพื่อเริ่มสร้างโปรแกรม' : 'Choose an exercise above to start building the plan.'}</p>
          </div>
        </div>
      ) : (
        <div className="dose-list">
          {items.map((item, index) => {
            const exercise = exercises.find(({ id }) => id === item.exerciseId);
            if (!exercise) return null;
            return (
              <article className="dose-row" key={item.exerciseId}>
                <div className="dose-index">{String(index + 1).padStart(2, '0')}</div>
                <div className="dose-copy">
                  <strong>{th ? exercise.titleTh : exercise.titleEn}</strong>
                  <span className="ready-state">✓ {th ? exercise.readinessTh : exercise.readinessEn}</span>
                </div>
                <div className="dose-controls">
                  <Stepper
                    compact
                    label={exercise.type === 'hold' ? (th ? 'วินาที' : 'Seconds') : (th ? 'ครั้ง' : 'Reps')}
                    max={exercise.type === 'hold' ? 120 : 50}
                    min={1}
                    value={exercise.type === 'hold' ? item.holdSec : item.reps}
                    onChange={(value) => onUpdate(item.exerciseId, exercise.type === 'hold' ? { holdSec: value } : { reps: value })}
                  />
                  <Stepper
                    compact
                    label={th ? 'เซ็ต' : 'Sets'}
                    max={10}
                    min={1}
                    value={item.sets}
                    onChange={(value) => onUpdate(item.exerciseId, { sets: value })}
                  />
                </div>
                <button className="remove-button" type="button" onClick={() => onRemove(item.exerciseId)} aria-label={`${th ? 'ลบ' : 'Remove'} ${th ? exercise.titleTh : exercise.titleEn}`}>
                  <Icon name="trash" size={17} />
                </button>
              </article>
            );
          })}
        </div>
      )}
    </Card>
  );
}
