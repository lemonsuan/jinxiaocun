<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue';
import {
  RouterLink,
  onBeforeRouteLeave,
  useRoute,
  useRouter,
} from 'vue-router';
import { createOrder, loadJob, loadOrder, updateOrder } from '../api';
import {
  WorkerRequestError,
  isWorkerCancellation,
  workerError,
} from '../request';
import { useWorkerStore } from '../store';
import {
  dateText,
  moneyText,
  operationId,
  parseTrackingNumbers,
} from '../logic';
import WorkerStatus from '../components/WorkerStatus.vue';
import type {
  CreateOrderInput,
  UpdateOrderInput,
  WorkerJob,
  WorkerOrder,
} from '../types';
const route = useRoute();
const router = useRouter();
const auth = useWorkerStore();
const creating = computed(() => route.path.endsWith('/new'));
const order = ref<WorkerOrder | null>(null);
const job = ref<WorkerJob | WorkerOrder['job'] | null>(null);
const orderNumber = ref('');
const tracking = ref<string[]>(['']);
const bulk = ref('');
const error = ref('');
const info = ref('');
const loading = ref(false);
const saving = ref(false);
const newest = ref<WorkerOrder | null>(null);
const conflict = ref(false);
const checkingLatest = ref(false);
const attempt = ref<CreateOrderInput | UpdateOrderInput | null>(null);
const original = ref('');
const locked = computed(() => order.value?.status === 'settled');
const disabled = computed(
  () => saving.value || locked.value || !!attempt.value,
);
const changed = computed(
  () =>
    JSON.stringify([orderNumber.value, tracking.value]) !== original.value ||
    !!bulk.value.trim(),
);
let controller: AbortController | undefined;
let alive = true;
let savedDestination = '';
function rememberOriginal() {
  original.value = JSON.stringify([orderNumber.value, tracking.value]);
}
function adopt(value: WorkerOrder) {
  order.value = value;
  job.value = value.job;
  orderNumber.value = value.order_number;
  tracking.value = value.parcels.map((parcel) => parcel.tracking_number);
  if (!tracking.value.length) tracking.value = [''];
  rememberOriginal();
}
async function initialize() {
  controller?.abort();
  controller = new AbortController();
  loading.value = true;
  error.value = '';
  info.value = '';
  attempt.value = null;
  conflict.value = false;
  newest.value = null;
  order.value = null;
  job.value = null;
  orderNumber.value = '';
  tracking.value = [''];
  rememberOriginal();
  const current = controller;
  try {
    if (creating.value) {
      const id = typeof route.query.job === 'string' ? route.query.job : '';
      if (!id) {
        error.value = '请先选择一个作业再填写订单。';
        return;
      }
      const value = await loadJob(id, current.signal);
      if (!current.signal.aborted) {
        job.value = value;
        if (value.status !== 'open' || value.can_report === false)
          error.value = '该作业已关闭，暂不接收新报单。';
      }
    } else {
      const value = await loadOrder(
        String(route.params.orderId),
        current.signal,
      );
      if (!current.signal.aborted) adopt(value);
    }
  } catch (failure) {
    if (!isWorkerCancellation(failure)) error.value = workerError(failure);
  } finally {
    if (!current.signal.aborted) loading.value = false;
  }
}
function addRow() {
  if (!disabled.value && tracking.value.length < 20) tracking.value.push('');
}
function removeRow(index: number) {
  if (!disabled.value) {
    tracking.value.splice(index, 1);
    if (!tracking.value.length) tracking.value.push('');
  }
}
function addBulk() {
  const parsed = parseTrackingNumbers([...tracking.value, bulk.value]);
  if (parsed.error) {
    error.value = parsed.error;
    return;
  }
  tracking.value = parsed.values.length ? parsed.values : [''];
  bulk.value = '';
  error.value = '';
  info.value = parsed.duplicateCount
    ? `已去除 ${parsed.duplicateCount} 个重复快递号。`
    : '快递单号已加入下方列表。';
}
async function save() {
  if (saving.value || locked.value || !job.value) return;
  if (creating.value && job.value.status !== 'open') return;
  error.value = '';
  info.value = '';
  if (!attempt.value) {
    if (!orderNumber.value.trim()) {
      error.value = '请填写订单号。';
      return;
    }
    if (orderNumber.value.trim().length > 100) {
      error.value = '订单号最多100个字符。';
      return;
    }
    const parsed = parseTrackingNumbers([...tracking.value, bulk.value]);
    if (parsed.error) {
      error.value = parsed.error;
      return;
    }
    if (!parsed.values.length) {
      error.value = '请至少填写一个快递单号。';
      return;
    }
    tracking.value = parsed.values;
    bulk.value = '';
    const common = {
      order_number: orderNumber.value.trim(),
      tracking_numbers: parsed.values,
      operation_id: operationId(),
    };
    attempt.value = creating.value
      ? { ...common, job_id: job.value.id }
      : { ...common, expected_version: order.value!.version };
  }
  saving.value = true;
  try {
    const result = creating.value
      ? await createOrder(attempt.value as CreateOrderInput)
      : await updateOrder(order.value!.id, attempt.value as UpdateOrderInput);
    if (!alive) return;
    attempt.value = null;
    conflict.value = false;
    adopt(result);
    if (creating.value) {
      savedDestination = `/worker/orders/${result.id}`;
      await router.replace(savedDestination);
      savedDestination = '';
    } else info.value = '订单已保存，快递进度会随本店入库同步更新。';
  } catch (failure) {
    if (!alive || isWorkerCancellation(failure)) return;
    error.value = workerError(failure);
    if (failure instanceof WorkerRequestError && !failure.outcomeUnknown)
      attempt.value = null;
    if (
      failure instanceof WorkerRequestError &&
      failure.status === 409 &&
      !creating.value
    )
      conflict.value = true;
  } finally {
    if (alive) saving.value = false;
  }
}
async function fetchLatest() {
  if (!order.value || checkingLatest.value) return;
  checkingLatest.value = true;
  try {
    newest.value = await loadOrder(order.value.id);
  } catch (failure) {
    if (!isWorkerCancellation(failure)) error.value = workerError(failure);
  } finally {
    checkingLatest.value = false;
  }
}
function useServer() {
  if (newest.value) adopt(newest.value);
  newest.value = null;
  conflict.value = false;
  attempt.value = null;
  error.value = '';
  info.value = '已采用服务器最新记录。';
}
function keepMine() {
  if (!newest.value) return;
  if (newest.value.status === 'settled') {
    error.value = '该订单已结算，不能覆盖修改。请联系本店管理员。';
    return;
  }
  order.value = newest.value;
  job.value = newest.value.job;
  newest.value = null;
  attempt.value = null;
  conflict.value = false;
  error.value = '';
  info.value = '已确认保留当前输入，请再次核对后点击保存。';
}
async function copyNumber(value: string) {
  try {
    await navigator.clipboard.writeText(value);
    info.value = '快递单号已复制。';
  } catch {
    info.value = '当前浏览器不支持自动复制，可长按快递单号选择复制。';
  }
}
onBeforeRouteLeave((to) => {
  if (to.path === savedDestination) return true;
  if (!auth.token) return true;
  if (
    attempt.value &&
    !window.confirm(
      '上次保存结果尚未确认，离开后请在我的报单核对。确定离开吗？',
    )
  )
    return false;
  if (saving.value) return false;
  if (
    changed.value &&
    !locked.value &&
    !attempt.value &&
    !window.confirm('当前修改还没有保存，确定离开吗？')
  )
    return false;
  return true;
});
watch(
  () => [route.params.orderId, route.query.job, creating.value],
  initialize,
  { immediate: true },
);
onBeforeUnmount(() => {
  alive = false;
  controller?.abort();
});
</script>
<template>
  <div>
    <RouterLink
      class="worker-back"
      :to="
        job
          ? { path: '/worker/orders', query: { job: job.id } }
          : '/worker/orders'
      "
      >← 返回我的报单</RouterLink
    >
    <div v-if="loading" class="worker-empty">正在打开订单…</div>
    <template v-else>
      <div class="worker-page-heading">
        <div>
          <h1>{{ creating ? '填写订单' : '订单详情' }}</h1>
          <p v-if="job" class="worker-muted">{{ job.title }}</p>
        </div>
        <WorkerStatus v-if="order" :status="order.status" />
      </div>
      <div v-if="locked" class="worker-info">
        此订单已结算，订单号和快递号已锁定。如需更正，请联系管理员。<br />结算返款
        ¥{{
          moneyText(
            order?.settlement?.refund_amount ?? job?.refund_amount ?? '',
          )
        }}
        · {{ dateText(order?.settlement?.settled_at ?? order?.settled_at) }}
      </div>
      <div v-if="attempt" class="worker-info" role="status">
        上次保存结果尚未确认，填写内容已保留。请先点击“确认上次保存结果”，确认前暂不修改内容，避免重复报单。
      </div>
      <div v-if="error" class="worker-error" role="alert">{{ error }}</div>
      <div v-if="info" class="worker-info" role="status">{{ info }}</div>
      <section v-if="job" class="worker-card">
        <label class="worker-field"
          ><span>订单号</span
          ><input
            v-model="orderNumber"
            name="order_number"
            class="worker-input"
            placeholder="输入完整订单号，保留字母及开头的0"
            maxlength="100"
            autocapitalize="none"
            autocorrect="off"
            :disabled="disabled"
        /></label>
        <div v-if="!locked" class="bulk-panel">
          <label class="worker-field"
            ><span>批量粘贴快递号 <small>选填</small></span
            ><textarea
              v-model="bulk"
              class="worker-input"
              name="tracking_bulk"
              rows="3"
              maxlength="5000"
              placeholder="每行一个，也可用逗号分隔\n支持同一订单多个快递"
              :disabled="disabled"
            /></label
          ><button
            type="button"
            class="worker-button secondary"
            :disabled="disabled || !bulk.trim()"
            @click="addBulk"
          >
            加入快递列表
          </button>
        </div>
        <div class="tracking-heading">
          <h2>
            快递单号
            <span
              >{{ tracking.filter((value) => value.trim()).length }}/20</span
            >
          </h2>
          <button
            v-if="!locked"
            type="button"
            class="worker-button ghost"
            :disabled="disabled || tracking.length >= 20"
            @click="addRow"
          >
            ＋ 添加
          </button>
        </div>
        <div v-for="(_, index) in tracking" :key="index" class="tracking-row">
          <div class="tracking-index">{{ index + 1 }}</div>
          <div class="tracking-field">
            <input
              v-model="tracking[index]"
              class="worker-input"
              :name="`tracking_${index}`"
              :aria-label="`第${index + 1}个快递单号`"
              placeholder="填写完整快递单号"
              maxlength="100"
              autocapitalize="none"
              autocorrect="off"
              :disabled="disabled"
            /><span
              v-if="
                order?.parcels.find(
                  (parcel) => parcel.tracking_number === tracking[index],
                )
              "
              class="tracking-arrival"
              >{{
                order.parcels.find(
                  (parcel) => parcel.tracking_number === tracking[index],
                )?.arrived
                  ? '已到货'
                  : '运输中'
              }}</span
            >
          </div>
          <button
            v-if="!locked"
            type="button"
            class="tracking-remove"
            :disabled="disabled"
            :aria-label="`删除第${index + 1}个快递`"
            @click="removeRow(index)"
          >
            ×</button
          ><button
            v-else
            type="button"
            class="tracking-remove copy"
            :aria-label="`复制第${index + 1}个快递号`"
            @click="copyNumber(tracking[index] || '')"
          >
            复制
          </button>
        </div>
        <p class="worker-muted">
          全部快递在本店入库并同步后显示“已到货”，管理员确认结算后显示“已结算”。
        </p>
      </section>
      <div v-if="conflict" class="worker-info">
        服务器上的订单可能已被更新或结算。当前输入已保留，请先核对最新记录。<button
          type="button"
          class="worker-button secondary wide"
          :disabled="checkingLatest"
          @click="fetchLatest"
        >
          {{ checkingLatest ? '读取中…' : '查看最新记录' }}
        </button>
      </div>
      <section v-if="newest" class="worker-card">
        <h2>服务器最新内容</h2>
        <p class="worker-order-number">{{ newest.order_number }}</p>
        <WorkerStatus :status="newest.status" />
        <div class="worker-parcels">
          <div
            v-for="parcel in newest.parcels"
            :key="parcel.id"
            class="worker-parcel"
          >
            <span class="worker-parcel-number">{{
              parcel.tracking_number
            }}</span>
          </div>
        </div>
        <div class="worker-actions">
          <button class="worker-button secondary" @click="useServer">
            采用服务器记录</button
          ><button
            v-if="newest.status !== 'settled'"
            class="worker-button"
            @click="keepMine"
          >
            保留我的输入再核对
          </button>
        </div>
      </section>
      <div v-if="job && !locked" class="editor-save">
        <button
          class="worker-button wide"
          :disabled="saving || conflict || (creating && job.status !== 'open')"
          @click="save"
        >
          {{
            saving
              ? '正在保存…'
              : attempt
                ? '确认上次保存结果'
                : creating
                  ? '保存并提交订单'
                  : '保存修改'
          }}
        </button>
      </div>
      <RouterLink
        v-if="!job"
        class="worker-button secondary wide"
        to="/worker/jobs"
        >返回本店作业</RouterLink
      >
    </template>
  </div>
