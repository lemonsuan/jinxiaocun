<script setup lang="ts">
import { onBeforeUnmount, ref } from 'vue';
import { RouterLink } from 'vue-router';
import { loadJobs } from '../api';
import { isWorkerCancellation, workerError } from '../request';
import { moneyText } from '../logic';
import type { WorkerJob } from '../types';
const rows = ref<WorkerJob[]>([]);
const total = ref(0);
const page = ref(1);
const query = ref('');
const loading = ref(false);
const error = ref('');
let controller: AbortController | undefined;
let appliedQuery = '';
let lastAppend = false;
async function fetchRows(append = false) {
  lastAppend = append;
  controller?.abort();
  const current = new AbortController();
  controller = current;
  loading.value = true;
  error.value = '';
  const requestedPage = append ? page.value + 1 : 1;
  try {
    const result = await loadJobs(
      {
        page: requestedPage,
        page_size: 12,
        q: appliedQuery || undefined,
      },
      current.signal,
    );
    if (!current.signal.aborted) {
      rows.value = append ? [...rows.value, ...result.items] : result.items;
      total.value = result.total;
      page.value = requestedPage;
    }
  } catch (failure) {
    if (!isWorkerCancellation(failure)) error.value = workerError(failure);
  } finally {
    if (!current.signal.aborted) loading.value = false;
  }
}
function search() {
  appliedQuery = query.value.trim();
  page.value = 1;
  void fetchRows();
}
function retry() {
  void fetchRows(lastAppend);
}
function more() {
  void fetchRows(true);
}
void fetchRows();
onBeforeUnmount(() => controller?.abort());
</script>
<template>
  <div>
    <div class="worker-page-heading">
      <div>
        <h1>作业</h1>
        <p class="worker-muted">选择作业，填写订单。</p>
      </div>
      <button
        type="button"
        class="worker-button ghost"
        :disabled="loading"
        @click="search"
      >
        刷新
      </button>
    </div>
    <form class="worker-search" @submit.prevent="search">
      <input
        v-model="query"
        class="worker-input"
        type="search"
        aria-label="搜索作业"
        placeholder="搜索作业名称"
        maxlength="100"
      /><button class="worker-button" type="submit" :disabled="loading">
        查询
      </button>
    </form>
    <div v-if="error" class="worker-error" role="alert">
      {{ error }}
      <button class="worker-button ghost" @click="retry">重试</button>
    </div>
    <div v-if="loading && !rows.length" class="worker-empty" role="status">
      正在加载本店作业…
    </div>
    <div v-else-if="!rows.length && !error" class="worker-empty">
      本店暂时没有可查看的作业。<br />管理员发布后，在这里刷新即可。
    </div>
    <article v-for="job in rows" :key="job.id" class="worker-card">
      <div class="job-title-row">
        <h2>{{ job.title }}</h2>
        <span class="job-state" :class="{ closed: job.status === 'closed' }">{{
          job.status === 'open' ? '可直接报单' : '已关闭'
        }}</span>
      </div>
      <p v-if="job.description" class="job-excerpt">{{ job.description }}</p>
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
      <div class="job-footer">
        <span>{{
          job.own_order_count
            ? `我已填写 ${job.own_order_count} 单`
            : '打开作业填写订单'
        }}</span
        ><RouterLink
          :to="`/worker/jobs/${job.id}`"
          class="worker-button secondary"
          >{{ job.status === 'open' ? '查看并报单' : '查看历史' }}
          <span aria-hidden="true">→</span></RouterLink
        >
      </div>
    </article>
    <button
      v-if="rows.length < total"
      class="worker-button secondary wide"
      :disabled="loading"
      @click="more"
    >
      {{ loading ? '加载中…' : `加载更多（已显示 ${rows.length}/${total}）` }}
    </button>
  </div>
</template>
<style scoped>
.job-title-row {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 10px;
}
.job-title-row h2 {
  min-width: 0;
}
.job-state {
  flex: none;
  color: #138257;
  background: #e7f6ed;
  border-radius: 999px;
  padding: 5px 8px;
  font-size: 10px;
  white-space: nowrap;
}
.job-state.closed {
  color: #7f8a83;
  background: #eef1ef;
}
.job-excerpt {
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
  color: #708276;
  font-size: 13px;
  line-height: 1.75;
  margin: 10px 0 0;
  overflow-wrap: anywhere;
}
.job-footer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  border-top: 1px solid #edf1ee;
  padding-top: 14px;
}
.job-footer > span {
  font-size: 11px;
  color: #87978c;
  min-width: 0;
}
.job-footer a {
  flex: none;
  font-size: 12px;
}
</style>
