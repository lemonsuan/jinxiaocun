import type { OrderStatus, WorkerScope } from './types.ts';

/**
 * 校验当前正在消费的网络请求上下文与捕获时的拍手会话作用域是否完全一致。
 *
 * 用于防止慢速网络环境下，用户切换拍手账号或更换店铺后，迟到的上一个账号响应污染当前界面。
 */
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

/**
 * 校验店铺数字编号是否合法（5~19位正整数字符串，且满足 PostgreSQL BIGINT 正数范围）。
 */
export function validShopNumber(value: string): boolean {
  return (
    /^[1-9]\d{4,18}$/.test(value) &&
    BigInt(value) >= 10000n &&
    BigInt(value) <= 9223372036854775807n
  );
}

/**
 * 拍手端快递单号解析结果。
 */
export interface ParsedTracking {
  /** 解析去重后的快递单号列表 */
  values: string[];
  /** 输入中被去重过滤掉的重复项数量 */
  duplicateCount: number;
  /** 校验错误原因提示（若有） */
  error: string;
}

/**
 * 解析并校验拍手提交的一组快递单号字符串（支持多行或任意中英文标点分隔）。
 *
 * @param input 原始文本项数组
 * @param max 单个报单允许的最大快递数量上限（默认 20 个）
 */
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

/**
 * 将订单流转枚举状态格式化为人类可读的中文标签。
 */
export function statusText(value: OrderStatus): string {
  return { in_transit: '运输中', arrived: '已到货', settled: '已结算' }[value];
}

/**
 * 将金额格式化为标准的两位小数十进制金额文本（不产生 NaN 或浮点精度抖动）。
 */
export function moneyText(value: string): string {
  if (!/^\d+(\.\d{1,2})?$/.test(value)) return '—';
  const [whole, fraction = ''] = value.split('.');
  return `${whole}.${fraction.padEnd(2, '0')}`;
}

/**
 * 将 ISO 日期字符串格式化为适合手机端紧凑展示的中文月日时分。
 */
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

/**
 * 校验登录成功后的返回目标路径，严格防范跨站重定向与跳转逃逸。
 */
export function safeWorkerReturn(value: unknown): string {
  return typeof value === 'string' &&
    /^\/worker\/(jobs|orders|profile)(\/|\?|$)/.test(value)
    ? value
    : '/worker/jobs';
}

/**
 * 生成具备全局唯一性的幂等操作标识（UUIDv4），用于防范报单重复提交。
 */
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

/** 拍手使用业务文字，底层仍沿用三态契约。 */
export function workerStatusText(value: OrderStatus): string {
  return { in_transit: '运输中', arrived: '已签收待返款', settled: '已返款' }[value];
}
