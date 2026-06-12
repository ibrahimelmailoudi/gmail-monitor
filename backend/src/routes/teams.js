import { Router } from 'express'
import { auth } from '../auth-middleware.js'
import { rankOf, RANK } from '../permissions.js'
import {
  listTeams, createTeam, updateTeam, deleteTeam, teamsForManager, teamsForLeader,
  listTeamMembers, addTeamMember, removeTeamMember, teamsForMember,
  accountsOwnedByUser, getUserById,
} from '../store.js'

const router = Router()
router.use(auth)

const isAdminUp = (u) => rankOf(u) >= RANK.support // support/admin/owner

// Can this user access this team? admin+ always; the team's manager; or a leader in it.
async function canAccessTeam(user, teamId) {
  if (isAdminUp(user)) return true
  const mgrTeams = await teamsForManager(user.id)
  if (mgrTeams.some(t => t.id === teamId)) return true
  const leadTeams = await teamsForLeader(user.id)
  if (leadTeams.some(t => t.id === teamId)) return true
  return false
}

// List teams visible to the caller.
router.get('/', async (req, res) => {
  if (isAdminUp(req.user)) return res.json(await listTeams())
  // managers see their teams; leaders see teams they lead; everyone sees teams they're in
  const mgr = await teamsForManager(req.user.id)
  const lead = await teamsForLeader(req.user.id)
  const member = await teamsForMember(req.user.id)
  const byId = new Map()
  ;[...mgr, ...lead, ...member].forEach(t => byId.set(t.id, t))
  res.json([...byId.values()])
})

// Create a team (admin/owner/support only) - assign a manager.
router.post('/', async (req, res) => {
  if (!isAdminUp(req.user)) return res.status(403).json({ message: 'Only admin/owner can create teams' })
  const { name, managerId } = req.body || {}
  if (!name?.trim()) return res.status(400).json({ message: 'Team name required' })
  res.json(await createTeam(name.trim(), managerId || null))
})

// Update team (admin/owner) - rename or reassign manager.
router.put('/:id', async (req, res) => {
  if (!isAdminUp(req.user)) return res.status(403).json({ message: 'Only admin/owner can edit teams' })
  await updateTeam(req.params.id, { name: req.body?.name, managerId: req.body?.managerId })
  res.json({ ok: true })
})

router.delete('/:id', async (req, res) => {
  if (!isAdminUp(req.user)) return res.status(403).json({ message: 'Only admin/owner can delete teams' })
  await deleteTeam(req.params.id)
  res.json({ ok: true })
})

// Members of a team (manager of that team, its leaders, or admin+).
router.get('/:id/members', async (req, res) => {
  if (!await canAccessTeam(req.user, req.params.id)) return res.status(403).json({ message: 'No access' })
  res.json(await listTeamMembers(req.params.id))
})

// Add a member. The team's manager (or admin+) may add leaders/mailers.
router.post('/:id/members', async (req, res) => {
  const { userId, roleInTeam } = req.body || {}
  if (!['team_leader', 'mailer'].includes(roleInTeam))
    return res.status(400).json({ message: 'roleInTeam must be team_leader or mailer' })
  // only the team manager or admin+ can add members
  const mgrTeams = await teamsForManager(req.user.id)
  const isMgr = mgrTeams.some(t => t.id === req.params.id)
  if (!isAdminUp(req.user) && !isMgr) return res.status(403).json({ message: 'Only the team manager or admin can add members' })
  await addTeamMember(req.params.id, userId, roleInTeam)
  res.json({ ok: true })
})

router.delete('/:id/members/:userId', async (req, res) => {
  const mgrTeams = await teamsForManager(req.user.id)
  const isMgr = mgrTeams.some(t => t.id === req.params.id)
  if (!isAdminUp(req.user) && !isMgr) return res.status(403).json({ message: 'Only the team manager or admin can remove members' })
  await removeTeamMember(req.params.id, req.params.userId)
  res.json({ ok: true })
})

// Read-only view of a member's accounts (manager of their team, a leader in that
// team, or admin+). Leaders can SEE but not edit.
router.get('/:id/members/:userId/accounts', async (req, res) => {
  if (!await canAccessTeam(req.user, req.params.id)) return res.status(403).json({ message: 'No access' })
  const accounts = await accountsOwnedByUser(req.params.userId)
  res.json({ readOnly: true, accounts })
})

export default router
