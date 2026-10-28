import { test } from 'node:test'
import assert from 'node:assert/strict'
import { parseBatchInput } from '../src/admin/batch.ts'
import { registrationLink } from '../src/admin/logic.ts'

test('批量输入支持手机粘贴分隔符，单号保持前导零和大小写，重复仅计一次', () => {
  assert.deepEqual(parseBatchInput('001A，SF2;001A\nsf2；ABC\tABC'), {
    numbers: ['001A', 'SF2', 'sf2', 'ABC'],
    duplicates: 2,
    error: '',
  })
})
test('批量上限按不同单号计算，重复粘贴不会错误触发200限制', () => {
  const numbers = Array.from({ length: 200 }, (_, i) => `SF${i}`)
  assert.equal(parseBatchInput([...numbers, ...numbers].join('\n')).error, '')
  assert.match(parseBatchInput([...numbers, 'SF201'].join('\n')).error, /200/)
})
test('空查询、超长单号和超长输入在发送前阻止', () => {
  assert.match(parseBatchInput(' , ；\n').error, /至少/)
  assert.match(parseBatchInput('0'.repeat(101)).error, /100/)
  assert.match(parseBatchInput('A'.repeat(60001)).error, /过长/)
})
test('注册链接带店铺数字且不携带管理页面搜索参数或旧hash', () => {
  assert.equal(
    registrationLink(
      'https://shop.example/app/?token=secret#/shop/members',
      '10000',
    ),
    'https://shop.example/app/#/worker/register?shop=10000',
  )
})
test('注册链接拒绝非网站协议、含账号密码地址和非法店铺号码', () => {
  assert.equal(registrationLink('javascript:alert(1)', '10000'), '')
  assert.equal(
    registrationLink('https://admin:secret@shop.example', '10000'),
    '',
  )
  for (const number of [
    '9999',
    '010000',
    '123-456',
    'UUID',
    '10000&token=secret',
  ])
    assert.equal(registrationLink('https://shop.example', number), '')
})
