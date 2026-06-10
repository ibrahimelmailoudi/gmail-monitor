# fill-stage40.ps1 - slower/clearer slide-in animation, clickable subject, IP leading-zero strip
# Run from E:\gmail-monitor
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path frontend\src,frontend\src\components\emails | Out-Null

Set-Content -LiteralPath 'frontend\src\index.css' -Encoding utf8 -Value @'
html, body, #root { margin: 0; height: 100%; }
body { background: #f1f5f9; }

/* new-email entrance animation - slow + larger travel so it's clearly visible
   sliding in from the left, one after another (staggered by index in EmailCard). */
@keyframes emailIn {
  0%   { opacity: 0; transform: translateX(-60px) scale(0.9); }
  50%  { opacity: 1; }
  100% { opacity: 1; transform: none; }
}
.email-in { animation: emailIn 2.2s cubic-bezier(.16,.84,.34,1) both; }

/* pulsing border to mark a brand-new email (expires when 'new' state clears) */
@keyframes newPulse {
  0%   { box-shadow: 0 0 0 0 rgba(37,99,235,0.55); }
  70%  { box-shadow: 0 0 0 6px rgba(37,99,235,0); }
  100% { box-shadow: 0 0 0 0 rgba(37,99,235,0); }
}
.email-new-border { animation: newPulse 2s ease-out infinite; }

/* the little NEW ticket badge sliding down above a new email */
@keyframes ticketDrop {
  from { opacity: 0; transform: translateY(-6px); }
  to   { opacity: 1; transform: none; }
}
.email-new-ticket { animation: ticketDrop 0.4s ease-out both; }

/* pulsing green dot for the 'listening for new mail' state */
@keyframes livePulse {
  0%   { box-shadow: 0 0 0 0 rgba(34,197,94,0.6); }
  70%  { box-shadow: 0 0 0 7px rgba(34,197,94,0); }
  100% { box-shadow: 0 0 0 0 rgba(34,197,94,0); }
}
'@
Write-Host 'wrote frontend\src\index.css'

Set-Content -LiteralPath 'frontend\src\components\emails\EmailCard.jsx' -Encoding utf8 -Value @'
import { formatDistanceToNowStrict } from 'date-fns'
import { CATEGORIES } from '../../config'

const timeAgo = (ts) => {
  try { return formatDistanceToNowStrict(new Date(ts), { addSuffix: true }) }
  catch { return 'recently' }
}

// Remove leading zeros from each IPv4 octet: 024.11.27.02 -> 24.11.27.2
const cleanIp = (ip) => {
  if (!ip) return ip
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(ip)) {
    return ip.split('.').map(o => String(parseInt(o, 10))).join('.')
  }
  return ip // leave IPv6 / other formats untouched
}

// ASCII-safe status mark (avoids encoding issues): PASS / FAIL / n/a
function AuthChip({ label, value }) {
  const v = (value || '').toLowerCase()
  const pass = v === 'pass'
  const fail = ['fail', 'softfail', 'permerror', 'temperror', 'none'].includes(v) && v !== ''
  const bg = pass ? '#16a34a' : (v && fail ? '#dc2626' : '#94a3b8')
  const txt = pass ? 'PASS' : (v ? v.toUpperCase() : 'n/a')
  return (
    <span style={{ background: bg, color: '#fff', fontSize: 10, fontWeight: 700,
      padding: '2px 6px', borderRadius: 5, whiteSpace: 'nowrap' }}>{label} {txt}</span>
  )
}