</template>
<style scoped>
.bulk-panel {
  padding: 15px;
  margin: 8px 0 20px;
  border-radius: 10px;
  background: #f4f8f5;
}
.bulk-panel .worker-field {
  margin: 0 0 10px;
}
.bulk-panel .worker-field > span small {
  display: inline;
  font-weight: 400;
  color: #9aa99f;
  margin-left: 6px;
}
.bulk-panel textarea {
  resize: vertical;
  min-height: 100px;
}
.bulk-panel button {
  min-height: 40px;
  font-size: 12px;
}
.tracking-heading {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  margin-bottom: 12px;
}
.tracking-heading h2 {
  font-size: 14px;
}
.tracking-heading h2 span {
  color: #8ca192;
  font-size: 11px;
  margin-left: 5px;
  font-weight: 400;
}
.tracking-row {
  display: flex;
  align-items: flex-start;
  gap: 8px;
  margin-bottom: 12px;
}
.tracking-index {
  flex: none;
  color: #a0b1a4;
  font-size: 11px;
  width: 15px;
  padding-top: 17px;
  text-align: center;
}
.tracking-field {
  min-width: 0;
  flex: 1;
}
.tracking-field input {
  font-size: 15px;
}
.tracking-remove {
  flex: none;
  border: 1px solid #efdbda;
  background: #fdf4f3;
  color: #b56562;
  border-radius: 8px;
  min-width: 40px;
  min-height: 46px;
  font-size: 22px;
  padding: 4px 10px;
}
.tracking-remove.copy {
  font-size: 11px;
  color: #4a775e;
  background: #edf6ef;
  border-color: #d6e7dc;
}
.tracking-remove:disabled {
  opacity: 0.4;
}
.tracking-arrival {
  display: block;
  margin: 4px 0 0 3px;
  color: #7d9584;
  font-size: 11px;
}
.editor-save {
  position: sticky;
  bottom: 76px;
  background: #f5f8f7ee;
  padding: 12px 0 0;
  z-index: 5;
  padding-bottom: 5px;
}
.worker-info .worker-button {
  margin-top: 12px;
}
</style>
