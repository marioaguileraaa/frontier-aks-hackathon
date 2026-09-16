'use strict';

const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const { spawnSync } = require('node:child_process');

const context = 'aks-hack-lab';
const source = 'fabtech-postgresql-0';
const target = 'c09-postgresql-0';

function kubectl(args, input) {
  const result = spawnSync('kubectl', ['--context', context, ...args], {
    input, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    if (process.argv[2] === 'inspect') console.error(result.stderr.trim());
    throw new Error(`kubectl operation failed (exit ${result.status}); no database content printed`);
  }
  return result.stdout;
}

function runDatabase(pod, command) {
  const script = 'set -e\nexport PGPASSWORD="$(cat /opt/bitnami/postgresql/secrets/password)"\n' + command + '\n';
  return kubectl(['exec', '-i', '-n', 'fabtech', pod, '--', 'bash'], script);
}

function query(pod, sql) {
  const delimiter = 'C09_' + randomUUID().replaceAll('-', '');
  return runDatabase(pod, `psql -h 127.0.0.1 -U fabtech -d fabtech -X -A -t -q -v ON_ERROR_STOP=1 <<'${delimiter}'\n${sql}\n${delimiter}`).trim();
}

function snapshot(pod) {
  return JSON.parse(query(pod, `SELECT json_build_object(
    'sessions', (SELECT count(*) FROM sessions),
    'speakers', (SELECT count(*) FROM speakers),
    'sessionsHash', (SELECT encode(sha256(convert_to(coalesce(string_agg(id::text || ':' || data::text, E'\\n' ORDER BY id), ''), 'UTF8')), 'hex') FROM sessions),
    'speakersHash', (SELECT encode(sha256(convert_to(coalesce(string_agg(id::text || ':' || data::text, E'\\n' ORDER BY id), ''), 'UTF8')), 'hex') FROM speakers)
  );`));
}

const action = process.argv[2] || 'inspect';
try {
  if (action === 'inspect') {
    const tables = Number(query(target, "SELECT count(*) FROM pg_tables WHERE schemaname='public';"));
    console.log(JSON.stringify({ source: snapshot(source), targetTables: tables }));
  } else if (action === 'migrate') {
    const api = JSON.parse(kubectl(['get', 'deployment', 'fabtech-api', '-n', 'fabtech', '-o', 'json']));
    assert.equal(api.spec.replicas, 0, 'API must be quiesced during migration');
    assert.equal(Number(query(target, "SELECT count(*) FROM pg_tables WHERE schemaname='public';")), 0, 'Destination is not empty; refusing to overwrite');
    const before = snapshot(source);
    const dump = runDatabase(source, 'pg_dump -h 127.0.0.1 -U fabtech -d fabtech --no-owner --no-acl --format=plain');
    const delimiter = 'C09_' + randomUUID().replaceAll('-', '');
    runDatabase(target, `psql -h 127.0.0.1 -U fabtech -d fabtech -X -q -v ON_ERROR_STOP=1 --single-transaction <<'${delimiter}'\n${dump}\n${delimiter}`);
    const after = snapshot(target);
    assert.deepEqual(after, before, 'Restored database differs from source');
    console.log(JSON.stringify({ migrated: true, data: after, dumpWrittenToDisk: false }));
  } else if (action === 'mark') {
    query(target, "CREATE TABLE IF NOT EXISTS c09_storage_proof (proof_id TEXT PRIMARY KEY, created_at TIMESTAMPTZ NOT NULL DEFAULT now()); INSERT INTO c09_storage_proof (proof_id) VALUES ('challenge09-persistent-disk') ON CONFLICT DO NOTHING;");
    console.log(JSON.stringify({ markerCreated: true, data: snapshot(target) }));
  } else if (action === 'verify') {
    const marker = Number(query(target, "SELECT count(*) FROM c09_storage_proof WHERE proof_id='challenge09-persistent-disk';"));
    assert.equal(marker, 1, 'Persistence marker is missing');
    const pod = JSON.parse(kubectl(['get', 'pod', target, '-n', 'fabtech', '-o', 'json']));
    const pvc = JSON.parse(kubectl(['get', 'pvc', 'data-c09-postgresql-0', '-n', 'fabtech', '-o', 'json']));
    console.log(JSON.stringify({ markerPresent: true, data: snapshot(target), podUid: pod.metadata.uid, pvcUid: pvc.metadata.uid, pv: pvc.spec.volumeName }));
  } else {
    throw new Error('Action must be inspect, migrate, mark or verify');
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}