// onFilter(text): clicking the from-name or domain sets the account filter
export default function EmailCard({ email, isNew, onFilter, onPlacementClick, index = 0 }) {
  const cat = CATEGORIES[email.category] || CATEGORIES.other
  const auth = email.auth || {}
  const fromName = email.sender.name || email.sender.email || 'Unknown'

  const clickable = (text) => ({
    cursor: onFilter ? 'pointer' : 'default',
    textDecoration: onFilter ? 'underline' : 'none',
  })

  return (
    <div style={{ position: 'relative', display: 'flex', flexDirection: 'column' }}>
      {/* NEW ticket - top-right corner, inside the card so overflow doesn't clip it */}
      {isNew && (
        <div className="email-new-ticket" style={{
          position: 'absolute', top: 6, right: 6, zIndex: 3,
          background: '#2563eb', color: '#fff', fontSize: 9, fontWeight: 800,
          letterSpacing: 0.5, padding: '2px 7px', borderRadius: 4,
          boxShadow: '0 2px 6px rgba(37,99,235,0.45)' }}>
          NEW
        </div>
      )}

      <div className={isNew ? 'email-in email-new-border' : ''} style={{
        background: cat.bg,
        border: isNew ? '2px solid #2563eb' : `1px solid ${cat.border}`,
        borderRadius: 10, padding: 12,
        width: 230, minWidth: 230, height: 230, boxSizing: 'border-box',
        display: 'flex', flexDirection: 'column', color: '#0f172a',
        animationDelay: isNew ? `${Math.min(index, 10) * 0.35}s` : undefined,
      }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 6 }}>
          <span onClick={() => onPlacementClick && onPlacementClick(email.category)}
            title={onPlacementClick ? 'Filter by placement' : ''}
            style={{ background: cat.color, color: '#fff', fontSize: 11, fontWeight: 700,
            padding: '2px 8px', borderRadius: 6, cursor: onPlacementClick ? 'pointer' : 'default' }}>{cat.name}</span>
          <span style={{ fontSize: 10, color: '#475569', marginRight: isNew ? 36 : 0 }}>{timeAgo(email.time)}</span>
        </div>

      {/* From name (clickable to filter) */}
      <div
        title={onFilter ? 'Filter by sender' : ''}
        onClick={() => onFilter && onFilter(fromName)}
        style={{ fontWeight: 700, fontSize: 13, ...clickable(),
          whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
        {fromName}
      </div>

      {/* Subject (clickable to filter) + little body preview */}
      <div style={{ fontSize: 12, color: '#334155', margin: '6px 0', flex: 1, overflow: 'hidden' }}>
        <div
          title={onFilter ? 'Filter by subject' : ''}
          onClick={() => onFilter && onFilter(email.sender.subject)}
          style={{ fontWeight: 600, ...clickable(),
          display: '-webkit-box', WebkitLineClamp: 1, WebkitBoxOrient: 'vertical', overflow: 'hidden' }}>
          {email.sender.subject}
        </div>
        {email.preview && (
          <div style={{ color: '#64748b', marginTop: 2,
            display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical', overflow: 'hidden' }}>
            {email.preview}
          </div>
        )}
      </div>

      <div style={{ display: 'flex', gap: 4, marginBottom: 6, flexWrap: 'wrap' }}>
        <AuthChip label="SPF" value={auth.spf} />
        <AuthChip label="DKIM" value={auth.dkim} />
        <AuthChip label="DMARC" value={auth.dmarc} />
      </div>

        <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap' }}>
          {email.ip && <span onClick={() => onFilter && onFilter(email.ip)} title={onFilter ? 'Filter by IP' : ''} style={{ ...chip, cursor: onFilter ? 'pointer' : 'default' }}>IP: {cleanIp(email.ip)}</span>}
          {email.sender.domain && (
            <span title={onFilter ? 'Filter by domain' : ''}
              onClick={() => onFilter && onFilter(email.sender.domain)}
              style={{ ...chip, cursor: onFilter ? 'pointer' : 'default' }}>
              {email.sender.domain}
            </span>
          )}
        </div>
      </div>
    </div>
  )
}

const chip = { fontSize: 10, color: '#334155', background: 'rgba(255,255,255,0.7)',
  border: '1px solid rgba(0,0,0,0.08)', borderRadius: 5, padding: '1px 6px' }
'@
Write-Host 'wrote frontend\src\components\emails\EmailCard.jsx'

Write-Host ""
Write-Host "STAGE 40 written. Restart frontend (npm run dev), hard-refresh."
