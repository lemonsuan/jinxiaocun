import axios, { CanceledError, type AxiosError } from 'axios';
import { useWorkerStore } from './store.ts';
import { sameWorkerScope } from './logic.ts';
import type { WorkerScope } from './types';

interface CapturedRequest {
  scope: WorkerScope;
  authenticated: boolean;
}
const captured = new WeakMap<object, CapturedRequest>();
export class WorkerRequestError extends Error {
  status: number;
  outcomeUnknown: boolean;
  constructor(message: string, status = 0, outcomeUnknown = false) {
    super(message);
    this.name = 'WorkerRequestError';
    this.status = status;
    this.outcomeUnknown = outcomeUnknown;
  }
}

async function messageOf(error: AxiosError): Promise<string> {
  let data = error.response?.data;
  if (typeof Blob !== 'undefined' && data instanceof Blob) {
    try {
      data = JSON.parse(await data.text());
    } catch {
      data = null;
    }
  }
  if (data && typeof data === 'object') {
    const value =
      (data as { detail?: unknown; message?: unknown }).detail ??
      (data as { message?: unknown }).message;
    if (typeof value === 'string' && value) return value;
  }
  if (!error.response)
    return error.code === 'ECONNABORTED'
      ? '请求超时，请重试；当前填写内容已保留。'
      : '网络暂时不可用，请检查连接后重试。';
  if (error.response.status === 401) return '登录已过期，请重新登录。';
  if (error.response.status === 403)
    return '此账号目前无法访问，请联系本店管理员。';
  if (error.response.status === 409)
    return '内容已发生变化，请查看最新记录后再保存。';
  if (error.response.status === 400 || error.response.status === 422)
    return '填写内容不符合要求，请核对后重试。';
  if (error.response.status === 404)
    return '没有找到该记录，或你没有查看权限。';
  return '服务暂时不可用，请稍后重试。';
}

function makeClient(authenticated: boolean) {
  const client = axios.create({ baseURL: '/api/worker', timeout: 20000 });
  client.interceptors.request.use((config) => {
    const store = useWorkerStore();
    captured.set(config, { scope: store.scope(), authenticated });
    // 拍手请求不发送管理端令牌，也不携带库存店铺认证头。
    if (authenticated && store.token)
      config.headers.Authorization = `Bearer ${store.token}`;
    return config;
  });
  client.interceptors.response.use(
    (response) => {
      const saved = captured.get(response.config);
      if (!saved || !sameWorkerScope(saved.scope, useWorkerStore().scope()))
        throw new CanceledError('拍手身份已变化');
      return response.data;
    },
    async (error: AxiosError) => {
      if (axios.isCancel(error)) return Promise.reject(error);
      const saved = error.config ? captured.get(error.config) : undefined;
      const store = useWorkerStore();
      if (saved && !sameWorkerScope(saved.scope, store.scope()))
        return Promise.reject(new CanceledError('拍手身份已变化'));
      const status = error.response?.status || 0;
      const message = await messageOf(error);
      if (saved && !sameWorkerScope(saved.scope, store.scope()))
        return Promise.reject(new CanceledError('拍手身份已变化'));
      if (
        saved?.authenticated &&
        (status === 401 ||
          (status === 403 && /禁用|账号|会话|认证|登录/.test(message)))
      )
        store.logout(message);
      return Promise.reject(
        new WorkerRequestError(message, status, !status || status >= 500),
      );
    },
  );
  return client;
}

export const workerRequest = makeClient(true);
export const workerPublicRequest = makeClient(false);
export const isWorkerCancellation = axios.isCancel;
export function workerError(error: unknown): string {
  return error instanceof Error ? error.message : '操作未完成，请稍后重试。';
}
