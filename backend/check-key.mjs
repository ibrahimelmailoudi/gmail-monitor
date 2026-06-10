// check-key.mjs - validates your ENCRYPTION_KEY
// Run from E:\gmail-monitor\backend  with:  node check-key.mjs
import 'dotenv/config'
const k = process.env.ENCRYPTION_KEY || ''
const hexOnly = /^[0-9a-fA-F]+$/.test(k)
console.log('length:', k.length, '(need exactly 64)')
console.log('valid hex chars only (0-9 a-f):', hexOnly)
console.log('VERDICT:', (k.length === 64 && hexOnly) ? 'VALID - good' : 'INVALID - fix ENCRYPTION_KEY in .env')
if (k.length !== 64 || !hexOnly) {
  console.log('\nGenerate a valid one in PowerShell:')
  console.log("  -join ((1..64) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })")
}
