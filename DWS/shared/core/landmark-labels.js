export const LANDMARK_LABELS = Object.freeze({
  nose: { en: 'Nose', th: 'จมูก' },
  left_shoulder: { en: 'Left shoulder', th: 'ไหล่ซ้าย' },
  right_shoulder: { en: 'Right shoulder', th: 'ไหล่ขวา' },
  left_elbow: { en: 'Left elbow', th: 'ศอกซ้าย' },
  right_elbow: { en: 'Right elbow', th: 'ศอกขวา' },
  left_wrist: { en: 'Left wrist', th: 'ข้อมือซ้าย' },
  right_wrist: { en: 'Right wrist', th: 'ข้อมือขวา' },
  left_hip: { en: 'Left hip', th: 'สะโพกซ้าย' },
  right_hip: { en: 'Right hip', th: 'สะโพกขวา' },
  left_knee: { en: 'Left knee', th: 'เข่าซ้าย' },
  right_knee: { en: 'Right knee', th: 'เข่าขวา' },
  left_ankle: { en: 'Left ankle', th: 'ข้อเท้าซ้าย' },
  right_ankle: { en: 'Right ankle', th: 'ข้อเท้าขวา' },
  left_foot_index: { en: 'Left foot', th: 'ปลายเท้าซ้าย' },
  right_foot_index: { en: 'Right foot', th: 'ปลายเท้าขวา' },
});

function humanizeLandmarkName(name = '') {
  return String(name).replaceAll('_', ' ');
}

export function landmarkLabel(name, lang = 'en') {
  const label = LANDMARK_LABELS[name];
  return label?.[lang] || label?.en || humanizeLandmarkName(name);
}

export function landmarkListLabel(names = [], lang = 'en') {
  return [...new Set((names || []).filter(Boolean))]
    .map((name) => landmarkLabel(name, lang))
    .join(lang === 'th' ? ', ' : ', ');
}
