import { defineStore } from 'pinia';
import { ref } from 'vue';
import type { WorkerInfo, WorkerScope, WorkerSession } from './types.ts';

const TOKEN_KEY = 'worker_token';
const PROFILE_KEY = 'worker_profile';
const SHOP_KEY = 'worker_last_shop';

function readProfile(): WorkerInfo | null {
  try {
    const value = JSON.parse(localStorage.getItem(PROFILE_KEY) || 'null');
    return value &&
      ['id', 'username', 'display_name', 'shop_number', 'shop_name'].every(
        (key) => typeof value[key] === 'string',
      )
      ? value
      : null;
  } catch {
    return null;
  }
}

export const useWorkerStore = defineStore('worker-auth', () => {
  const worker = ref<WorkerInfo | null>(readProfile());
  const token = ref(worker.value ? localStorage.getItem(TOKEN_KEY) || '' : '');
  const lastShop = ref(localStorage.getItem(SHOP_KEY) || '');
  const epoch = ref(0);
  const notice = ref('');

  function scope(): WorkerScope {
    return {
      token: token.value,
      workerId: worker.value?.id || '',
      shopNumber: worker.value?.shop_number || '',
      epoch: epoch.value,
    };
  }
  function setSession(session: WorkerSession) {
    epoch.value++;
    worker.value = session.worker;
    token.value = session.token;
    notice.value = '';
    lastShop.value = session.worker.shop_number;
    localStorage.setItem(TOKEN_KEY, session.token);
    localStorage.setItem(PROFILE_KEY, JSON.stringify(session.worker));
    localStorage.setItem(SHOP_KEY, session.worker.shop_number);
  }
  function refreshWorker(value: WorkerInfo) {
    if (
      !worker.value ||
      value.id !== worker.value.id ||
      value.shop_number !== worker.value.shop_number
    )
      return;
    worker.value = value;
    localStorage.setItem(PROFILE_KEY, JSON.stringify(value));
  }
  function rememberShop(value: string) {
    lastShop.value = value;
    localStorage.setItem(SHOP_KEY, value);
  }
  function logout(message = '') {
    epoch.value++;
    token.value = '';
    worker.value = null;
    notice.value = message;
    localStorage.removeItem(TOKEN_KEY);
    localStorage.removeItem(PROFILE_KEY);
  }
  return {
    worker,
    token,
    epoch,
    lastShop,
    notice,
    scope,
    setSession,
    refreshWorker,
    rememberShop,
    logout,
  };
});
