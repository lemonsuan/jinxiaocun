import type { CreateOrderInput, UpdateOrderInput, WorkerMedia, WorkerScope } from './types.ts';

const PREFIX = 'worker_order_draft_v1:';
const DIGEST = /^[a-f0-9]{64}$/;
export interface PendingPhoto { id: string; name: string }
export interface WorkerOrderDraft {
  orderNumber: string;
  trackingText: string;
  note: string;
  photos: WorkerMedia[];
  pendingPhotos: PendingPhoto[];
  attempt: CreateOrderInput | UpdateOrderInput | null;
}
function storage(): Storage | undefined {
  try { return typeof sessionStorage === 'undefined' ? undefined : sessionStorage; }
  catch { return undefined; }
}
export function orderDraftKey(scope: WorkerScope, jobId: string, orderId?: string): string {
  return `${PREFIX}${encodeURIComponent(scope.shopNumber)}:${encodeURIComponent(scope.workerId)}:${encodeURIComponent(jobId)}:${encodeURIComponent(orderId || 'new')}`;
}
function validAttempt(value: unknown): value is CreateOrderInput | UpdateOrderInput {
  if (!value || typeof value !== 'object') return false;
  const x = value as Record<string, unknown>;
  return typeof x.order_number === 'string' && x.order_number.length <= 100 &&
    typeof x.operation_id === 'string' && x.operation_id.length > 0 && x.operation_id.length <= 100 &&
    Array.isArray(x.tracking_numbers) && x.tracking_numbers.length >= 1 && x.tracking_numbers.length <= 20 &&
    x.tracking_numbers.every(n => typeof n === 'string' && n.length > 0 && n.length <= 100) &&
    (typeof x.job_id === 'string' || (Number.isInteger(x.expected_version) && Number(x.expected_version) > 0)) &&
    (x.note === undefined || (typeof x.note === 'string' && x.note.length <= 2000)) &&
    (x.photo_sha256s === undefined || (Array.isArray(x.photo_sha256s) && x.photo_sha256s.length <= 10 && x.photo_sha256s.every(n => typeof n === 'string' && DIGEST.test(n))));
}
export function readOrderDraft(key: string): WorkerOrderDraft | null {
  try {
    const raw = storage()?.getItem(key);
    if (!raw || raw.length > 30000) return null;
    const x = JSON.parse(raw);
    if (typeof x.orderNumber !== 'string' || x.orderNumber.length > 100 ||
      typeof x.trackingText !== 'string' || x.trackingText.length > 5000 ||
      typeof x.note !== 'string' || x.note.length > 2000 ||
      !Array.isArray(x.photos) || !Array.isArray(x.pendingPhotos) || x.photos.length + x.pendingPhotos.length > 10 ||
      !x.photos.every((p: WorkerMedia) => typeof p?.sha256 === 'string' && DIGEST.test(p.sha256) && typeof p.name === 'string' && p.name.length <= 255) ||
      !x.pendingPhotos.every((p: PendingPhoto) => typeof p?.id === 'string' && typeof p.name === 'string' && p.name.length <= 255) ||
      (x.attempt !== null && !validAttempt(x.attempt))) return null;
    // 仅恢复明确字段，草稿不能夹带令牌、收款资料或其他账号信息。
    return { orderNumber: x.orderNumber, trackingText: x.trackingText, note: x.note,
      photos: x.photos.map((p: WorkerMedia) => ({ sha256: p.sha256, name: p.name })),
      pendingPhotos: x.pendingPhotos.map((p: PendingPhoto) => ({ id: p.id, name: p.name })),
      attempt: x.attempt ? { order_number: x.attempt.order_number, tracking_numbers: x.attempt.tracking_numbers,
        operation_id: x.attempt.operation_id, note: x.attempt.note, photo_sha256s: x.attempt.photo_sha256s,
        ...(x.attempt.job_id ? { job_id: x.attempt.job_id } : { expected_version: x.attempt.expected_version }) } : null };
  } catch { return null; }
}
export function saveOrderDraft(key: string, draft: WorkerOrderDraft): boolean {
  try {
    const target = storage();
    if (!target) return false;
    target.setItem(key, JSON.stringify(draft));
    return true;
  } catch { return false; }
}
export function removeOrderDraft(key: string) { try { storage()?.removeItem(key); } catch { /* 禁用存储时不阻断提交结果。 */ } }
export function clearWorkerDrafts(scope: WorkerScope) {
  const start = `${PREFIX}${encodeURIComponent(scope.shopNumber)}:${encodeURIComponent(scope.workerId)}:`;
  try {
    const target = storage();
    if (!target) return;
    for (let i = target.length - 1; i >= 0; i--) {
      const key = target.key(i);
      if (key?.startsWith(start)) target.removeItem(key);
    }
  } catch { /* 隐私模式拒绝存储时仍允许退出。 */ }
}
