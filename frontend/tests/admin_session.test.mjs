import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createPinia, setActivePinia } from 'pinia'
const storage = new Map()
globalThis.localStorage = {
  getItem: (key) => storage.get(key) ?? null,
  setItem: (key, value) => storage.set(key, value),
  removeItem: (key) => storage.delete(key),
}
const { useAuthStore } = await import('../src/store/auth.ts')
test('数字店铺ID与内部店铺标识分开存储，切店提升会话版本，重新登录一并清空', () => {
  setActivePinia(createPinia())
  const store = useAuthStore()
  store.setLoginInfo('admin', '店主')
  const before = store.scopeVersion
  store.setActiveShop('uuid-a', 'A店', 'CREATOR', '10000')
  assert.equal(store.activeShopId, 'uuid-a')
  assert.equal(store.activeShopNumber, '10000')
  assert.equal(storage.get('shop_active_number'), '10000')
  assert.ok(store.scopeVersion > before)
  storage.set('worker_token', 'worker')
  store.setLoginInfo('new-admin', '另一人')
  assert.equal(store.activeShopNumber, '')
  assert.equal(store.activeShopId, '')
  assert.equal(storage.has('shop_active_number'), false)
  assert.equal(storage.get('worker_token'), 'worker')
})
