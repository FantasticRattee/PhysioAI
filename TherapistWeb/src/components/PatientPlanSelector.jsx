import { useEffect, useMemo, useRef, useState } from 'react';
import Icon from './Icon.jsx';

function searchablePatientText(patient) {
  return `${patient.name} ${patient.caseCode}`.toLocaleLowerCase();
}

export default function PatientPlanSelector({ lang, patients, patientId, onChange }) {
  const th = lang === 'th';
  const [isOpen, setIsOpen] = useState(false);
  const [query, setQuery] = useState('');
  const rootRef = useRef(null);
  const searchRef = useRef(null);
  const selectedPatient = patients.find(({ id }) => id === patientId) ?? null;
  const normalizedQuery = query.trim().toLocaleLowerCase();
  const filteredPatients = useMemo(() => (
    normalizedQuery
      ? patients.filter((patient) => searchablePatientText(patient).includes(normalizedQuery))
      : patients
  ), [normalizedQuery, patients]);

  useEffect(() => {
    if (!isOpen) return undefined;
    searchRef.current?.focus();

    const closeOnOutsidePress = (event) => {
      if (!rootRef.current?.contains(event.target)) setIsOpen(false);
    };
    const closeOnEscape = (event) => {
      if (event.key === 'Escape') setIsOpen(false);
    };

    document.addEventListener('pointerdown', closeOnOutsidePress);
    document.addEventListener('keydown', closeOnEscape);
    return () => {
      document.removeEventListener('pointerdown', closeOnOutsidePress);
      document.removeEventListener('keydown', closeOnEscape);
    };
  }, [isOpen]);

  const toggleDropdown = () => {
    setIsOpen((current) => !current);
    setQuery('');
  };

  const selectPatient = (nextPatientId) => {
    onChange(nextPatientId);
    setIsOpen(false);
    setQuery('');
  };

  return (
    <section className="patient-plan-selector" data-testid="patient-plan-selector">
      <span className="patient-plan-selector-icon"><Icon name="user" size={21} /></span>
      <div className="patient-plan-selector-copy">
        <span className="eyebrow">{th ? 'มอบหมายแผนให้ผู้ป่วย' : 'Assign plan to patient'}</span>
        <strong>{th ? 'เลือก Patient ก่อนสร้างหรือแก้ไขแผน' : 'Choose a patient before building or editing a plan'}</strong>
        <small id="patient-plan-selector-help">
          {th
            ? `แผนจะถูกส่งไปยังบัญชีที่เลือกเท่านั้น · เชื่อมแล้ว ${patients.length.toLocaleString('th-TH')} คน`
            : `The plan will be delivered only to the selected Patient account · ${patients.length.toLocaleString('en-US')} assigned`}
        </small>
      </div>
      <div className="patient-plan-selector-control" ref={rootRef}>
        <span id="patient-plan-selector-label">{th ? 'ผู้รับแผน' : 'Plan recipient'}</span>
        <button
          aria-controls="patient-plan-options"
          aria-describedby="patient-plan-selector-help"
          aria-expanded={isOpen}
          aria-haspopup="listbox"
          aria-labelledby="patient-plan-selector-label patient-plan-selector-value"
          className="patient-selector-trigger"
          onClick={toggleDropdown}
          type="button"
        >
          <span id="patient-plan-selector-value">
            {selectedPatient
              ? <><strong>{selectedPatient.name}</strong><small>{selectedPatient.caseCode}</small></>
              : (th ? '— เลือก Patient —' : '— Select a Patient —')}
          </span>
          <svg aria-hidden="true" className="patient-selector-caret" viewBox="0 0 20 20">
            <path d="m5 7.5 5 5 5-5" />
          </svg>
        </button>
        {isOpen ? (
          <div className="patient-selector-popover">
            <label className="patient-selector-search">
              <Icon name="search" size={17} />
              <span className="sr-only">{th ? 'ค้นหาผู้ป่วย' : 'Search patients'}</span>
              <input
                aria-controls="patient-plan-options"
                onChange={(event) => setQuery(event.target.value)}
                placeholder={th ? 'ค้นหาชื่อหรือรหัสผู้ป่วย' : 'Search name or patient ID'}
                ref={searchRef}
                type="search"
                value={query}
              />
            </label>
            <div className="patient-selector-result-count" role="status">
              {th
                ? `พบ ${filteredPatients.length.toLocaleString('th-TH')} คน`
                : `${filteredPatients.length.toLocaleString('en-US')} patients`}
            </div>
            <div className="patient-selector-options" id="patient-plan-options" role="listbox">
              {filteredPatients.length ? filteredPatients.map((patient) => {
                const isSelected = patient.id === patientId;
                return (
                  <button
                    aria-selected={isSelected}
                    className={`patient-selector-option${isSelected ? ' selected' : ''}`}
                    key={patient.id}
                    onClick={() => selectPatient(patient.id)}
                    role="option"
                    type="button"
                  >
                    <span aria-hidden="true" className="patient-selector-avatar">
                      {patient.name.trim().charAt(0).toLocaleUpperCase() || 'P'}
                    </span>
                    <span className="patient-selector-option-copy">
                      <strong>{patient.name}</strong>
                      <small>{patient.caseCode}</small>
                    </span>
                    {isSelected ? <Icon className="patient-selector-check" name="check" size={18} /> : null}
                  </button>
                );
              }) : (
                <p className="patient-selector-empty">
                  {th ? 'ไม่พบผู้ป่วยที่ตรงกับคำค้นหา' : 'No patients match your search'}
                </p>
              )}
            </div>
          </div>
        ) : null}
      </div>
      <span className={`patient-plan-status${selectedPatient ? ' ready' : ''}`} role="status">
        {selectedPatient
          ? (th ? `พร้อมส่งให้ ${selectedPatient.name}` : `Ready for ${selectedPatient.name}`)
          : (th ? 'ยังไม่ได้เลือกผู้ป่วย' : 'No patient selected')}
      </span>
    </section>
  );
}
