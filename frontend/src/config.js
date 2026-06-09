// Central config & constants
export const API = import.meta.env.VITE_BACKEND_URL

export const CATEGORIES = {
  primary:    { name: 'Primary Inbox', color: '#15803d', bg: '#dcfce7', border: '#86efac' },
  spam:       { name: 'Spam',          color: '#b91c1c', bg: '#fee2e2', border: '#fca5a5' },
  promotions: { name: 'Promotions',    color: '#be185d', bg: '#fce7f3', border: '#f9a8d4' },
  social:     { name: 'Social',        color: '#4338ca', bg: '#e0e7ff', border: '#a5b4fc' },
  updates:    { name: 'Updates',       color: '#c2410c', bg: '#ffedd5', border: '#fdba74' },
  forums:     { name: 'Forums',        color: '#0e7490', bg: '#cffafe', border: '#67e8f9' },
  unknown:    { name: 'Unknown',       color: '#64748b', bg: '#f1f5f9', border: '#cbd5e1' },
  other:      { name: 'Other',         color: '#475569', bg: '#f1f5f9', border: '#cbd5e1' },
}
