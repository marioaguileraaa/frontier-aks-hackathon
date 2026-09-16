'use strict';

const { readFile } = require('node:fs/promises');
const { Pool } = require('pg');
const sessionsData = require('./sessions');
const speakersData = require('./speakers');

let pool = null;

async function init() {
  const connStr = (
    await readFile('/mnt/secrets/db-connection-string', 'utf8')
  ).trim();

  if (!connStr) {
    throw new Error('El archivo de conexion de PostgreSQL esta vacio');
  }

  // Expected format: postgresql://user:password@host:5432/dbname?sslmode=require
  // For Azure Database for PostgreSQL, always include ?sslmode=require
  pool = new Pool({
    connectionString: connStr,
    connectionTimeoutMillis: 5000
  });

  try {
    await pool.query('SELECT 1');
    console.log('Connected to PostgreSQL');
  } catch {
    await pool.end().catch(() => {});
    pool = null;
    throw new Error(
      'No se pudo conectar a PostgreSQL usando el secreto montado'
    );
  }

  await pool.query(`
    CREATE TABLE IF NOT EXISTS sessions (
      id   SERIAL PRIMARY KEY,
      data JSONB  NOT NULL
    );
    CREATE TABLE IF NOT EXISTS speakers (
      id   SERIAL PRIMARY KEY,
      data JSONB  NOT NULL
    );
  `);

  const { rows } = await pool.query('SELECT COUNT(*) FROM sessions');
  if (parseInt(rows[0].count, 10) === 0) {
    console.log('Seeding database...');
    for (const session of sessionsData) {
      await pool.query('INSERT INTO sessions (data) VALUES ($1)', [session]);
    }
    for (const speaker of speakersData) {
      await pool.query('INSERT INTO speakers (data) VALUES ($1)', [speaker]);
    }
    console.log(`Seeded ${sessionsData.length} sessions and ${speakersData.length} speakers`);
  } else {
    console.log('Database already seeded — skipping');
  }

  return true;
}

async function getSessions() {
  const { rows } = await pool.query('SELECT data FROM sessions ORDER BY id');
  return rows.map(r => r.data);
}

async function getSpeakers() {
  const { rows } = await pool.query('SELECT data FROM speakers ORDER BY id');
  return rows.map(r => r.data);
}

function isConnected() {
  return pool !== null;
}

module.exports = { init, getSessions, getSpeakers, isConnected };
