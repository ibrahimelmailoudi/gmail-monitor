import client from '../api/client'

export const dnsLookup  = (domain) => client.get('/api/tools/dns', { params: { domain } }).then(r => r.data)
export const dkimLookup = (domain, selector) =>
  client.get('/api/tools/dkim', { params: { domain, selector } }).then(r => r.data)
export const recordsLookup = (domain) => client.get('/api/tools/records', { params: { domain } }).then(r => r.data)
export const ptrLookup     = (ip) => client.get('/api/tools/ptr', { params: { ip } }).then(r => r.data)
export const spfTree = (domain) => client.get('/api/tools/spf-tree', { params: { domain } }).then(r => r.data)
