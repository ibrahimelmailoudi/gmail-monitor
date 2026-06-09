// backend/src/placements.js

/**
 * Detect the provider name from IMAP host or email domain.
 * Used as a FALLBACK when the account has no isp_id linked.
 */
export function providerOf({ host = '', ispName = '' }) {
  const h = host.toLowerCase()
  const e = ispName.toLowerCase()

  if (h.includes('gmail') || h.includes('google') || e.includes('@gmail.com'))
    return 'gmail'
  if (h.includes('gmx') || e.includes('@gmx.') || e.includes('@web.de'))
    return 'gmx'
  if (h.includes('outlook') || h.includes('hotmail') || h.includes('live.com')
      || e.includes('@outlook.com') || e.includes('@hotmail.com') || e.includes('@live.com'))
    return 'outlook'
  if (h.includes('yahoo') || e.includes('@yahoo.'))
    return 'yahoo'
  if (h.includes('icloud') || e.includes('@icloud.com') || e.includes('@me.com'))
    return 'icloud'
  if (h.includes('zoho') || e.includes('@zoho.com'))
    return 'zoho'

  return 'generic'
}

/**
 * Fallback placement definitions when the account has no ISP record in the DB.
 * These mirror exactly what fill-stage33.sql seeds into the isps table.
 */
const PROVIDER_PLACEMENTS = {
  gmail: [
    { key: 'primary',    label: 'Primary Inbox', detect: { type: 'gmraw', query: 'category:primary' } },
    { key: 'promotions', label: 'Promotions',    detect: { type: 'gmraw', query: 'category:promotions' } },
    { key: 'social',     label: 'Social',         detect: { type: 'gmraw', query: 'category:social' } },
    { key: 'updates',    label: 'Updates',        detect: { type: 'gmraw', query: 'category:updates' } },
    { key: 'forums',     label: 'Forums',         detect: { type: 'gmraw', query: 'category:forums' } },
    { key: 'spam',       label: 'Spam',           detect: { type: 'folder', path: '[Gmail]/Spam' } },
  ],
  gmx: [
    { key: 'inbox', label: 'Inbox', detect: { type: 'inbox' } },
    { key: 'spam',  label: 'Spam',  detect: { type: 'folder', path: 'Spam' } },
  ],
  outlook: [
    { key: 'focused', label: 'Focused',    detect: { type: 'inbox' } },
    { key: 'other',   label: 'Other',      detect: { type: 'folder', path: 'Other' } },
    { key: 'spam',    label: 'Spam (Junk)', detect: { type: 'folder', path: 'Junk' } },
  ],
  yahoo: [
    { key: 'inbox', label: 'Inbox',        detect: { type: 'inbox' } },
    { key: 'spam',  label: 'Spam (Bulk)',  detect: { type: 'folder', path: 'Bulk Mail' } },
  ],
  icloud: [
    { key: 'inbox', label: 'Inbox', detect: { type: 'inbox' } },
    { key: 'spam',  label: 'Junk',  detect: { type: 'folder', path: 'Junk' } },
  ],
  zoho: [
    { key: 'inbox', label: 'Inbox', detect: { type: 'inbox' } },
    { key: 'spam',  label: 'Spam',  detect: { type: 'folder', path: 'Spam' } },
  ],
  generic: [
    { key: 'inbox', label: 'Inbox', detect: { type: 'inbox' } },
    { key: 'spam',  label: 'Spam',  detect: { type: 'folder', path: 'Spam' } },
  ],
}

/**
 * Returns the placement array for a given provider key.
 * The route /:id/placements uses this as a fallback when no ISP record exists.
 */
export function placementsFor(provider) {
  return PROVIDER_PLACEMENTS[provider] ?? PROVIDER_PLACEMENTS.generic
}