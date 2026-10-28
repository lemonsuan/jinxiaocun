<script setup lang="ts">
import { onBeforeUnmount, ref, watch } from 'vue';
import { RouterLink, useRoute } from 'vue-router';
import { loadJob } from '../api';
import WorkerPhoto from '../components/WorkerPhoto.vue';
import { isWorkerCancellation, workerError } from '../request';
import { moneyText } from '../logic';
import type { WorkerJob } from '../types';
const route = useRoute();
const job = ref<WorkerJob | null>(null);
const loading = ref(false);
const error = ref('');
let controller: AbortController | undefined;
async function load() {
  controller?.abort();
  const current = new AbortController();
  controller = current;
  job.value = null;
  loading.value = true;
  error.value = '';
  try {
    const result = await loadJob(String(route.params.jobId), current.signal);
    if (!current.signal.aborted) job.value = result;
  } catch (failure) {
    if (!isWorkerCancellation(failure)) error.value = workerError(failure);
  } finally {
    if (!current.signal.aborted) loading.value = false;
  }
}
watch(() => route.params.jobId, load, { immediate: true });
onBeforeUnmount(() => controller?.abort());
</script>
<template>
  <div>
    <RouterLink class="worker-back" to="/worker/jobs"
      >← 返回本店作业</RouterLink
    >
    <div v-if="loading" class="worker-empty">正在加载作业…</div>
    <div v-else-if="error" class="worker-error" role="alert">
      {{ error
      }}<button class="worker-button ghost" @click="load">重新加载</button>
    </div>
    <template v-if="job">
      <div class="worker-page-heading">
        <div>
          <h1>{{ job.title }}</h1>
          <p class="worker-muted">
            {{
              job.status === 'open'
                ? '本店作业 · 可直接填写订单'
                : '作业已关闭 · 仍可查看自己的历史报单'
            }}
          </p>
        </div>
      </div>
      <section class="worker-card">
        <div class="worker-money">
          <div>
            <span>作业成本</span
            ><strong>¥{{ moneyText(job.cost_amount) }}</strong>
          </div>
          <div>
            <span>返款金额</span
            ><strong>¥{{ moneyText(job.refund_amount) }}</strong>
          </div>
        </div>
        <p class="job-description">
          {{
            job.description ||
            '管理员暂未填写额外说明，请按本作业要求填写订单与快递单号。'
          }}
        </p>
      </section>
      <section v-if="job.photos.length" class="job-photos">
        <h2>作业参考照片</h2>
        <p class="worker-muted">点击照片可放大查看。</p>
        <WorkerPhoto
          v-for="photo in job.photos"
          :key="photo.sha256"
          :job-id="job.id"
          :digest="photo.sha256"
        />
      </section>
      <div class="worker-card">
        <h2>我的订单与快递</h2>
        <p class="worker-muted">
          只能查看自己的报单。每个订单可填写多个快递号，全部入库后显示已到货，管理员确认后显示已结算。
        </p>
        <div class="worker-actions">
          <RouterLink
            class="worker-button secondary"
            :to="{ path: '/worker/orders', query: { job: job.id } }"
            >查看我的报单</RouterLink
          ><RouterLink
            v-if="job.status === 'open' && job.can_report !== false"
            class="worker-button"
            :to="{ path: '/worker/orders/new', query: { job: job.id } }"
            >＋ 直接报单</RouterLink
          >
        </div>
      </div>
      <div v-if="job.status === 'closed'" class="worker-info">
        此作业已关闭，不再接收新报单。自己的未结算订单仍可补充或修改快递号。
      </div>
    </template>
  </div>
</template>
<style scoped>
.job-description {
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  color: #5d7466;
  line-height: 1.9;
  font-size: 14px;
  border-top: 1px solid #edf1ee;
  padding-top: 16px;
  margin: 5px 0 0;
}
.job-photos {
  display: flex;
  flex-direction: column;
  gap: 13px;
  margin: 22px 0;
}
.job-photos h2 {
  font-size: 15px;
  font-weight: 700;
}
.job-photos .worker-muted {
  margin: 0;
}
</style>
