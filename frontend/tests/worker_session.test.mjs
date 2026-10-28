import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createPinia, setActivePinia } from 'pinia'
const storage = new Map()
globalThis.localStorage = {
  getItem: (key) => storage.get(key) ?? null,
  setItem: (key, value) => storage.set(key, value),
  removeItem: (key) => storage.delete(key),
}
const { useWorkerStore } = await import('../src/worker/store.ts')
const { sameWorkerScope } = await import('../src/worker/logic.ts')
function session(id = 'a', shop = '10000') {
  return {
    token: `worker-${id}`,
    worker: {
      id,
      username: `user-${id}`,
      display_name: `拍手${id}`,
      shop_number: shop,
      shop_name: `店铺${shop}`,
    },
  }
}
function setup() {
  storage.clear()
  setActivePinia(createPinia())
  return useWorkerStore()
}
test('拍手登录及退出不改管理端凭据，退出清除本人敏感资料', () => {
  const auth = setup()
  storage.set('shop_token', 'admin-token')
  storage.set('shop_active_id', 'admin-shop')
  auth.setSession(session())
  const captured = auth.scope()
  assert.equal(sameWorkerScope(captured, auth.scope()), true)
  auth.logout('账号已禁用')
  assert.equal(auth.token, '')
  assert.equal(auth.worker, null)
  assert.equal(auth.notice, '账号已禁用')
  assert.equal(storage.has('worker_token'), false)
  assert.equal(storage.has('worker_profile'), false)
  assert.equal(storage.get('shop_token'), 'admin-token')
  assert.equal(storage.get('shop_active_id'), 'admin-shop')
  assert.equal(auth.lastShop, '10000')
  assert.equal(sameWorkerScope(captured, auth.scope()), false)
})
test('切换账号或店铺后旧响应失效，返回原账号也不能复活', () => {
  const auth = setup()
  auth.setSession(session())
  const captured = auth.scope()
  auth.setSession(session('b', '10001'))
  auth.setSession(session())
  assert.equal(sameWorkerScope(captured, auth.scope()), false)
  assert.equal(auth.worker.id, 'a')
})
test('损坏的拍手本地资料不能仅凭残留token进入本人界面', () => {
  storage.clear()
  storage.set('worker_token', 'stale')
  storage.set('worker_profile', 'invalid-json')
  setActivePinia(createPinia())
  const auth = useWorkerStore()
  assert.equal(auth.token, '')
  assert.equal(auth.worker, null)
})
