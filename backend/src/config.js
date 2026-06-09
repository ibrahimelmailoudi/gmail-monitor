import 'dotenv/config'

export const config = {
  port: Number(process.env.PORT) || 4000,
  frontendUrl: process.env.FRONTEND_URL || 'http://localhost:5173',
  jwtSecret: process.env.JWT_SECRET || 'dev-secret-change-me',
  accessUsername: process.env.ACCESS_USERNAME || '',
  bootstrapSecret: process.env.BOOTSTRAP_SECRET || '',
  encryptionKey: process.env.ENCRYPTION_KEY || '0'.repeat(64),
  gmailPollMs: Number(process.env.GMAIL_POLL_MS) || 20000,
  databaseUrl: process.env.DATABASE_URL,
  databaseSsl: process.env.DATABASE_SSL !== 'false', // SSL on by default (Supabase); set false for local
  google: {
    clientId: process.env.GOOGLE_CLIENT_ID,
    clientSecret: process.env.GOOGLE_CLIENT_SECRET,
    redirectUri: process.env.GOOGLE_REDIRECT_URI || 'http://localhost:4000/api/auth/google/callback',
  },
}

// Max emails kept per account (matches the frontend cap)
export const MAX_EMAILS = 100
