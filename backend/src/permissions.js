// Permission keys an admin can grant a support user
export const PERMS = ['manage_users', 'manage_isps', 'delete_accounts',
  'share_accounts', 'resolve_requests', 'set_passwords', 'refresh_accounts']

export function isStaff(user) {
  return user?.role === 'admin' || user?.role === 'support'
}

// admin has all; support has whatever is granted in user.permissions
export function can(user, perm) {
  if (user?.role === 'admin') return true
  if (user?.role === 'support') return !!user.permissions?.[perm]
  return false
}

export function staffOnly(req, res, next) {
  if (!isStaff(req.user)) return res.status(403).json({ message: 'Staff only' })
  next()
}

export const requirePerm = (perm) => (req, res, next) => {
  if (!can(req.user, perm)) return res.status(403).json({ message: `Missing permission: ${perm}` })
  next()
}
