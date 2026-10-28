import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createPinia, setActivePinia } from 'pinia'
import { AxiosError } from 'axios'
const storage = new Map()
globalThis.localStorage = {
  getItem: (key) => storage.get(key) ?? null,
  setItem: (key, value) => storage.set(key, value),
  removeItem: (key) => storage.delete(key),
}
const { useWorkerStore } = await import('../src/worker/store.ts')
const { workerRequest, workerPublicRequest, WorkerRequestError } = await import(
  '../src/worker/request.ts'
)
function setup() {
  storage.clear()
  setActivePinia(createPinia())
  const auth = useWorkerStore()
  auth.setSession({
    token: 'worker-a',
    worker: {
      id: 'a',
      username: 'a',
      display_name: '甲',
      shop_number: '10000',
      shop_name: 'A',
    },
  })
  storage.set('shop_token', 'admin-secret')
  return auth
}
function response(config, data, status = 200) {
  return { config, data, status, statusText: '', headers: {} }
}
test('拍手与公开注册请求不携带管理端凭据或库存店铺头', async () => {
  setup()
  workerRequest.defaults.adapter = async (config) => {
    assert.equal(config.headers.Authorization, 'Bearer worker-a')
    assert.equal(config.headers['X-Active-Shop-ID'], undefined)
    return response(config, { ok: true })
  }
  assert.deepEqual(await workerRequest.get('/me'), { ok: true })
  workerPublicRequest.defaults.adapter = async (config) => {
    assert.equal(config.headers.Authorization, undefined)
    assert.equal(config.headers['X-Active-Shop-ID'], undefined)
    return response(config, { shop_number: '10000', name: 'A' })
  }
  assert.equal((await workerPublicRequest.get('/shop')).shop_number, '10000')
})
test('禁用响应清除拍手身份，管理会话保持原样', async () => {
  const auth = setup()
  workerRequest.defaults.adapter = async (config) => {
    const res = response(
      config,
      { detail: '拍手账号已被本店禁用，请联系管理员' },
      403,
    )
    throw new AxiosError('Forbidden', 'ERR_BAD_REQUEST', config, null, res)
  }
  await assert.rejects(
    workerRequest.get('/orders'),
    (error) => error instanceof WorkerRequestError && error.status === 403,
  )
  assert.equal(auth.token, '')
  assert.equal(auth.worker, null)
  assert.equal(storage.get('shop_token'), 'admin-secret')
  assert.match(auth.notice, /禁用/)
})
test('旧账号迟到的401不能注销新拍手账号', async () => {
  const auth = setup()
  let release
  let started
  const pending = new Promise((resolve) => {
    release = resolve
  })
  const requested = new Promise((resolve) => {
    started = resolve
  })
  workerRequest.defaults.adapter = async (config) => {
    started()
    await pending
    const res = response(config, { detail: '登录已过期' }, 401)
    throw new AxiosError('Unauthorized', 'ERR_BAD_REQUEST', config, null, res)
  }
  const request = workerRequest.get('/orders')
  await requested
  auth.setSession({
    token: 'worker-b',
    worker: {
      id: 'b',
      username: 'b',
      display_name: '乙',
      shop_number: '10001',
      shop_name: 'B',
    },
  })
  release()
  await assert.rejects(request, (error) => error.code === 'ERR_CANCELED')
  assert.equal(auth.token, 'worker-b')
  assert.equal(auth.worker.shop_number, '10001')
})
test('网络失败明确标注结果未知供保存请求沿用同一操作键', async () => {
  setup()
  workerRequest.defaults.adapter = async (config) => {
    throw new AxiosError('offline', 'ERR_NETWORK', config)
  }
  await assert.rejects(
    workerRequest.post('/orders', { operation_id: 'fixed' }),
    (error) =>
      error instanceof WorkerRequestError &&
      error.outcomeUnknown &&
      error.status === 0,
  )
})
