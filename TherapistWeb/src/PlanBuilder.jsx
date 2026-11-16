'use client';

import { useCallback, useEffect, useMemo, useRef, useState, useTransition } from 'react';
import DosageCard from './components/DosageCard.jsx';
import ExercisePicker from './components/ExercisePicker.jsx';
import NotesCard from './components/NotesCard.jsx';
import PatientPlanSelector from './components/PatientPlanSelector.jsx';
import ScheduleCard from './components/ScheduleCard.jsx';
import SummaryCard from './components/SummaryCard.jsx';
import Topbar from './components/Topbar.jsx';
import { makeDefaultPlan, makePlanItem } from './data.js';

const EMPTY_PATIENTS = Object.freeze([]);
const EMPTY_PLANS = Object.freeze({});
const EMPTY_EXERCISES = Object.freeze([]);

export default function PlanBuilder({ exercises = EMPTY_EXERCISES, initialDate, initialPatients = EMPTY_PATIENTS, initialPlans = EMPTY_PLANS, therapist, onSignOut, onSavePlan }) {
  const [lang, setLang] = useState('th');
  const patients = initialPatients;
  const [patientId, setPatientId] = useState('');
  const [plan, setPlan] = useState(() => makeDefaultPlan('', initialDate));
  const [toast, setToast] = useState('');
  const [isSaving, startSaving] = useTransition();
  const toastTimeout = useRef(null);
  const selectedIds = useMemo(() => new Set(plan.items.map((item) => item.exerciseId)), [plan.items]);
  const selectedPatient = patients.find((patient) => patient.id === patientId) ?? null;

  useEffect(() => {
    setPatientId('');
    setPlan(makeDefaultPlan('', initialDate));
  }, [initialDate, initialPatients, initialPlans]);

  useEffect(() => () => window.clearTimeout(toastTimeout.current), []);

  const notify = useCallback((message) => {
    setToast(message);
    window.clearTimeout(toastTimeout.current);
    toastTimeout.current = window.setTimeout(() => setToast(''), 2600);
  }, []);

  const changePatient = (nextPatientId) => {
    setPatientId(nextPatientId);
    setPlan(initialPlans[nextPatientId] ?? makeDefaultPlan(nextPatientId, initialDate));
  };

  const toggleExercise = (exerciseId) => {
    setPlan((current) => {
      if (current.items.some((item) => item.exerciseId === exerciseId)) {
        return { ...current, items: current.items.filter((item) => item.exerciseId !== exerciseId), updatedAt: null };
      }
      const exercise = exercises.find(({ id }) => id === exerciseId);
      return exercise ? { ...current, items: [...current.items, makePlanItem(exercise)], updatedAt: null } : current;
    });
  };

  const updateItem = (exerciseId, patch) => {
    setPlan((current) => ({
      ...current,
      updatedAt: null,
      items: current.items.map((item) => item.exerciseId === exerciseId ? { ...item, ...patch } : item),
    }));
  };

  const patchPlan = (patch) => setPlan((current) => ({ ...current, ...patch, updatedAt: null }));

  const persistPlan = () => {
    if (!selectedPatient) {
      notify(lang === 'th' ? 'ยังไม่มีผู้ป่วยที่เชื่อมกับบัญชีนี้' : 'No patient is assigned to this account');
      return;
    }
    startSaving(async () => {
      const result = await onSavePlan(plan);
      if (result?.error) {
        notify(result.error);
        return;
      }
      setPlan((current) => ({ ...current, updatedAt: result.updatedAt }));
      notify(lang === 'th' ? `ส่งแผนให้ ${selectedPatient.name} บน iPhone แล้ว` : `Plan sent to ${selectedPatient.name} on iPhone`);
    });
  };

  return (
    <div className="app-shell" lang={lang}>
      <Topbar
        lang={lang}
        onToggleLanguage={() => setLang((current) => current === 'th' ? 'en' : 'th')}
        onSignOut={onSignOut}
        therapist={therapist}
      />
      {patients.length ? (
        <main className="builder-page">
          <PatientPlanSelector
            lang={lang}
            onChange={changePatient}
            patientId={patientId}
            patients={patients}
          />
          {selectedPatient ? (
            <div className="plan-layout">
              <div className="main-column">
                <ExercisePicker exercises={exercises} lang={lang} onToggle={toggleExercise} selectedIds={selectedIds} />
                <DosageCard exercises={exercises} lang={lang} items={plan.items} onRemove={toggleExercise} onUpdate={updateItem} />
              </div>
              <aside className="side-column">
                <ScheduleCard lang={lang} onPatch={patchPlan} plan={plan} />
                <NotesCard lang={lang} notes={plan.notes} onChange={(notes) => patchPlan({ notes })} />
                <SummaryCard isSaving={isSaving} lang={lang} onSave={persistPlan} patient={selectedPatient} plan={plan} />
              </aside>
            </div>
          ) : (
            <section className="patient-selection-required" role="status">
              <span aria-hidden="true">↑</span>
              <h1>{lang === 'th' ? 'เลือก Patient ที่จะรับแผนก่อน' : 'Select the Patient who will receive this plan'}</h1>
              <p>
                {lang === 'th'
                  ? 'ระบบจะยังไม่เปิดแบบฟอร์ม เพื่อป้องกันการสร้างหรือส่งแผนให้ผิดบัญชี'
                  : 'The plan form stays locked to prevent creating or sending a plan to the wrong account.'}
              </p>
            </section>
          )}
        </main>
      ) : (
        <main className="empty-assignment" role="status">
          <IconLink />
          <h1>{lang === 'th' ? 'ยังไม่มีผู้ป่วยที่เชื่อมกับบัญชีนี้' : 'No patients are assigned to this account'}</h1>
          <p>
            {lang === 'th'
              ? 'ผู้ดูแลระบบต้องเชื่อม Patient กับ Therapist ก่อน จึงจะสร้างแผนการรักษาได้'
              : 'An administrator must connect a patient to this therapist before a plan can be created.'}
          </p>
        </main>
      )}
      {toast ? <div className="toast" role="status">{toast}</div> : null}
    </div>
  );
}

function IconLink() {
  return <span aria-hidden="true" className="empty-assignment-icon">↔</span>;
}
