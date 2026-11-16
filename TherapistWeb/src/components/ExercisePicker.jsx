import Icon from './Icon.jsx';
import { Card, SectionLabel } from './PlanControls.jsx';

export default function ExercisePicker({ exercises, lang, selectedIds, onToggle }) {
  const th = lang === 'th';
  const groups = [{
    id: 'production',
    label: th ? 'ท่าที่มีในแอปผู้ป่วย iOS' : 'Exercises available in the iOS patient app',
  }];

  return (
    <Card className="exercise-picker-card" data-testid="exercise-picker">
      <SectionLabel
        icon="exercises"
        detail={th ? 'เลือกท่าที่ต้องการเพิ่มในโปรแกรม' : 'Choose exercises to add to the program'}
      >
        {th ? 'ท่าฝึก' : 'Exercises'}
      </SectionLabel>
      {groups.map((group) => (
        <div className="exercise-group" key={group.id}>
          <div className="sub-label">{group.label}</div>
          <div className="exercise-chip-list">
            {exercises.filter((exercise) => exercise.group === group.id).map((exercise) => {
              const selected = selectedIds.has(exercise.id);
              return (
                <button
                  aria-pressed={selected}
                  className={`exercise-chip${selected ? ' selected' : ''}`}
                  key={exercise.id}
                  onClick={() => onToggle(exercise.id)}
                  type="button"
                >
                  <span className="chip-icon"><Icon name={selected ? 'check' : 'plus'} size={13} strokeWidth={2.2} /></span>
                  <span>{th ? exercise.titleTh : exercise.titleEn}</span>
                  <small>{exercise.runtime}</small>
                </button>
              );
            })}
          </div>
        </div>
      ))}
    </Card>
  );
}
