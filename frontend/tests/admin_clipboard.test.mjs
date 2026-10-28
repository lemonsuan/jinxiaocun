import { test } from 'node:test'
import assert from 'node:assert/strict'
import { copyVisibleText } from '../src/admin/logic.ts'

function clipboard(t, writeText) {
  const original = Object.getOwnPropertyDescriptor(globalThis, 'navigator')
  Object.defineProperty(globalThis, 'navigator', {
    configurable: true,
    value: { clipboard: { writeText } },
  })
  t.after(() => {
    if (original) Object.defineProperty(globalThis, 'navigator', original)
    else delete globalThis.navigator
  })
  return t.mock.method(globalThis, 'clearTimeout')
}

test('复制成功返回true并清理超时计时器', async t => {
  const writes = []
  const clear = clipboard(t, async value => { writes.push(value) })
  assert.equal(await copyVisibleText('店铺注册链接', 100), true)
  assert.deepEqual(writes, ['店铺注册链接'])
  assert.equal(clear.mock.callCount(), 1)
})

test('复制权限被拒绝返回false并清理计时器，供界面手动复制', async t => {
  const clear = clipboard(t, async () => { throw new Error('权限被拒绝') })
  assert.equal(await copyVisibleText('10000', 100), false)
  assert.equal(clear.mock.callCount(), 1)
})

test('浏览器复制请求始终不结束时超时返回false并清理计时器', { timeout: 2000 }, async t => {
  const clear = clipboard(t, () => new Promise(() => {}))
  assert.equal(await copyVisibleText('10000', 5), false)
  assert.equal(clear.mock.callCount(), 1)
})
