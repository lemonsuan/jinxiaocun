<script setup lang="ts">
import WorkerIcon from '../components/WorkerIcon.vue';
import { onBeforeUnmount, ref, watch } from 'vue';
import { RouterLink, useRoute, useRouter } from 'vue-router';
import { loadJob, loadOrder } from '../api';
import { isWorkerCancellation, workerError } from '../request';
import type { WorkerJob, WorkerOrder } from '../types';
import WorkerOrderModal from '../components/WorkerOrderModal.vue';
const route = useRoute(), router = useRouter();
const job = ref<WorkerJob | WorkerOrder['job'] | null>(null), orderId = ref<string>(), error = ref(''), opened = ref(true);
let controller: AbortController | undefined;
async function load() {
  controller?.abort(); const current = controller = new AbortController();
  job.value = null; error.value = ''; opened.value = true;
  try {
    if (route.params.orderId) { const order = await loadOrder(String(route.params.orderId), current.signal); if (!current.signal.aborted) { job.value = order.job; orderId.value = order.id; } }
    else if (typeof route.query.job === 'string') { const value = await loadJob(route.query.job, current.signal); if (!current.signal.aborted) { job.value = value; orderId.value = undefined; } }
    else error.value = '请先选择作业再填报。';
  } catch (failure) { if (!isWorkerCancellation(failure)) error.value = workerError(failure); }
}
function close() { opened.value = false; void router.replace(job.value ? `/worker/jobs/${job.value.id}` : '/worker/orders'); }
watch(() => route.fullPath, load, { immediate: true });
onBeforeUnmount(() => controller?.abort());
</script>
<template><div><RouterLink class="worker-back" to="/worker/orders"><WorkerIcon name="back" />已做作业</RouterLink><p v-if="error" class="worker-error">{{ error }}</p><p v-else class="worker-empty">正在打开填报窗口…</p><WorkerOrderModal v-if="job && opened" :key="route.fullPath" :model-value="true" :job="job" :order-id="orderId" @update:model-value="close" /></div></template>
