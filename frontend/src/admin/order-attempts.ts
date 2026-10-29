import { settlementInput } from './order-actions.ts';
import type { AdminOrder } from './types.ts';

export type AdminOrderAttempt = {
  orderId: string;
  orderNumber: string;
} & (
  | { action: 'settle'; input: ReturnType<typeof settlementInput> }
  | { action: 'reopen'; input: { expected_version: number; operation_id: string; reason: string } }
);

/** 仅保存提交参数，不保存令牌、照片、收款资料或整份业务快照。 */
export function attemptStorageKey(username: string, shopId: string) {
  return `admin-order-attempt:${JSON.stringify([username, shopId])}`;
}

export function settlementAttempt(order: AdminOrder, key: string): AdminOrderAttempt {
  return JSON.parse(JSON.stringify({
    action: 'settle', orderId: order.id, orderNumber: order.order_number,
    input: settlementInput(order, key),
  })) as AdminOrderAttempt;
}

export function readOrderAttempt(storage: Pick<Storage, 'getItem'>, key: string): AdminOrderAttempt | null {
  try {
    const value = JSON.parse(storage.getItem(key) || 'null') as AdminOrderAttempt | null;
    if (!value || typeof value.orderId !== 'string' || typeof value.orderNumber !== 'string' ||
      !value.input || !Number.isInteger(value.input.expected_version) ||
      value.input.expected_version < 0 || typeof value.input.operation_id !== 'string' ||
      !value.input.operation_id) return null;
    if (value.action === 'reopen') return typeof value.input.reason === 'string' ? value : null;
    if (value.action !== 'settle' || !Number.isInteger(value.input.expected_job_version) ||
      value.input.expected_job_version < 1 || !Number.isInteger(value.input.expected_payout_version) ||
      value.input.expected_payout_version < 0 || !Array.isArray(value.input.evidence) ||
      value.input.evidence.some((item) => typeof item.tracking_number !== 'string' ||
        typeof item.receipt_id !== 'string' || !Number.isInteger(item.revision))) return null;
    return value;
  } catch { return null; }
}
