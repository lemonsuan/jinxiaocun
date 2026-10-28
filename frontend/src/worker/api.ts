import { workerPublicRequest, workerRequest } from './request';
import type {
  CreateOrderInput,
  Page,
  UpdateOrderInput,
  WorkerInfo,
  WorkerJob,
  WorkerOrder,
  WorkerSession,
  WorkerShop,
} from './types';

export function lookupShop(shopNumber: string, signal?: AbortSignal) {
  return workerPublicRequest.get<never, WorkerShop>('/shop', {
    params: { shop_number: shopNumber },
    signal,
  });
}
export function loginWorker(data: {
  shop_number: string;
  username: string;
  password: string;
}) {
  return workerPublicRequest.post<never, WorkerSession>('/login', data);
}
export function registerWorker(data: {
  shop_number: string;
  username: string;
  password: string;
  display_name: string;
  phone?: string;
}) {
  return workerPublicRequest.post<never, WorkerSession>('/register', data);
}
export function loadWorker(signal?: AbortSignal) {
  return workerRequest.get<never, WorkerInfo>('/me', { signal });
}
export function loadJobs(
  params: { page: number; page_size: number; q?: string },
  signal?: AbortSignal,
) {
  return workerRequest.get<never, Page<WorkerJob>>('/jobs', { params, signal });
}
export function loadJob(id: string, signal?: AbortSignal) {
  return workerRequest.get<never, WorkerJob>(
    `/jobs/${encodeURIComponent(id)}`,
    { signal },
  );
}
export function loadOrders(
  params: {
    page: number;
    page_size: number;
    job_id?: string;
    status?: string;
    q?: string;
  },
  signal?: AbortSignal,
) {
  return workerRequest.get<never, Page<WorkerOrder>>('/orders', {
    params,
    signal,
  });
}
export function loadOrder(id: string, signal?: AbortSignal) {
  return workerRequest.get<never, WorkerOrder>(
    `/orders/${encodeURIComponent(id)}`,
    { signal },
  );
}
export function createOrder(data: CreateOrderInput) {
  return workerRequest.post<never, WorkerOrder>('/orders', data);
}
export function updateOrder(id: string, data: UpdateOrderInput) {
  return workerRequest.patch<never, WorkerOrder>(
    `/orders/${encodeURIComponent(id)}`,
    data,
  );
}
export function loadJobPhoto(
  jobId: string,
  digest: string,
  signal: AbortSignal,
) {
  return workerRequest.get<never, Blob>(
    `/jobs/${encodeURIComponent(jobId)}/photos/${encodeURIComponent(digest)}`,
    { responseType: 'blob', signal },
  );
}
