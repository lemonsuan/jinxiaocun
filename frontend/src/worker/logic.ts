import type { OrderStatus, WorkerScope } from './types.ts';

export function sameWorkerScope(
  captured: WorkerScope,
  current: WorkerScope,
): boolean {
  return (
    captured.epoch === current.epoch &&
    captured.token === current.token &&
    captured.workerId === current.workerId &&
    captured.shopNumber === current.shopNumber
  );
}

export function validShopNumber(value: string): boolean {
  return (
    /^[1-9]\d{4,18}$/.test(value) &&
    BigInt(value) >= 10000n &&
    BigInt(value) <= 9223372036854775807n
  );
}

export interface ParsedTracking {
  values: string[];
  duplicateCount: number;
  error: string;
}
export function parseTrackingNumbers(
  input: string[],
  max = 20,
): ParsedTracking {
  const tokens = input
    .flatMap((text) => text.split(/[\s,，;；]+/u))
    .map((value) => value.trim())
    .filter(Boolean);
  if (tokens.some((value) => value.length > 100))
    return {
      values: [],
      duplicateCount: 0,
      error: '每个快递单号最多100个字符，请核对后再添加。',
    };
  const values = [...new Set(tokens)];
  if (values.length > max)
    return {
      values: [],
      duplicateCount: tokens.length - values.length,
      error: `一个订单最多填写${max}个不同的快递单号。`,
    };
  return { values, duplicateCount: tokens.length - values.length, error: '' };
}

export function statusText(value: OrderStatus): string {
  return { in_transit: '运输中', arrived: '已到货', settled: '已结算' }[value];
}

export function moneyText(value: string): string {
  if (!/^\d+(\.\d{1,2})?$/.test(value)) return '—';
  const [whole, fraction = ''] = value.split('.');
  return `${whole}.${fraction.padEnd(2, '0')}`;
}

export function dateText(value: string | null | undefined): string {
  if (!value) return '—';
  const date = new Date(value);
  return Number.isNaN(date.getTime())
    ? '—'
    : date.toLocaleString('zh-CN', {
        month: '2-digit',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit',
        hour12: false,
      });
}

export function safeWorkerReturn(value: unknown): string {
  return typeof value === 'string' &&
    /^\/worker\/(jobs|orders)(\/|\?|$)/.test(value)
    ? value
    : '/worker/jobs';
}

export function operationId(): string {
  if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID();
  const bytes = new Uint8Array(16);
  if (globalThis.crypto?.getRandomValues)
    globalThis.crypto.getRandomValues(bytes);
  else
    for (let index = 0; index < bytes.length; index++)
      bytes[index] = Math.floor(Math.random() * 256);
  return [...bytes]
    .map((value) => value.toString(16).padStart(2, '0'))
    .join('');
}
