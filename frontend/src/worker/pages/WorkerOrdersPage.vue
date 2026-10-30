<script setup lang="ts">
import WorkerIcon from '../components/WorkerIcon.vue';
import { onBeforeUnmount, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import { loadOrders, loadOrderSummary } from '../api';
import { isWorkerCancellation, workerError } from '../request';
import type { WorkerOrder, WorkerOrderSummary } from '../types';
import WorkerOrderList from '../components/WorkerOrderList.vue';
const route = useRoute();
const rows = ref<WorkerOrder[]>([]), summary = ref<WorkerOrderSummary | null>(null);
const total = ref(0), page = ref(1), query = ref(''), loading = ref(false), error = ref('');
let controller: AbortController | undefined;
let appliedQuery = '';
async function load(append = false) {
  controller?.abort(); const current = controller = new AbortController();
  loading.value = true; error.value = '';
  const next = append ? page.value + 1 : 1;
  try {
    const [result, stats] = await Promise.all([loadOrders({ page: next, page_size: 20, q: appliedQuery || undefined, job_id: typeof route.query.job === 'string' ? route.query.job : undefined }, current.signal), loadOrderSummary(current.signal)]);
    if (current.signal.aborted) return;
    rows.value = append ? [...rows.value, ...result.items] : result.items; total.value = result.total; page.value = next; summary.value = stats;
  } catch (failure) { if (!isWorkerCancellation(failure)) error.value = workerError(failure); }
  finally { if (!current.signal.aborted) loading.value = false; }
}
function search() { appliedQuery = query.value.trim(); void load(); }
watch(() => route.query.job, () => { rows.value = []; void load(); }, { immediate: true });
onBeforeUnmount(() => controller?.abort());
</script>
<template>
  <div>
    <div class="worker-summary" aria-label="全部已做作业统计"><div><strong>{{ summary?.in_transit ?? '—' }}</strong><span>运输中</span></div><div><strong>{{ summary?.arrived ?? '—' }}</strong><span>已签收等待返款</span></div><div><strong>{{ summary?.total ?? '—' }}</strong><span>总量</span></div></div>
    <div class="worker-section-heading"><h1>已做作业</h1><button type="button" class="worker-icon-button" aria-label="刷新已做作业" title="刷新已做作业" :disabled="loading" @click="load()"><WorkerIcon name="refresh" /></button></div>
    <form class="worker-search" @submit.prevent="search"><input v-model="query" class="worker-input" type="search" aria-label="搜索订单或快递号" placeholder="订单号 / 快递单号" maxlength="100" /><button class="worker-button" :disabled="loading">查询</button></form>
    <p v-if="route.query.job" class="worker-muted">当前列表仅显示所选作业，顶部数量为本人全部订单。</p>
    <p v-if="error" class="worker-error" role="alert">{{ error }}<button class="worker-button ghost" @click="load()">重试</button></p>
    <WorkerOrderList :orders="rows" show-job @saved="load()" />
    <p v-if="!rows.length && !error" class="worker-empty">{{ loading ? '正在加载…' : '暂无订单，去作业页面填写第一单吧。' }}</p>
    <button v-if="rows.length < total" class="worker-button secondary wide" :disabled="loading" @click="load(true)">{{ loading ? '加载中…' : '加载更多订单' }}</button>
  </div>
</template>
