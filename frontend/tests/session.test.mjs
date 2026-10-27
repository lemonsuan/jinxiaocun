import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createPinia, setActivePinia } from 'pinia'
import { sameScope } from '../src/utils/session-scope.ts'
const storage = new Map()
globalThis.localStorage = { getItem: key => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key) }
const { useAuthStore } = await import('../src/store/auth.ts')
function auth() { storage.clear(); setActivePinia(createPinia()); return useAuthStore() }
test('new login clears previous account shop and role in reactive state and storage', () => {
  const store = auth(); store.setLoginInfo('old-token', 'old'); store.setActiveShop('shop-a', 'A', 'CREATOR')
  store.setLoginInfo('new-token', 'new')
  assert.equal(store.activeShopId, ''); assert.equal(store.activeShopRole, '')
  assert.equal(storage.has('shop_active_id'), false); assert.equal(storage.has('shop_active_name'), false); assert.equal(storage.has('shop_active_role'), false)
})
test('logout invalidates captured scope and clears every persisted session field', () => {
  const store = auth(); store.setLoginInfo('token', 'user'); store.setActiveShop('a', 'A', 'ADMIN')
  const captured = { token:store.token, activeShopId:store.activeShopId, scopeVersion:store.scopeVersion }
  assert.equal(sameScope(captured, store), true); store.logout()
  assert.equal(sameScope(captured, store), false); assert.equal(store.token, ''); assert.equal(store.username, ''); assert.equal(storage.size, 0)
})
test('returning to the same shop does not revive an old response', () => {
  const store = auth(); store.setLoginInfo('token', 'user'); store.setActiveShop('a', 'A', 'MEMBER')
  const captured = { token:store.token, activeShopId:store.activeShopId, scopeVersion:store.scopeVersion }
  store.setActiveShop('b', 'B', 'MEMBER'); store.setActiveShop('a', 'A', 'MEMBER')
  assert.equal(sameScope(captured, store), false)
})
