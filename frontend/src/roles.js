// Frontend role hierarchy helper (mirrors backend permissions.js)
// owner > admin > support > manager > team_leader > mailer
export const RANK = { mailer: 1, team_leader: 2, manager: 3, support: 4, admin: 5, owner: 6 }
export const rankOf = (user) => RANK[user?.role] || 0
// "staff" = manager and up (can see management-style UI / notifications)
export const isStaff = (user) => rankOf(user) >= RANK.manager
// owner/admin/support have all permissions; manager/team_leader only granted ones
export const can = (user, perm) => {
  if (rankOf(user) >= RANK.support) return true
  if (rankOf(user) >= RANK.team_leader) return !!user?.permissions?.[perm]
  return false
}
export const canManageUsers = (user) => rankOf(user) >= RANK.support
export const roleLabel = (role) => ({
  owner: 'Owner', admin: 'Administrator', support: 'Support', manager: 'Manager',
  team_leader: 'Team Leader', mailer: 'Mailer',
}[role] || 'Mailer')
