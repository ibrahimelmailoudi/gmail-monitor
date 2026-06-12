// Real-world role hierarchy (highest to lowest):
//   owner > admin > manager > team_leader > mailer
// Higher ranks outrank lower ones. owner == the is_top_admin flag holder.
export const ROLES = ['mailer', 'team_leader', 'manager', 'support', 'admin', 'owner']
export const RANK = { mailer: 1, team_leader: 2, manager: 3, support: 4, admin: 5, owner: 6 }

export function rankOf(user) { return RANK[user?.role] || 0 }

// Section-grant permission keys (granted by owner/admin to managers/leaders).
export const PERMS = ['manage_users', 'manage_isps', 'delete_accounts',
  'share_accounts', 'resolve_requests', 'set_passwords', 'refresh_accounts']

// "Staff" = anyone above a plain mailer (manager and up).
export function isStaff(user) {
  return rankOf(user) >= RANK.manager
}

// owner/admin: full powers. manager/team_leader: only explicitly granted perms.
// mailer: none.
export function can(user, perm) {
  if (rankOf(user) >= RANK.support) return true          // support, admin, owner = all
  if (rankOf(user) >= RANK.team_leader) return !!user.permissions?.[perm]
  return false
}

// Only owner/admin manage users.
export function canManageUsers(user) {
  return rankOf(user) >= RANK.support
}

// Can `actor` act on / modify `target` (must strictly outrank them)?
export function outranks(actor, target) {
  return rankOf(actor) > rankOf(target)
}

export function staffOnly(req, res, next) {
  if (!isStaff(req.user)) return res.status(403).json({ message: 'Staff only' })
  next()
}

export const requirePerm = (perm) => (req, res, next) => {
  if (!can(req.user, perm)) return res.status(403).json({ message: `Missing permission: ${perm}` })
  next()
}
