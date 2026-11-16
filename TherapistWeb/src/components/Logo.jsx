export default function Logo({ compact = false }) {
  return (
    <div className="brand-lockup" aria-label="PhysioAI">
      <span className="logo-mark" aria-hidden="true">
        <svg viewBox="0 0 64 64" role="presentation">
          <path d="M19 46 47 40 37 14" />
          <circle cx="19" cy="46" r="8" />
        </svg>
      </span>
      <span className="brand-copy">
        <span className="wordmark">Physio<strong>AI</strong></span>
        {!compact ? <h1 className="product-name">Therapist Plan Builder</h1> : null}
      </span>
    </div>
  );
}
