import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  parseTrackingNumbers,
  validShopNumber,
  sameWorkerScope,
  safeWorkerReturn,
  moneyText,
  statusText,
  operationId,
} from '../src/worker/logic.ts'

test('快递粘贴保留字母和前导零，常见分隔去重且不重复报单', () => {
  const result = parseTrackingNumbers(['SF001，002\nSF001; JD003', '002', ''])
  assert.deepEqual(result.values, ['SF001', '002', 'JD003'])
  assert.equal(result.duplicateCount, 2)
  assert.equal(result.error, '')
})
test('快递列表严格限制每号长度及20个不同号码，不静默截断', () => {
  assert.match(parseTrackingNumbers(['A'.repeat(101)]).error, /100/)
  assert.match(
    parseTrackingNumbers(Array.from({ length: 21 }, (_, index) => `SF${index}`))
      .error,
    /20/,
  )
  assert.equal(parseTrackingNumbers(['\n,， ;']).values.length, 0)
})
test('数字店铺ID不转浮点，支持精确上限并拒绝无效或UUID', () => {
  for (const value of ['10000', '10001', '9223372036854775807'])
    assert.equal(validShopNumber(value), true)
  for (const value of [
    '9999',
    '010000',
    '1e5',
    '-10000',
    '9223372036854775808',
    '123e4567-e89b-12d3-a456-426614174000',
    '',
  ])
    assert.equal(validShopNumber(value), false)
})
test('拍手身份代际拒绝返回同店同账号后的旧请求', () => {
  const scope = { token: 'token', workerId: 'a', shopNumber: '10000', epoch: 0 }
  assert.equal(sameWorkerScope(scope, { ...scope }), true)
  assert.equal(sameWorkerScope(scope, { ...scope, epoch: 2 }), false)
  assert.equal(sameWorkerScope(scope, { ...scope, workerId: 'b' }), false)
  assert.equal(sameWorkerScope(scope, { ...scope, shopNumber: '10001' }), false)
})
test('登录后的返回地址只允许拍手订单与作业内部路径', () => {
  assert.equal(
    safeWorkerReturn('/worker/orders/new?job=abc'),
    '/worker/orders/new?job=abc',
  )
  for (const value of [
    'https://other.test',
    '//other.test',
    '/shop/stock',
    '/worker/login',
    '/worker/jobs-malicious',
  ])
    assert.equal(safeWorkerReturn(value), '/worker/jobs')
})
test('金额以十进制字符串展示，三态标签没有多余核验状态', () => {
  assert.equal(moneyText('1234567890123456.20'), '1234567890123456.20')
  assert.equal(moneyText('0'), '0.00')
  assert.equal(moneyText('1.2'), '1.20')
  assert.equal(moneyText('1.234'), '—')
  assert.equal(statusText('in_transit'), '运输中')
  assert.equal(statusText('arrived'), '已到货')
  assert.equal(statusText('settled'), '已结算')
  assert.notEqual(operationId(), operationId())
})
