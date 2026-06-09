import { nanoid } from 'nanoid'

export function categoryFromLabels(labels = []) {
  if (labels.includes('SPAM')) return 'spam'
  if (labels.includes('CATEGORY_PROMOTIONS')) return 'promotions'
  if (labels.includes('CATEGORY_SOCIAL')) return 'social'
  if (labels.includes('CATEGORY_UPDATES')) return 'updates'
  if (labels.includes('CATEGORY_FORUMS')) return 'updates'
  return 'primary'
}

export function extractIp(receivedHeaders = []) {
  const arr = Array.isArray(receivedHeaders) ? receivedHeaders : [receivedHeaders]
  for (let i = arr.length - 1; i >= 0; i--) {
    const m = String(arr[i]).match(/\[?(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\]?/)
    if (m && !isPrivate(m[1])) return m[1]
  }
  return null
}
function isPrivate(ip) {
  return /^(10\.|127\.|0\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.)/.test(ip)
}

export function domainOf(emailAddr = '') {
  const at = emailAddr.lastIndexOf('@')
  return at === -1 ? '' : emailAddr.slice(at + 1).toLowerCase()
}

// Parse SPF/DKIM/DMARC from one or more Authentication-Results headers.
// Returns { spf, dkim, dmarc } each 'pass' | 'fail' | 'none' | null
export function parseAuth(headers = []) {
  const text = (Array.isArray(headers) ? headers : [headers]).join(' ').toLowerCase()
  const pick = (re) => { const m = text.match(re); return m ? m[1] : null }
  return {
    spf: pick(/spf=(\w+)/),
    dkim: pick(/dkim=(\w+)/),
    dmarc: pick(/dmarc=(\w+)/),
  }
}

// Heuristic category for IMAP (Gmail's Promotions/Social/Updates tabs are NOT
// exposed over IMAP, so we approximate from sender + subject keywords).
export function guessCategory({ address = '', subject = '', name = '', listUnsub = '', fallback = 'unknown' }) {
  const s = `${address} ${subject} ${name}`.toLowerCase()
  // bulk/marketing mail almost always carries List-Unsubscribe
  if (listUnsub || /(newsletter|promo|sale|offer|deal|discount|coupon|% off|unsubscribe|marketing|limited time)/.test(s)) return 'promotions'
  if (/(facebook|twitter|x\.com|instagram|linkedin|tiktok|youtube|pinterest|social|friend request|tagged you|mentioned you)/.test(s)) return 'social'
  if (/(notification|notify|alert|update|receipt|invoice|confirm|verify|verification|security|sign-?in|password|account|order #|shipping)/.test(s)) return 'updates'
  if (/(win|winner|congratulations|free|prize|claim now|act now|viagra|casino|risk-?free|wire transfer)/.test(s)) return 'spam'
  // can't tell from headers alone (common over IMAP) -> caller decides
  return fallback
}

export function buildEmail({ name, address, subject, dateMs, ip, category, auth, preview, messageId }) {
  // Normalize Message-ID (strip <>, whitespace, lowercase) so the SAME email arriving
  // live and via refresh produces the SAME id and dedupes instead of showing twice.
  const norm = (messageId || '').replace(/[<>]/g, '').trim().toLowerCase()
  const stableId = norm || nanoid()
  return {
    id: stableId,
    message_id: messageId || '',
    category: category || 'primary',
    time: new Date(dateMs || Date.now()).toISOString(),
    ip: ip || null,
    preview: (preview || '').slice(0, 140),
    auth: auth || { spf: null, dkim: null, dmarc: null },
    sender: {
      name: name || '',
      email: address || '',
      subject: subject || '(no subject)',
      domain: domainOf(address),
    },
  }
}

// Map Gmail X-GM-LABELS (returned over IMAP) to our category names - EXACT placement.
export function categoryFromImapLabels(labelsSet) {
  const labels = Array.from(labelsSet || []).map(l => String(l).toLowerCase())
  const has = (s) => labels.some(l => l.includes(s))
  if (has('spam') || has('junk')) return 'spam'
  if (has('promotions')) return 'promotions'
  if (has('social')) return 'social'
  if (has('forums')) return 'forums'
  if (has('updates')) return 'updates'
  if (has('personal') || has('inbox')) return 'primary'
  return 'unknown'
}
