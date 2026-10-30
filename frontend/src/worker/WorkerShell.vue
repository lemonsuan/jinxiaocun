<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref, watch } from 'vue';
import { RouterLink, RouterView, useRouter } from 'vue-router';
import { loadWorker } from './api';
import { useWorkerStore } from './store';
import WorkerIcon from './components/WorkerIcon.vue';
const auth = useWorkerStore();
const router = useRouter();
const checking = ref(false);
let controller: AbortController | undefined;
let timer: ReturnType<typeof setInterval> | undefined;
async function checkSession() {
  if (!auth.token || checking.value || document.hidden) return;
  checking.value = true;
  controller = new AbortController();
  try {
    auth.refreshWorker(await loadWorker(controller.signal));
  } catch {
    /* 认证失效由独立请求层清理，临时网络失败保留当前界面。 */
  } finally {
    checking.value = false;
  }
}
function foreground() {
  if (!document.hidden) void checkSession();
}
function logout() {
  auth.logout();
  void router.replace({
    path: '/worker/login',
    query: auth.lastShop ? { shop: auth.lastShop } : {},
  });
}
watch(
  () => auth.token,
  (token) => {
    if (!token)
      void router.replace({
        path: '/worker/login',
        query: auth.lastShop ? { shop: auth.lastShop } : {},
      });
  },
);
onMounted(() => {
  void checkSession();
  timer = setInterval(checkSession, 20000);
  document.addEventListener('visibilitychange', foreground);
});
onBeforeUnmount(() => {
  controller?.abort();
  if (timer) clearInterval(timer);
  document.removeEventListener('visibilitychange', foreground);
});
</script>
<template>
  <div class="worker-app">
    <header class="worker-header">
      <div class="worker-brand">
        <strong>{{ auth.worker?.shop_name || '我的店铺' }}</strong
        ><span class="worker-subtitle"
          >店铺 ID {{ auth.worker?.shop_number }} ·
          {{ auth.worker?.display_name || auth.worker?.username }}</span
        >
      </div>
      <button type="button" class="worker-logout" @click="logout">退出</button>
    </header>
    <main v-if="auth.token" class="worker-main">
      <RouterView :key="auth.epoch" />
    </main>
    <nav
      v-if="auth.token"
      class="worker-navigation"
      aria-label="拍手工作区导航"
    >
      <RouterLink to="/worker/jobs" class="worker-nav-item"
        ><WorkerIcon name="jobs" />作业</RouterLink
      ><RouterLink to="/worker/orders" class="worker-nav-item"
        ><WorkerIcon name="orders" />已做作业</RouterLink
      ><RouterLink to="/worker/profile" class="worker-nav-item"><WorkerIcon name="profile" />我的</RouterLink>
    </nav>
  </div>
</template>
<style src="./worker.css"></style>
