export function requestedCallMedia(value) {
  if (value === undefined) return 'video'; // Older clients are video-only.
  return value === 'audio' || value === 'video' ? value : null;
}

export function callMediaConstraints(mediaType) {
  return {
    audio: { echoCancellation: true, noiseSuppression: true },
    video: mediaType === 'audio' ? false : { facingMode: 'user', width: { ideal: 1280 }, height: { ideal: 720 } },
  };
}
