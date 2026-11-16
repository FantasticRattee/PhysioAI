import { createModelRegistry } from './ModelRegistry.js';

export const DEFAULT_MOTION_TCN_BASE_URL = '/shared/models/motion-tcn';

async function fetchJson(url, fetchImpl = globalThis.fetch) {
  if (typeof fetchImpl !== 'function') return null;
  const res = await fetchImpl(url);
  if (!res?.ok) return null;
  return res.json();
}

export function createMotionTcnModelRegistry({
  baseUrl = DEFAULT_MOTION_TCN_BASE_URL,
  fetchImpl = globalThis.fetch,
  tf = null,
  logger = console,
} = {}) {
  return createModelRegistry({
    loaders: {
      'motion-tcn': async () => {
        const root = String(baseUrl).replace(/\/$/, '');
        const manifest = await fetchJson(`${root}/manifest.json`, fetchImpl);
        if (!manifest?.modelPath) return null;
        const runtime = tf || globalThis.tf;
        const loader = manifest.modelFormat === 'tfjs-graph-model'
          ? runtime?.loadGraphModel
          : runtime?.loadLayersModel;
        if (typeof loader !== 'function') return null;
        const modelUrl = manifest.modelPath.startsWith('http') || manifest.modelPath.startsWith('/')
          ? manifest.modelPath
          : `${root}/${manifest.modelPath.replace(/^\.\//, '')}`;
        const model = await loader.call(runtime, modelUrl);
        model.__physioAiManifest = manifest;
        if (manifest.modelFormat === 'tfjs-graph-model') {
          const phaseOutput = manifest.outputMap?.phase;
          const qualityOutput = manifest.outputMap?.quality;
          const execute = typeof model.execute === 'function'
            ? model.execute.bind(model)
            : typeof model.executeAsync === 'function'
              ? model.executeAsync.bind(model)
              : null;
          if (!phaseOutput || !qualityOutput || !execute) return null;
          model.predictMotion = async ({ vectors = [] } = {}) => {
            const input = runtime.tensor3d([vectors]);
            try {
              return await execute(input, [phaseOutput, qualityOutput]);
            } finally {
              input.dispose?.();
            }
          };
        }
        return model;
      },
    },
    metadata: {
      'motion-tcn': {
        baseUrl,
        optional: true,
        source: 'shared-models',
      },
    },
    logger,
  });
}
