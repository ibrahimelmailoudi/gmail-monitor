// All dashboard sections. `grantable: true` means an admin/owner can give this
// section to a user via the Access checkboxes. Sections that are always available
// to everyone, or restricted to a role, are listed too (so the full picture shows),
// but only grantable ones render as checkboxes in the Access dialog.
export const SECTIONS = [
  // Granted by admin/owner:
  { key: 'overview',     label: 'Overview (Deliverability)', grantable: true },
  { key: 'extract',      label: 'Extract',                   grantable: true },
  { key: 'analytics',    label: 'Analytics',                 grantable: true },
  { key: 'allaccounts',  label: 'All Accounts',              grantable: true },
  { key: 'storedemails', label: 'Stored Emails',             grantable: true },
  // Always available to everyone (shown for completeness, not grantable):
  { key: 'monitor',      label: 'Monitor',                   grantable: false, always: true },
  { key: 'myaccounts',   label: 'My Accounts',               grantable: false, always: true },
  { key: 'storage',      label: 'Storage',                   grantable: false, always: true },
  { key: 'tools',        label: 'Tools',                     grantable: false, always: true },
  { key: 'vault',        label: 'Vault',                     grantable: false, always: true },
  { key: 'requests',     label: 'Support',                   grantable: false, always: true },
  // Role-restricted (not grantable by checkbox):
  { key: 'teams',        label: 'Teams',        grantable: false, role: 'team_leader+' },
  { key: 'users',        label: 'Users',        grantable: false, role: 'support+' },
  { key: 'settings',     label: 'Settings',     grantable: false, role: 'admin+' },
]

// Convenience: just the ones an admin can grant.
export const GRANTABLE_SECTIONS = SECTIONS.filter(s => s.grantable)
