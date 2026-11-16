const INDEX = Object.freeze({
  leftShoulder: 11,
  rightShoulder: 12,
  leftHip: 23,
  rightHip: 24,
  leftAnkle: 27,
  rightAnkle: 28,
});

function coordinate(point, key) {
  if (Array.isArray(point)) return Number(point[key === 'x' ? 0 : key === 'y' ? 1 : 2]) || 0;
  return Number(point?.[key]) || 0;
}

function midpoint(left, right) {
  return {
    x: (coordinate(left, 'x') + coordinate(right, 'x')) / 2,
    y: (coordinate(left, 'y') + coordinate(right, 'y')) / 2,
  };
}

export function dynamicWeightShiftMetrics(landmarks = [], {
  neutralTorsoLeanDeg = 0,
  mirrored = false,
} = {}) {
  if (!Array.isArray(landmarks) || landmarks.length < 29) {
    return {
      valid: false,
      trunkShiftDeg: 0,
      shoulderTiltDeg: 0,
      signedTorsoLeanDeg: 0,
      screenDirection: 'unknown',
      anatomicalDirection: 'unknown',
      jointAngles: { trunk_shift: 0, shoulder_tilt: 0 },
    };
  }
  const leftShoulder = landmarks[INDEX.leftShoulder];
  const rightShoulder = landmarks[INDEX.rightShoulder];
  const shoulder = midpoint(leftShoulder, rightShoulder);
  const hip = midpoint(landmarks[INDEX.leftHip], landmarks[INDEX.rightHip]);
  const ankle = midpoint(landmarks[INDEX.leftAnkle], landmarks[INDEX.rightAnkle]);
  const shoulderTiltDeg = Math.abs(Math.atan2(
    coordinate(rightShoulder, 'y') - coordinate(leftShoulder, 'y'),
    Math.abs(coordinate(rightShoulder, 'x') - coordinate(leftShoulder, 'x')) || 1e-6,
  ) * 180 / Math.PI);
  const torsoLeanDeg = Math.atan2(shoulder.x - hip.x, hip.y - shoulder.y) * 180 / Math.PI;
  const signedTorsoLeanDeg = torsoLeanDeg - Number(neutralTorsoLeanDeg || 0);
  const trunkShiftDeg = Math.abs(signedTorsoLeanDeg);
  const screenDirection = Math.abs(signedTorsoLeanDeg) < 1e-6
    ? 'center'
    : signedTorsoLeanDeg > 0 ? 'screen_right' : 'screen_left';
  const anatomicalDirection = screenDirection === 'center'
    ? 'center'
    : screenDirection === 'screen_right'
      ? mirrored ? 'right' : 'left'
      : mirrored ? 'left' : 'right';
  return {
    valid: true,
    torsoLeanDeg,
    signedTorsoLeanDeg,
    trunkShiftDeg,
    shoulderTiltDeg,
    screenDirection,
    anatomicalDirection,
    shoulderCenterX: shoulder.x,
    hipCenterX: hip.x,
    ankleCenterX: ankle.x,
    shoulderRelativeToHipX: shoulder.x - hip.x,
    hipRelativeToAnklesX: hip.x - ankle.x,
    jointAngles: { trunk_shift: trunkShiftDeg, shoulder_tilt: shoulderTiltDeg },
  };
}
