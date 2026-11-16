import Icon from './Icon.jsx';

export function SectionLabel({ icon, children, detail }) {
  return (
    <div className="section-heading">
      <span className="section-icon"><Icon name={icon} size={16} /></span>
      <span>
        <span className="eyebrow">{children}</span>
        {detail ? <span className="section-detail">{detail}</span> : null}
      </span>
    </div>
  );
}

export function Stepper({ label, value, min, max, onChange, compact = false }) {
  const clamp = (next) => Math.min(max, Math.max(min, Math.round(Number(next) || min)));
  return (
    <div className={`stepper-field${compact ? ' compact' : ''}`}>
      {label ? <span className="field-caption">{label}</span> : null}
      <div className="stepper">
        <button type="button" aria-label={`${label ?? 'value'} ลด`} onClick={() => onChange(clamp(value - 1))}>−</button>
        <input
          aria-label={label}
          inputMode="numeric"
          max={max}
          min={min}
          onChange={(event) => onChange(clamp(event.target.value))}
          type="number"
          value={value}
        />
        <button type="button" aria-label={`${label ?? 'value'} เพิ่ม`} onClick={() => onChange(clamp(value + 1))}>+</button>
      </div>
    </div>
  );
}

export function Card({ className = '', children, ...props }) {
  return <section className={`card ${className}`.trim()} {...props}>{children}</section>;
}
