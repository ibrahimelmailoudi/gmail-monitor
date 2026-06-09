import pg from 'pg'
import { config } from './config.js'

const { Pool } = pg

if (!config.databaseUrl) {
  console.warn('[db] DATABASE_URL missing in .env')
}

// Standard Postgres connection. Same code works on Supabase (use its connection
// string) and on your own server later â€” just change DATABASE_URL.
export const pool = new Pool({
  connectionString: config.databaseUrl,
  ssl: config.databaseSsl ? { rejectUnauthorized: false } : false,
})

export const q = (text, params) => pool.query(text, params)
