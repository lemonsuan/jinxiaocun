<script setup lang="ts">
import { onBeforeUnmount, ref, watch } from 'vue';
import { RouterLink, useRoute } from 'vue-router';
import { loadJob, loadOrders } from '../api';
import { isWorkerCancellation, workerError } from '../request';
import { moneyText } from '../logic';
import { orderDraftKey, readOrderDraft } from '../drafts';
import { useWorkerStore } from '../store';
import type { WorkerJob, WorkerOrder } from '../types';
import WorkerModal from '../components/WorkerModal.vue';
import WorkerOrderModal from '../components/WorkerOrderModal.vue';
import WorkerOrderList from '../components/WorkerOrderList.vue';
const route = useRoute();
const auth = useWorkerStore();
const job = ref<WorkerJob | null>(null), rows = ref<WorkerOrder[]>([]);
const total = ref(0), page = ref(1), loading = ref(false), error = ref('');
const details = ref(false), reporting = ref(false);
const pendingReport = ref(false);
let controller: AbortController | undefined;
async function load(append = false) {
  controller?.abort(); const current = controller = new AbortController();
  loading.value = true; error.value = '';
  const id = String(route.params.jobId), next = append ? page.value + 1 : 1;
  try {
    const [value, orders] = await Promise.all([loadJob(id, current.signal), loadOrders({ job_id: id, page: next, page_size: 20 }, current.signal)]);
    if (current.signal.aborted) return;
    job.value = value; rows.value = append ? [...rows.value, ...orders.items] : orders.items; total.value = orders.total; page.value = next;
    const saved = readOrderDraft(orderDraftKey(auth.scope(), id))?.attempt;
    pendingReport.value = !!saved && 'job_id' in saved && saved.job_id === id;
  } catch (failure) { if (!isWorkerCancellation(failure)) error.value = workerError(failure); }
  finally { if (!current.signal.aborted) loading.value = false; }
}
watch(() => route.params.jobId, () => { job.value = null; rows.value = []; reporting.value = details.value = false; void load(); }, { immediate: true });
onBeforeUnmount(() => controller?.abort());
</script>
<template>
  <div class="worker-job-page">
    <RouterLink class="worker-back" to="/worker/jobs">← 作业列表</RouterLink>
    <p v-if="error" class="worker-error" role="alert">{{ error }}<button class="worker-button ghost" @click="load()">重试</button></p>
    <div v-if="job" class="worker-card worker-job-content">
      <h1 class="worker-job-title">{{ job.title }}</h1>
      <button type="button" class="worker-detail-strip" @click="details = true"><span>查看作业详情</span><span aria-hidden="true">›</span></button>
      <div class="worker-section-heading"><h2>已填报订单 <small>{{ total }}</small></h2><button class="worker-button ghost" :disabled="loading" @click="load()">刷新</button></div>
      <WorkerOrderList :orders="rows" @saved="load()" />
      <p v-if="!rows.length" class="worker-empty">{{ loading ? '正在加载…' : '还没有填报，点击下方按钮填写第一单。' }}</p>
      <button v-if="rows.length < total" class="worker-button secondary wide" :disabled="loading" @click="load(true)">{{ loading ? '加载中…' : '加载更多订单' }}</button>
    </div>
    <p v-else-if="loading" class="worker-empty">正在加载作业…</p>
    <div v-if="job" class="worker-report-bar"><button class="worker-button wide" :disabled="!pendingReport && (job.status !== 'open' || job.can_report === false)" @click="reporting = true">{{ pendingReport ? '确认上次填报结果' : job.status === 'open' ? '填报作业' : '作业已关闭' }}</button></div>
    <WorkerModal v-if="job" v-model="details" :title="job.title" detail><div class="worker-money"><div><span>作业成本</span><strong>¥{{ moneyText(job.cost_amount) }}</strong></div><div><span>返款金额</span><strong>¥{{ moneyText(job.refund_amount) }}</strong></div></div><p class="worker-job-description">{{ job.description || '暂无补充说明。' }}</p></WorkerModal>
    <WorkerOrderModal v-if="job && reporting" :model-value="true" :job="job" @update:model-value="reporting = false" @saved="load()" />
  </div>
</template>
