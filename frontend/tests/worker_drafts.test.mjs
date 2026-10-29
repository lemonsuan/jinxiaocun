import { test, beforeEach } from 'node:test'
import assert from 'node:assert/strict'
import { orderDraftKey, readOrderDraft, saveOrderDraft, clearWorkerDrafts } from '../src/worker/drafts.ts'
const data = new Map()
globalThis.sessionStorage = {
  get length() { return data.size },
  getItem: key => data.get(key) ?? null,
  setItem: (key, value) => data.set(key, value),
  removeItem: key => data.delete(key),
  key: index => [...data.keys()][index] ?? null,
}
const scope = { token: 'never-save-token', workerId: 'a', shopNumber: '10000', epoch: 1 }
const digest = 'a'.repeat(64)
const draft = () => ({ baseVersion: 3, orderNumber: '0001', trackingText: 'SF01\n002', note: '补充说明', photos: [{ sha256: digest, name: '补充.jpg' }], pendingPhotos: [{ id: 'failed-1', name: '待重选.png' }], attempt: { order_number: '0001', tracking_numbers: ['SF01', '002'], expected_version: 3, operation_id: 'same-key', note: '补充说明', photo_sha256s: [digest] } })
beforeEach(() => data.clear())
test('草稿按店铺、本人、作业和编辑订单隔离，不携带令牌', () => {
  const key = orderDraftKey(scope, 'job1', 'order1')
  const variants = [orderDraftKey({ ...scope, shopNumber: '10001' }, 'job1', 'order1'), orderDraftKey({ ...scope, workerId: 'b' }, 'job1', 'order1'), orderDraftKey(scope, 'job2', 'order1'), orderDraftKey(scope, 'job1')]
  assert.equal(saveOrderDraft(key, draft()), true)
  for (const other of variants) assert.equal(readOrderDraft(other), null)
  assert.equal(data.get(key).includes(scope.token), false)
})
test('刷新恢复未知结果的原始操作键、版本和完整附件请求，剥离夹带字段', () => {
  const key = orderDraftKey(scope, 'job1', 'order1')
  const value = draft()
  value.attempt.token = 'should-not-restore'
  value.token = 'should-not-restore'
  saveOrderDraft(key, value)
  const restored = readOrderDraft(key)
  assert.equal(restored.attempt.operation_id, 'same-key')
  assert.equal(restored.attempt.expected_version, 3)
  assert.equal(restored.baseVersion, 3)
  assert.deepEqual(restored.attempt.photo_sha256s, [digest])
  assert.equal('token' in restored.attempt, false)
  assert.equal('token' in restored, false)
  assert.deepEqual(restored.pendingPhotos, [{ id: 'failed-1', name: '待重选.png' }])
})
test('损坏、超量和非法附件草稿不能恢复为可提交表单', () => {
  const key = orderDraftKey(scope, 'job1')
  for (const mutate of [x => { x.note = 'x'.repeat(2001) }, x => { x.photos[0].sha256 = 'wrong' }, x => { x.pendingPhotos = Array.from({ length: 10 }, (_, i) => ({ id: String(i), name: 'x' })) }, x => { x.baseVersion = -1 }, x => { x.attempt.tracking_numbers = [] }]) {
    const value = draft(); mutate(value); saveOrderDraft(key, value)
    assert.equal(readOrderDraft(key), null)
  }
  data.set(key, '{broken')
  assert.equal(readOrderDraft(key), null)
})
test('退出只清本人本店订单和收款草稿，保留其他身份草稿', () => {
  const own = orderDraftKey(scope, 'job1')
  const other = orderDraftKey({ ...scope, workerId: 'b' }, 'job1')
  data.set(own, 'own')
  data.set(other, 'other')
  data.set('worker_payout_draft_v1:10000:a', 'own-payout')
  data.set('worker_payout_draft_v1:10001:a', 'other-payout')
  clearWorkerDrafts(scope)
  assert.equal(data.has(own), false)
  assert.equal(data.has('worker_payout_draft_v1:10000:a'), false)
  assert.equal(data.get(other), 'other')
  assert.equal(data.get('worker_payout_draft_v1:10001:a'), 'other-payout')
})
test('浏览器拒绝存储时冻结提交凭据明确失败，调用者不得发送无法恢复的请求', () => {
  const key = orderDraftKey(scope, 'job1')
  const original = sessionStorage.setItem
  sessionStorage.setItem = () => { throw new Error('QuotaExceededError') }
  try { assert.equal(saveOrderDraft(key, draft()), false); assert.equal(data.has(key), false) }
  finally { sessionStorage.setItem = original }
})
