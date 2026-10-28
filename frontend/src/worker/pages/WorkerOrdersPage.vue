<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue';
import { RouterLink, useRoute } from 'vue-router';
import { loadOrders } from '../api';
import { isWorkerCancellation, workerError } from '../request';
import { dateText, moneyText } from '../logic';
import WorkerStatus from '../components/WorkerStatus.vue';
import type { WorkerOrder } from '../types';
const route = useRoute();
const rows = ref<WorkerOrder[]>([]);
const total = ref(0);
const page = ref(1);
const query = ref('');
const status = ref('');
const loading = ref(false);
const error = ref('');
const jobId = computed(() =>
  typeof route.query.job === 'string' ? route.query.job : '',
);
const filters = [
  { value: '', label: '全部' },
  { value: 'in_transit', label: '运输中' },
  { value: 'arrived', label: '已到货' },
  { value: 'settled', label: '已结算' },
];
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
    const result = await loadOrders(
      {
        page: requestedPage,
        page_size: 12,
        q: appliedQuery || undefined,
        status: status.value || undefined,
        job_id: jobId.value || undefined,
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
function selectStatus(value: string) {
  status.value = value;
  search();
}
function retry() {
  void fetchRows(lastAppend);
}
function more() {
  void fetchRows(true);
}
watch(
  jobId,
  () => {
    rows.value = [];
    search();
  },
  { immediate: true },
);
onBeforeUnmount(() => controller?.abort());
</script>
<template>
  <div>
    <RouterLink v-if="jobId" class="worker-back" :to="`/worker/jobs/${jobId}`"
      >← 返回作业</RouterLink
    >
    <div class="worker-page-heading">
      <div>
        <h1>我的报单</h1>
        <p class="worker-muted">仅展示自己的订单 · 共 {{ total }} 单</p>
      </div>
      <button class="worker-button ghost" :disabled="loading" @click="search">
        刷新进度
      </button>
    </div>
    <form class="worker-search" @submit.prevent="search">
      <input
        v-model="query"
        class="worker-input"
        type="search"
        aria-label="搜索我的订单或快递"
        placeholder="订单号或快递单号"
        maxlength="100"
      /><button class="worker-button" type="submit" :disabled="loading">
        查询
      </button>
    </form>
    <div class="worker-filter-row" aria-label="订单状态筛选">
      <button
        v-for="filter in filters"
        :key="filter.value"
        class="worker-filter"
        :class="{ active: status === filter.value }"
        :aria-pressed="status === filter.value"
        :disabled="loading"
        @click="selectStatus(filter.value)"
      >
        {{ filter.label }}
      </button>
    </div>
    <div v-if="error" class="worker-error" role="alert">
      {{ error
      }}<button class="worker-button ghost" @click="retry">重试</button>
    </div>
    <div v-if="loading && !rows.length" class="worker-empty">
      正在读取我的报单…
    </div>
    <div v-else-if="!rows.length && !error" class="worker-empty">
      {{
        status || query
          ? '没有符合条件的报单，可以调整筛选条件。'
          : '还没有报单，先打开本店作业填写第一单。'
      }}
      <div class="worker-actions" style="justify-content: center">
        <RouterLink class="worker-button secondary" to="/worker/jobs"
          >查看本店作业</RouterLink
        >
      </div>
    </div>
    <article v-for="order in rows" :key="order.id" class="worker-card">
      <div class="order-title-row">
        <span class="worker-order-number">{{ order.order_number }}</span
        ><WorkerStatus :status="order.status" />
      </div>
      <RouterLink class="order-job-name" :to="`/worker/jobs/${order.job.id}`">{{
        order.job.title
      }}</RouterLink>
      <div class="worker-progress" aria-hidden="true">
        <span
          :style="{
            width: `${order.parcel_count ? (order.arrived_count / order.parcel_count) * 100 : 0}%`,
          }"
        />
      </div>
      <p class="arrival-summary">
        快递已到 <strong>{{ order.arrived_count }}</strong> /
        {{ order.parcel_count }} 件<span v-if="order.status === 'arrived'">
          · 等待管理员结算</span
        >
      </p>
      <div class="worker-parcels">
        <div
          v-for="parcel in order.parcels"
          :key="parcel.id"
          class="worker-parcel"
        >
          <span class="worker-parcel-number">{{ parcel.tracking_number }}</span
          ><span
            class="worker-parcel-state"
            :class="{ arrived: parcel.arrived }"
            >{{ parcel.arrived ? '已到货' : '运输中' }}</span
          >
        </div>
      </div>
      <div v-if="order.status === 'settled'" class="settlement-line">
        已结算返款
        <strong
          >¥{{
            moneyText(
              order.settlement?.refund_amount ?? order.job.refund_amount,
            )
          }}</strong
        >
        · {{ dateText(order.settlement?.settled_at ?? order.settled_at) }}
      </div>
      <div class="order-footer">
        <span>更新于 {{ dateText(order.updated_at) }}</span
        ><RouterLink
          class="worker-button secondary"
          :to="`/worker/orders/${order.id}`"
          >{{
            order.status === 'settled' ? '查看详情' : '查看 / 修改'
          }}</RouterLink
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
.order-title-row {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 10px;
}
.order-title-row > span {
  min-width: 0;
}
.order-job-name {
  display: block;
  font-size: 12px;
  color: #6e8979;
  text-decoration: none;
  margin: 10px 0 0;
  overflow-wrap: anywhere;
}
.arrival-summary {
  font-size: 12px;
  color: #75897b;
  margin: 0;
}
.arrival-summary strong {
  color: #16815a;
}
.order-footer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 9px;
  border-top: 1px solid #edf1ee;
  padding-top: 13px;
  margin-top: 12px;
}
.order-footer > span {
  color: #8a9a8e;
  font-size: 10px;
}
.order-footer a {
  font-size: 12px;
  flex: none;
}
.settlement-line {
  font-size: 12px;
  background: #edf7f0;
  color: #53755d;
  border-radius: 8px;
  padding: 11px;
  line-height: 1.8;
}
.settlement-line strong {
  color: #16724b;
}
</style>
