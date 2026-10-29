import request from '../utils/request';
import { settlementInput } from './order-actions';
import type { Page } from '../worker/types';
import type {
  AdminJob,
  AdminOrder,
  AdminWorker,
  JobInput,
  Member,
} from './types';
export function listJobs(
  params: { page: number; page_size: number; q?: string; status?: string },
  signal?: AbortSignal,
) {
  return request.get<never, Page<AdminJob>>('/api/jobs', { params, signal });
}
export function getJob(id: string, signal?: AbortSignal) {
  return request.get<never, AdminJob>(`/api/jobs/${encodeURIComponent(id)}`, {
    signal,
  });
}
export function saveJob(input: JobInput, id?: string, version?: number) {
  return id
    ? request.patch<never, AdminJob>(`/api/jobs/${encodeURIComponent(id)}`, {
        ...input,
        expected_version: version,
      })
    : request.post<never, AdminJob>('/api/jobs', input);
}
export function uploadJobPhoto(file: File) {
  const data = new FormData();
  data.append('file', file);
  return request.post<
    never,
    { sha256: string; size: number; content_type: string }
  >('/api/jobs/media', data, { timeout: 60000 });
}
export function listOrders(
  params: {
    page: number;
    page_size: number;
    q?: string;
    status?: string;
    job_id?: string;
    worker_id?: string;
  },
  signal?: AbortSignal,
) {
  return request.get<never, Page<AdminOrder>>('/api/jobs/orders', {
    params,
    signal,
  });
}
export function getOrder(id: string, signal?: AbortSignal) {
  return request.get<never, AdminOrder>(
    `/api/jobs/orders/${encodeURIComponent(id)}`,
    { signal },
  );
}
export function settleOrder(order: AdminOrder, operationId: string) {
  return request.post<never, AdminOrder>(
    `/api/jobs/orders/${encodeURIComponent(order.id)}/settle`,
    settlementInput(order, operationId),
  );
}
export function reopenOrder(
  order: AdminOrder,
  operationId: string,
  reason: string,
) {
  return request.post<never, AdminOrder>(
    `/api/jobs/orders/${encodeURIComponent(order.id)}/reopen`,
    { expected_version: order.version, operation_id: operationId, reason },
  );
}
export function listWorkers(
  params: { page: number; page_size: number; q?: string; enabled?: boolean },
  signal?: AbortSignal,
) {
  return request.get<never, Page<AdminWorker>>('/api/jobs/workers', {
    params,
    signal,
  });
}
export function setWorkerEnabled(worker: AdminWorker, enabled: boolean) {
  return request.post<never, AdminWorker>(
    `/api/jobs/workers/${encodeURIComponent(worker.id)}/enabled`,
    { enabled, expected_version: worker.version },
  );
}
export function resetWorkerPassword(worker: AdminWorker, password: string) {
  return request.post<never, AdminWorker>(
    `/api/jobs/workers/${encodeURIComponent(worker.id)}/password`,
    { new_password: password, expected_version: worker.version },
  );
}
export function listMembers(signal?: AbortSignal) {
  return request.get<never, Member[]>('/api/shops/members', { signal });
}
export function setMemberStatus(member: Member, status: Member['status']) {
  return request.post('/api/shops/members/update', {
    membership_id: member.id,
    status,
  });
}
