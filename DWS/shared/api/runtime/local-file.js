import crypto from 'node:crypto';
import { access, mkdir, readFile, readdir, rename, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';

const DEFAULT_DATA_DIR = 'data/local';

const DEFAULT_TABLES = Object.freeze({
  profiles: 'profiles',
  therapistPatients: 'therapist_patients',
  plans: 'plans',
  references: 'references',
  sessions: 'sessions',
  sessionMedia: 'session_media',
  datasets: 'motion_datasets',
  aiModels: 'ai_models',
});

const TABLE_FILES = Object.freeze({
  profiles: 'profiles.json',
  therapist_patients: 'therapist_patients.json',
  plans: 'plans.json',
  references: 'references.json',
  sessions: 'sessions.json',
  session_media: 'session_media.json',
  motion_datasets: 'motion_datasets.json',
  ai_models: 'ai_models.json',
  users: 'users.json',
  tokens: 'tokens.json',
});

const TABLE_KEYS = Object.freeze({
  profiles: ['id'],
  therapist_patients: ['therapist_id', 'patient_id'],
  plans: ['patient_id'],
  references: ['patient_id', 'exercise_id'],
  sessions: ['id'],
  session_media: ['id'],
  motion_datasets: ['id'],
  ai_models: ['therapist_id', 'exercise_id'],
  users: ['id'],
  tokens: ['token'],
});

const EXERCISE_ARTIFACT_DIRS = Object.freeze({
  reference: 'references',
  references: 'references',
  session: 'sessions',
  sessions: 'sessions',
  dataset: 'datasets',
  datasets: 'datasets',
  aiModel: 'models',
  aiModels: 'models',
  model: 'models',
  models: 'models',
});

function resolveDataDir(env = process.env) {
  const configured = env.PHYSIOAI_DATA_DIR || DEFAULT_DATA_DIR;
  if (path.isAbsolute(configured)) return configured;
  const scoped = configured.replace(/^data[\\/]/, '') || 'local';
  return path.join(process.cwd(), 'data', scoped);
}

function nowIso() {
  return new Date().toISOString();
}

function clone(value) {
  return value == null ? value : JSON.parse(JSON.stringify(value));
}

function safePathSegment(value, fallback = 'item') {
  const text = String(value || '')
    .normalize('NFKC')
    .trim()
    .toLowerCase()
    .replace(/[^\p{Letter}\p{Number}._-]+/gu, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 90);
  return text || fallback;
}

function exerciseFolderName(exercise = {}) {
  const id = safePathSegment(exercise.id, 'exercise');
  const label = safePathSegment(exercise.label || exercise.labelTh || exercise.title || id, 'exercise');
  return `${label}__${id}`;
}

function artifactFileName(kind, payload = {}) {
  if (payload.id) return `${safePathSegment(payload.id)}.json`;
  if (kind === 'references') {
    const patientId = payload.patientId || payload.patient_id || 'local';
    const exerciseId = payload.exerciseId || payload.exercise_id || 'exercise';
    return `${safePathSegment(patientId)}__${safePathSegment(exerciseId)}.json`;
  }
  if (kind === 'models') {
    const exerciseId = payload.exerciseId || payload.exercise_id || 'exercise';
    const version = payload.version || payload.modelVersion || 'model';
    return `${safePathSegment(exerciseId)}__${safePathSegment(version)}.json`;
  }
  return `${safePathSegment(Date.now())}.json`;
}

function datasetSummary(payload = {}) {
  const { frames, ...summary } = clone(payload) || {};
  return {
    ...summary,
    frameCount: Array.isArray(frames)
      ? frames.length
      : Math.max(0, Number(payload.frameCount) || 0),
  };
}

function parseDatasetJsonl(text = '') {
  return String(text || '')
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

function normalizeEmail(email) {
  return String(email || '').trim().toLowerCase();
}

function safeName(value) {
  return String(value || '').trim() || 'User';
}

function passwordHash(password, salt) {
  return crypto
    .createHash('sha256')
    .update(`${salt}:${password}`)
    .digest('hex');
}

function publicAuthUser(user = {}) {
  return {
    id: user.id,
    email: user.email,
    user_metadata: user.user_metadata || {},
  };
}

function keyFieldsFor(table, options = {}) {
  const explicit = String(options.onConflict || '')
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
  return explicit.length ? explicit : (TABLE_KEYS[table] || ['id']);
}

function sameKey(a = {}, b = {}, fields = []) {
  return fields.every((field) => a[field] === b[field]);
}

function applyProjection(row, selectText) {
  if (!row || !selectText || selectText === '*') return row;
  const fields = String(selectText)
    .split(',')
    .map((field) => field.trim())
    .filter(Boolean);
  if (!fields.length) return row;
  const out = {};
  for (const field of fields) {
    const key = field.split(/\s+/)[0];
    if (key in row) out[key] = row[key];
  }
  return out;
}

function matchesFilters(row = {}, filters = []) {
  return filters.every((filter) => {
    if (filter.type === 'eq') return row[filter.column] === filter.value;
    if (filter.type === 'in') return filter.values.includes(row[filter.column]);
    return true;
  });
}

export class LocalFileStore {
  constructor({ root = resolveDataDir() } = {}) {
    this.root = root;
    this.writeLocks = new Map();
    this.seeded = false;
  }

  fileFor(table) {
    return path.join(this.root, TABLE_FILES[table] || `${table}.json`);
  }

  exercisesRoot() {
    return path.join(this.root, 'exercises');
  }

  async ensureExerciseRoot() {
    await this.ensureRoot();
    await mkdir(this.exercisesRoot(), { recursive: true });
  }

  async ensureExerciseSubdirs(dir) {
    await mkdir(dir, { recursive: true });
    await Promise.all(
      [...new Set(Object.values(EXERCISE_ARTIFACT_DIRS))]
        .map((child) => mkdir(path.join(dir, child), { recursive: true })),
    );
  }

  async exerciseDirs() {
    await this.ensureExerciseRoot();
    try {
      const entries = await readdir(this.exercisesRoot(), { withFileTypes: true });
      return entries
        .filter((entry) => entry.isDirectory())
        .map((entry) => path.join(this.exercisesRoot(), entry.name));
    } catch (error) {
      if (error.code === 'ENOENT') return [];
      throw error;
    }
  }

  async findExerciseDir(id) {
    const safeId = safePathSegment(id, '');
    if (!safeId) return null;
    const suffix = `__${safeId}`;
    for (const dir of await this.exerciseDirs()) {
      if (path.basename(dir).endsWith(suffix)) return dir;
      try {
        const doc = JSON.parse(await readFile(path.join(dir, 'exercise.json'), 'utf8'));
        if (doc?.id === id) return dir;
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      }
    }
    return null;
  }

  async exerciseDirFor(exercise = {}) {
    await this.ensureExerciseRoot();
    const desired = path.join(this.exercisesRoot(), exerciseFolderName(exercise));
    const existing = exercise.id ? await this.findExerciseDir(exercise.id) : null;
    if (!existing || existing === desired) return existing || desired;
    try {
      await rename(existing, desired);
      return desired;
    } catch (error) {
      if (error.code === 'EEXIST') return existing;
      throw error;
    }
  }

  async ensureRoot() {
    await mkdir(this.root, { recursive: true });
    await this.seedDefaults();
  }

  async seedDefaults() {
    if (this.seeded) return;
    this.seeded = true;
    const defaults = {
      profiles: [
        { id: 'local_therapist', name: 'Local Therapist', email: 'therapist@local', role: 'therapist' },
        { id: 'local_patient', name: 'Local Patient', email: 'patient@local', role: 'patient' },
      ],
      therapist_patients: [
        { therapist_id: 'local_therapist', patient_id: 'local_patient', linked_at: nowIso() },
      ],
      plans: [],
      references: [],
      sessions: [],
      session_media: [],
      motion_datasets: [],
      ai_models: [],
      users: [],
      tokens: [],
    };
    for (const [table, rows] of Object.entries(defaults)) {
      try {
        await access(this.fileFor(table));
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
        await writeFile(this.fileFor(table), `${JSON.stringify(rows, null, 2)}\n`);
      }
    }
  }

  async readTable(table) {
    await this.ensureRoot();
    try {
      const text = await readFile(this.fileFor(table), 'utf8');
      const parsed = JSON.parse(text);
      return Array.isArray(parsed) ? parsed : [];
    } catch (error) {
      if (error.code === 'ENOENT') return [];
      throw error;
    }
  }

  async writeTable(table, rows) {
    await this.ensureRoot();
    const spacing = table === 'motion_datasets' ? 0 : 2;
    await writeFile(this.fileFor(table), `${JSON.stringify(rows, null, spacing)}\n`);
  }

  async listExercises() {
    const rows = [];
    for (const dir of await this.exerciseDirs()) {
      try {
        const text = await readFile(path.join(dir, 'exercise.json'), 'utf8');
        const parsed = JSON.parse(text);
        if (parsed?.id) rows.push(parsed);
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      }
    }
    return rows.sort((a, b) => {
      const at = Date.parse(a.updatedAt || a.createdAt || '') || 0;
      const bt = Date.parse(b.updatedAt || b.createdAt || '') || 0;
      if (at !== bt) return at - bt;
      return String(a.label || a.id).localeCompare(String(b.label || b.id));
    }).map(clone);
  }

  async upsertExercise(exercise = {}) {
    const now = nowIso();
    const doc = {
      ...clone(exercise),
      source: 'custom',
      createdAt: exercise.createdAt || now,
      updatedAt: now,
    };
    const dir = await this.exerciseDirFor(doc);
    await this.ensureExerciseSubdirs(dir);
    await writeFile(path.join(dir, 'exercise.json'), `${JSON.stringify(doc, null, 2)}\n`);
    return clone(doc);
  }

  async deleteExercise(id) {
    const dir = await this.findExerciseDir(id);
    if (dir) await rm(dir, { recursive: true, force: true });
    return true;
  }

  async ensureExerciseFolderForArtifact(payload = {}) {
    const exerciseId = payload.exerciseId || payload.exercise_id || payload.exercise?.id;
    if (!exerciseId) return null;
    const existing = await this.findExerciseDir(exerciseId);
    const dir = existing || path.join(this.exercisesRoot(), exerciseFolderName({
      id: exerciseId,
      label: payload.exerciseLabel || payload.label || exerciseId,
    }));
    await this.ensureExerciseSubdirs(dir);
    return dir;
  }

  async writeExerciseArtifact(kind, payload = {}) {
    const folder = EXERCISE_ARTIFACT_DIRS[kind] || EXERCISE_ARTIFACT_DIRS[`${kind}s`];
    if (!folder) return null;
    if (folder === 'datasets') return this.writeDatasetArtifact(payload);
    const dir = await this.ensureExerciseFolderForArtifact(payload);
    if (!dir) return null;
    const artifactDir = path.join(dir, folder);
    await mkdir(artifactDir, { recursive: true });
    const file = path.join(artifactDir, artifactFileName(folder, payload));
    await writeFile(file, `${JSON.stringify(clone(payload), null, 2)}\n`);
    return file;
  }

  async datasetArtifactDir(exercise) {
    const payload = exercise && typeof exercise === 'object'
      ? exercise
      : { exerciseId: exercise };
    const dir = await this.ensureExerciseFolderForArtifact(payload);
    if (!dir) return null;
    const artifactDir = path.join(dir, 'datasets');
    await mkdir(artifactDir, { recursive: true });
    return artifactDir;
  }

  async readDatasetIndex(exerciseId) {
    const artifactDir = await this.datasetArtifactDir(exerciseId);
    if (!artifactDir) return null;
    try {
      const parsed = JSON.parse(await readFile(path.join(artifactDir, 'index.json'), 'utf8'));
      return Array.isArray(parsed) ? parsed : [];
    } catch (error) {
      if (error.code === 'ENOENT') return null;
      throw error;
    }
  }

  async writeDatasetIndex(exerciseId, rows = []) {
    const artifactDir = await this.datasetArtifactDir(exerciseId);
    if (!artifactDir) return null;
    const file = path.join(artifactDir, 'index.json');
    await writeFile(file, `${JSON.stringify(rows.map(datasetSummary), null, 2)}\n`);
    return file;
  }

  async readCanonicalDataset(exerciseId) {
    const exerciseDir = await this.findExerciseDir(exerciseId);
    if (!exerciseDir) return [];
    try {
      return parseDatasetJsonl(await readFile(path.join(exerciseDir, 'dataset.jsonl'), 'utf8'));
    } catch (error) {
      if (error.code === 'ENOENT') return [];
      throw error;
    }
  }

  async listDatasetArtifacts({ exerciseId, datasetId = null, summary = false } = {}) {
    const id = String(exerciseId || '').trim();
    if (!id) return null;
    const artifactDir = await this.datasetArtifactDir(id);
    if (!artifactDir) return [];
    const canonicalRows = await this.readCanonicalDataset(id);
    if (datasetId) {
      try {
        const parsed = JSON.parse(await readFile(
          path.join(artifactDir, `${safePathSegment(datasetId)}.json`),
          'utf8',
        ));
        return parsed ? [clone(parsed)] : [];
      } catch (error) {
        if (error.code === 'ENOENT') {
          const canonical = canonicalRows.find((row) => row?.id === datasetId);
          return canonical ? [clone(canonical)] : null;
        }
        throw error;
      }
    }
    if (summary) {
      const index = await this.readDatasetIndex(id);
      if (index == null && canonicalRows.length === 0) return null;
      const merged = new Map(canonicalRows.map((row) => [row?.id, datasetSummary(row)]));
      for (const row of index || []) merged.set(row?.id, datasetSummary(row));
      return [...merged.values()].map(clone);
    }
    let entries;
    try {
      entries = await readdir(artifactDir, { withFileTypes: true });
    } catch (error) {
      if (error.code === 'ENOENT') return [];
      throw error;
    }
    const rows = [];
    for (const entry of entries) {
      if (!entry.isFile() || entry.name === 'index.json' || !entry.name.endsWith('.json')) continue;
      rows.push(JSON.parse(await readFile(path.join(artifactDir, entry.name), 'utf8')));
    }
    const merged = new Map(canonicalRows.map((row) => [row?.id, row]));
    for (const row of rows) merged.set(row?.id, row);
    return [...merged.values()].map(clone);
  }

  async writeDatasetArtifact(payload = {}) {
    const exerciseId = payload.exerciseId || payload.exercise_id;
    if (!exerciseId || !payload.id) return null;
    const artifactDir = await this.datasetArtifactDir(payload);
    const file = path.join(artifactDir, `${safePathSegment(payload.id)}.json`);
    await writeFile(file, `${JSON.stringify(clone(payload), null, 2)}\n`);

    const lockKey = `dataset-index:${exerciseId}`;
    const previous = this.writeLocks.get(lockKey) || Promise.resolve();
    const next = previous.then(async () => {
      const current = await this.readDatasetIndex(exerciseId) || [];
      const summary = datasetSummary(payload);
      const index = current.findIndex((row) => row?.id === payload.id);
      if (index === -1) current.push(summary);
      else current[index] = summary;
      await this.writeDatasetIndex(exerciseId, current);
    });
    this.writeLocks.set(lockKey, next.catch(() => {}));
    await next;
    return file;
  }

  async upsertDatasetArtifact(payload = {}) {
    await this.writeDatasetArtifact(payload);
    return clone(payload);
  }

  async rebuildDatasetArtifacts(rows = []) {
    const grouped = new Map();
    for (const row of Array.isArray(rows) ? rows : []) {
      const exerciseId = row?.exerciseId || row?.exercise_id;
      if (!exerciseId || !row?.id) continue;
      if (!grouped.has(exerciseId)) grouped.set(exerciseId, []);
      grouped.get(exerciseId).push(row);
    }
    const counts = {};
    for (const [exerciseId, exerciseRows] of grouped) {
      const artifactDir = await this.datasetArtifactDir(exerciseRows[0] || exerciseId);
      for (const row of exerciseRows) {
        await writeFile(
          path.join(artifactDir, `${safePathSegment(row.id)}.json`),
          `${JSON.stringify(clone(row), null, 2)}\n`,
        );
      }
      await this.writeDatasetIndex(exerciseId, exerciseRows);
      counts[exerciseId] = exerciseRows.length;
    }
    return counts;
  }

  async mutateTable(table, updater) {
    const previous = this.writeLocks.get(table) || Promise.resolve();
    const next = previous.then(async () => {
      const rows = await this.readTable(table);
      const updated = await updater(rows);
      await this.writeTable(table, updated.rows || rows);
      return updated.result;
    });
    this.writeLocks.set(table, next.catch(() => {}));
    return next;
  }

  async createUser({ email, password, name, role = 'patient', emailConfirm = true } = {}) {
    const normalizedEmail = normalizeEmail(email);
    if (!normalizedEmail || !password) {
      return { data: { user: null }, error: new Error('Missing email or password') };
    }
    const result = await this.mutateTable('users', async (users) => {
      if (users.some((user) => user.email === normalizedEmail)) {
        return { rows: users, result: { data: { user: null }, error: new Error('User already registered') } };
      }
      const salt = crypto.randomBytes(12).toString('hex');
      const user = {
        id: `local_${crypto.randomUUID()}`,
        email: normalizedEmail,
        passwordHash: passwordHash(password, salt),
        salt,
        email_confirmed_at: emailConfirm ? nowIso() : null,
        user_metadata: { name: safeName(name) },
        created_at: nowIso(),
      };
      return {
        rows: [...users, user],
        result: { data: { user: publicAuthUser(user) }, error: null },
      };
    });
    if (!result.error && result.data?.user?.id) {
      await this.upsertRows('profiles', [{
        id: result.data.user.id,
        name: safeName(name),
        email: normalizedEmail,
        role,
      }], { onConflict: 'id' });
    }
    return result;
  }

  async signInWithPassword({ email, password } = {}) {
    const normalizedEmail = normalizeEmail(email);
    const users = await this.readTable('users');
    const user = users.find((item) => item.email === normalizedEmail);
    if (!user || user.passwordHash !== passwordHash(password || '', user.salt)) {
      return { data: { user: null, session: null }, error: new Error('Invalid login credentials') };
    }
    const token = `local_${crypto.randomUUID()}`;
    await this.upsertRows('tokens', [{
      token,
      user_id: user.id,
      created_at: nowIso(),
    }], { onConflict: 'token' });
    return {
      data: {
        user: publicAuthUser(user),
        session: { access_token: token },
      },
      error: null,
    };
  }

  async getUser(token) {
    const tokens = await this.readTable('tokens');
    const row = tokens.find((item) => item.token === token);
    if (!row) return { data: { user: null }, error: new Error('Invalid token') };
    const users = await this.readTable('users');
    const user = users.find((item) => item.id === row.user_id);
    if (!user) return { data: { user: null }, error: new Error('Invalid token') };
    return { data: { user: publicAuthUser(user) }, error: null };
  }

  async upsertRows(table, payload, options = {}) {
    const list = Array.isArray(payload) ? payload : [payload];
    const fields = keyFieldsFor(table, options);
    return this.mutateTable(table, async (rows) => {
      const next = [...rows];
      for (const row of list) {
        const index = next.findIndex((existing) => sameKey(existing, row, fields));
        if (index === -1) next.push(clone(row));
        else next[index] = { ...next[index], ...clone(row) };
      }
      return {
        rows: next,
        result: { data: clone(Array.isArray(payload) ? list : list[0]), error: null },
      };
    });
  }

  async insertRows(table, payload) {
    const list = Array.isArray(payload) ? payload : [payload];
    return this.mutateTable(table, async (rows) => ({
      rows: [...rows, ...list.map(clone)],
      result: { data: clone(Array.isArray(payload) ? list : list[0]), error: null },
    }));
  }

  async deleteRows(table, filters) {
    return this.mutateTable(table, async (rows) => ({
      rows: rows.filter((row) => !matchesFilters(row, filters)),
      result: { data: null, error: null },
    }));
  }
}

class LocalQueryBuilder {
  constructor(store, table) {
    this.store = store;
    this.table = table;
    this.filters = [];
    this.orderBy = null;
    this.limitCount = null;
    this.selectText = '*';
    this.op = 'select';
    this.payload = null;
    this.options = {};
  }

  select(text = '*') {
    this.selectText = text || '*';
    return this;
  }

  eq(column, value) {
    this.filters.push({ type: 'eq', column, value });
    return this;
  }

  in(column, values = []) {
    this.filters.push({ type: 'in', column, values: Array.isArray(values) ? values : [] });
    return this;
  }

  order(column, options = {}) {
    this.orderBy = { column, ascending: options.ascending !== false };
    return this;
  }

  limit(value) {
    this.limitCount = Number(value) || null;
    return this;
  }

  upsert(payload, options = {}) {
    this.op = 'upsert';
    this.payload = payload;
    this.options = options;
    return this;
  }

  insert(payload) {
    this.op = 'insert';
    this.payload = payload;
    return this;
  }

  delete() {
    this.op = 'delete';
    return this;
  }

  async rows() {
    const rows = await this.store.readTable(this.table);
    let next = rows.filter((row) => matchesFilters(row, this.filters));
    if (this.orderBy) {
      const { column, ascending } = this.orderBy;
      next = next.slice().sort((a, b) => {
        const av = a[column] ?? '';
        const bv = b[column] ?? '';
        if (av === bv) return 0;
        return (av > bv ? 1 : -1) * (ascending ? 1 : -1);
      });
    }
    if (this.limitCount != null) next = next.slice(0, this.limitCount);
    return next.map((row) => applyProjection(clone(row), this.selectText));
  }

  async execute() {
    if (this.op === 'upsert') return this.store.upsertRows(this.table, this.payload, this.options);
    if (this.op === 'insert') return this.store.insertRows(this.table, this.payload);
    if (this.op === 'delete') return this.store.deleteRows(this.table, this.filters);
    return { data: await this.rows(), error: null };
  }

  async maybeSingle() {
    const result = await this.execute();
    if (result.error) return result;
    const data = Array.isArray(result.data) ? (result.data[0] || null) : result.data;
    return { data, error: null };
  }

  async single() {
    const result = await this.execute();
    if (result.error) return result;
    const data = Array.isArray(result.data) ? result.data[0] : result.data;
    return { data: data || null, error: null };
  }

  then(resolve, reject) {
    return this.execute().then(resolve, reject);
  }
}

export function createLocalFileClient(store) {
  return {
    auth: {
      signUp: async ({ email, password, options } = {}) => {
        const created = await store.createUser({
          email,
          password,
          name: options?.data?.name,
          role: options?.data?.role || 'patient',
          emailConfirm: true,
        });
        if (created.error) return { data: { user: null, session: null }, error: created.error };
        const login = await store.signInWithPassword({ email, password });
        return login;
      },
      signInWithPassword: (payload) => store.signInWithPassword(payload),
      getUser: (token) => store.getUser(token),
      resend: async () => ({ data: {}, error: null }),
      admin: {
        createUser: ({ email, password, email_confirm: emailConfirm = true, user_metadata: meta = {} } = {}) =>
          store.createUser({ email, password, name: meta.name, role: meta.role || 'patient', emailConfirm }),
      },
    },
    from(table) {
      return new LocalQueryBuilder(store, table);
    },
  };
}

export function localFileRuntimeConfig(env = process.env) {
  return {
    root: resolveDataDir(env),
    tables: DEFAULT_TABLES,
  };
}

export function createLocalFileRuntime({ env = process.env, store = null } = {}) {
  const config = localFileRuntimeConfig(env);
  const fileStore = store || new LocalFileStore({ root: config.root });
  return {
    storageMode: 'file',
    storageRoot: config.root,
    TABLES: config.tables,
    exerciseStore: {
      list: () => fileStore.listExercises(),
      upsert: (exercise) => fileStore.upsertExercise(exercise),
      delete: (id) => fileStore.deleteExercise(id),
      writeArtifact: (kind, payload) => fileStore.writeExerciseArtifact(kind, payload),
      listDatasets: (options) => fileStore.listDatasetArtifacts(options),
      upsertDataset: (payload) => fileStore.upsertDatasetArtifact(payload),
    },
    storageReady: () => true,
    dataClient: () => createLocalFileClient(fileStore),
  };
}

export default {
  LocalFileStore,
  createLocalFileClient,
  createLocalFileRuntime,
  localFileRuntimeConfig,
};
