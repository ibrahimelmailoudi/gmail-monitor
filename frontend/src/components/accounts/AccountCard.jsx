import { useState, useMemo } from 'react'
import { Avatar, Button, Space, Popconfirm, Tag, Card, Typography, Input, Tooltip, message, Modal, AutoComplete } from 'antd'
import { MailOutlined, PlayCircleOutlined, PauseCircleOutlined, DeleteOutlined, SearchOutlined, LockOutlined, ReloadOutlined, ShareAltOutlined, StarOutlined, StarFilled } from '@ant-design/icons'
import EmailCard from '../emails/EmailCard'
import { useApp } from '../../context/AppProvider'
import { refreshAccount, searchUsers, shareAccount, setPriority } from '../../services/accounts'

const { Text } = Typography
const MAX_PER_SECTION = 40

export default function AccountCard({ account, onToggle, onRemove, onRefresh, newEmailIds, emailFilter, onPlacementClick, showOwnerName }) {
  const { user } = useApp()
  const isStaff = user?.role === 'admin' || user?.role === 'support'
  const isAdmin = !!user?.is_admin
  const [localSearch, setLocalSearch] = useState('')
  const [refreshing, setRefreshing] = useState(false)
  const [shareOpen, setShareOpen] = useState(false)
  const [shareOptions, setShareOptions] = useState([])
  const [sharePick, setSharePick] = useState(null)
  const [shareText, setShareText] = useState('')
  const [priority, setPriorityState] = useState(!!account.priority)

  const isOwner = (account.owner_id || account.ownerId) === user?.id
  const isGlobal = account.scope === 'global'
  // Rule: normal users get NO crud on GLOBAL accounts (only staff do).
  // On personal accounts, the owner and staff have full crud.
  const canToggle = isGlobal ? isStaff : (isOwner || isStaff)
  const canDelete = isGlobal ? isStaff : (isOwner || isStaff)
  // Refresh: staff always; on personal accounts the owner; or a user explicitly
  // granted the refresh_accounts permission (but still not on global unless staff).
  const canRefresh = isStaff || (!isGlobal && isOwner) || (!isGlobal && !!user?.permissions?.refresh_accounts)
  // Share: only the owner of a personal account, or staff.
  const canShare = isGlobal ? isStaff : (isOwner || isStaff)
  // Priority: owner of a personal account, or staff.
  const canPriority = isGlobal ? isStaff : (isOwner || isStaff)

  const togglePriority = async () => {
    const next = !priority
    setPriorityState(next) // optimistic
    try { await setPriority(account.id, next) }
    catch { setPriorityState(!next); message.error('Could not change priority') }
  }

  const filtered = useMemo(() => {
    let list = account.emails || []
    if (emailFilter) list = list.filter(emailFilter)
    const q = localSearch.toLowerCase().trim()
    if (q) {
      list = list.filter(e =>
        (e.sender?.name || '').toLowerCase().includes(q) ||
        (e.sender?.subject || '').toLowerCase().includes(q) ||
        (e.sender?.domain || '').toLowerCase().includes(q) ||
        (e.ip || '').toLowerCase().includes(q))
    }
    return list
  }, [account.emails, localSearch, emailFilter])

  const total = (account.emails || []).length
  const shown = filtered.slice(0, MAX_PER_SECTION)
  const live = account.active

  const doRefresh = async () => {
    setRefreshing(true)
    try {
      const data = await refreshAccount(account.id)
      onRefresh?.(account.id, data.emails || [])
      message.success(`Refreshed ${account.email}`)
    } catch (e) {
      message.error(e.response?.data?.message || 'Refresh failed')
    } finally { setRefreshing(false) }
  }

  // share-by-name: type a name/code, system proposes matches (id shown), pick one
  const onShareSearch = async (text) => {
    setShareText(text)
    if (!text || text.length < 2) { setShareOptions([]); return }
    try {
      const users = await searchUsers(text)
      setShareOptions(users.map(u => ({
        value: u.id,
        label: `${u.username}  -  ID ${u.code}`,
      })))
    } catch { setShareOptions([]) }
  }
  const doShare = async () => {
    if (!sharePick) return message.warning('Pick a user from the list')
    try {
      await shareAccount(account.id, sharePick)
      message.success('Account shared')
      setShareOpen(false); setSharePick(null); setShareText(''); setShareOptions([])
    } catch (e) { message.error(e.response?.data?.message || 'Share failed') }
  }

  return (
    <Card styles={{ body: { padding: 14 } }} style={{ marginBottom: 14 }}>
      <div style={{ display: 'flex', gap: 16, alignItems: 'stretch' }}>
        <div style={{ width: 215, minWidth: 215, display: 'flex', flexDirection: 'column', gap: 8 }}>
          <Space align="center">
            {/* Envelope turns green when live, gray/amber when paused */}
            <Avatar shape="square"
              style={{ background: live ? '#16a34a' : '#94a3b8' }}
              icon={<MailOutlined />} />
            <Text strong style={{ color: live ? '#16a34a' : '#94a3b8' }}>
              {live ? 'Live' : 'Paused'}
            </Text>
          </Space>

          <Text strong style={{ wordBreak: 'break-all' }}>
            {showOwnerName ? (account.owner_username || account.ownerName || account.email) : account.email}
          </Text>
          <Space size={6} wrap>
            {isStaff && account.type && <Tag>{account.type.toUpperCase()}</Tag>}
            {account.scope === 'global' && <Tag color="purple">GLOBAL</Tag>}
            {priority && <Tag color="gold">PRIORITY</Tag>}
            <Tag color="blue">{total} emails</Tag>
          </Space>

          <Input size="small" allowClear prefix={<SearchOutlined />}
            placeholder="Filter this account"
            value={localSearch} onChange={(e) => setLocalSearch(e.target.value)} />

          {/* Controls: pause/resume + refresh + delete */}
          <Space style={{ marginTop: 'auto' }} wrap>
            {canToggle ? (
              <Tooltip title={live ? 'Pause' : 'Resume'}>
                <Button size="small" icon={live ? <PauseCircleOutlined /> : <PlayCircleOutlined />}
                  onClick={() => onToggle(account.id)} />
              </Tooltip>
            ) : (
              <Tooltip title="Global account - only staff can pause it">
                <Button size="small" disabled icon={live ? <PauseCircleOutlined /> : <PlayCircleOutlined />} />
              </Tooltip>
            )}
            {canRefresh && (
              <Tooltip title="Check for new emails now">
                <Button size="small" icon={<ReloadOutlined />} loading={refreshing} onClick={doRefresh} />
              </Tooltip>
            )}
            {canDelete ? (
              <Popconfirm title="Remove this account?" onConfirm={() => onRemove(account.id)}>
                <Button size="small" danger icon={<DeleteOutlined />}>Delete</Button>
              </Popconfirm>
            ) : (
              <Tooltip title="Global account  -  only the owner or staff can remove it">
                <Button size="small" disabled icon={<LockOutlined />}>Delete</Button>
              </Tooltip>
            )}
            {canShare && (
              <Tooltip title="Share this account with another user">
                <Button size="small" icon={<ShareAltOutlined />} onClick={() => setShareOpen(true)} />
              </Tooltip>
            )}
            {canPriority && (
              <Tooltip title={priority ? 'Priority - checked first. Click to unset.' : 'Set as priority (checked before other accounts)'}>
                <Button size="small"
                  icon={priority ? <StarFilled style={{ color: '#f59e0b' }} /> : <StarOutlined />}
                  onClick={togglePriority} />
              </Tooltip>
            )}
          </Space>
        </div>

        <div style={{ flex: 1, display: 'flex', gap: 10, overflowX: 'auto', paddingBottom: 4 }}>
          {shown.length === 0 ? (
            <div style={{ alignSelf: 'center', display: 'flex', alignItems: 'center', gap: 10,
              color: '#94a3b8', padding: '0 8px' }}>
              {localSearch ? (
                <Text type="secondary">No emails match this filter</Text>
              ) : live ? (
                <>
                  <span style={{ width: 9, height: 9, borderRadius: '50%', background: '#22c55e',
                    boxShadow: '0 0 0 0 rgba(34,197,94,0.6)', animation: 'livePulse 1.6s infinite' }} />
                  <Text type="secondary" style={{ fontWeight: 600 }}>Listening for new mail</Text>
                </>
              ) : (
                <Text type="secondary">Paused - press play to resume monitoring</Text>
              )}
            </div>
          ) : shown.map((em, i) => (
            <EmailCard key={em.id} email={em} isNew={newEmailIds.has(em.id)} index={i}
              onFilter={(text) => setLocalSearch(text)} onPlacementClick={onPlacementClick} />
          ))}
          {filtered.length > MAX_PER_SECTION && (
            <div style={{ alignSelf: 'center', minWidth: 90, color: '#94a3b8', fontSize: 12, textAlign: 'center' }}>
              +{filtered.length - MAX_PER_SECTION} more
            </div>
          )}
        </div>
      </div>

      <Modal title={`Share ${account.email}`} open={shareOpen} onCancel={() => setShareOpen(false)}
        onOk={doShare} okText="Share">
        <p style={{ color: '#64748b' }}>Type a username (or their 4-digit ID). Pick the right person from the suggestions.</p>
        <AutoComplete
          style={{ width: '100%' }}
          options={shareOptions}
          value={shareText}
          onSearch={onShareSearch}
          onChange={(v) => setShareText(v)}
          onSelect={(value, option) => { setSharePick(value); setShareText(option.label) }}
          placeholder="Start typing a name or ID..."
        />
      </Modal>
    </Card>
  )
}
