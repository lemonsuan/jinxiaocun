import { test } from 'node:test'
import assert from 'node:assert/strict'
import { settlementInput } from '../src/admin/order-actions.ts'
import { attemptStorageKey, settlementAttempt, readOrderAttempt } from '../src/admin/order-attempts.ts'
import { jobReportLink } from '../src/admin/logic.ts'

function order() {
  return {
    id: '00000000-0000-4000-8000-000000000001', order_number: '001ORDER', version: 4,
    job: { version: 8 }, payout: { version: 3, alipay_phone: '13800000000' },
    parcels: [
      { tracking_number: '001SF', receipt: { receipt_id: 'receipt-1', revision: 19 } },
      { tracking_number: '002SF', receipt: null },
    ],
  }
}
test('确认携带核对时的订单、作业、收款版本和全部已到货证据', () => {
  assert.deepEqual(settlementInput(order(), 'operation-1'), {
    expected_version: 4, expected_job_version: 8, expected_payout_version: 3,
    operation_id: 'operation-1', evidence: [{ tracking_number: '001SF', receipt_id: 'receipt-1', revision: 19 }],
  })
  assert.equal(settlementInput({ ...order(), payout: null }, 'operation-2').expected_payout_version, 0)
})
test('未知结果重试冻结原请求，后来收款和证据变化不会混入，且不保存收款隐私', () => {
  const detail = order()
  const attempt = settlementAttempt(detail, 'same-key')
  detail.version++
  detail.payout.version++
  detail.parcels[0].receipt.revision++
  detail.parcels[0].tracking_number = 'changed'
  assert.equal(attempt.input.expected_version, 4)
  assert.equal(attempt.input.expected_payout_version, 3)
  assert.equal(attempt.input.evidence[0].revision, 19)
  assert.equal(attempt.input.evidence[0].tracking_number, '001SF')
  assert.equal(attempt.input.operation_id, 'same-key')
  assert.ok(!JSON.stringify(attempt).includes('13800000000'))
})
test('待确认请求按账号和店铺隔离，刷新读取保持操作键且不恢复坏存储', () => {
  const first = attemptStorageKey('admin', 'shop-a')
  const otherShop = attemptStorageKey('admin', 'shop-b')
  const otherAdmin = attemptStorageKey('another', 'shop-a')
  assert.notEqual(first, otherShop)
  assert.notEqual(first, otherAdmin)
  const attempt = settlementAttempt(order(), 'same-key')
  const storage = new Map([[first, JSON.stringify(attempt)]])
  const api = { getItem: key => storage.get(key) ?? null }
  assert.deepEqual(readOrderAttempt(api, first), attempt)
  assert.equal(readOrderAttempt(api, otherShop), null)
  for (const value of ['{', 'null', '{}', JSON.stringify({ ...attempt, action: 'other' }), JSON.stringify({ ...attempt, input: { ...attempt.input, expected_version: -1 } })]) {
    storage.set(first, value)
    assert.equal(readOrderAttempt(api, first), null)
  }
})
test('撤销结算未知结果保存原原因和操作键', () => {
  const attempt = { action: 'reopen', orderId: order().id, orderNumber: '001ORDER', input: { expected_version: 5, operation_id: 'reopen-key', reason: '更正付款记录' } }
  assert.deepEqual(readOrderAttempt({ getItem: () => JSON.stringify(attempt) }, 'key'), attempt)
})
test('作业分享带公开店号和登录后目标，清除管理搜索参数', () => {
  const link = jobReportLink('https://shop.example/app/?token=private#/shop/jobs', '10003', order().id)
  const url = new URL(link)
  assert.equal(url.search, '')
  const [path, query] = url.hash.slice(1).split('?')
  assert.equal(path, '/worker/login')
  const params = new URLSearchParams(query)
  assert.equal(params.get('shop'), '10003')
  assert.equal(params.get('redirect'), `/worker/jobs/${order().id}`)
  assert.ok(!link.includes('private'))
  assert.equal(jobReportLink('https://shop.example', '10003', '../../admin'), '')
  assert.equal(jobReportLink('https://shop.example', '9223372036854775808', order().id), '')
})
