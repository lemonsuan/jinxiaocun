<script setup lang="ts">
import { onBeforeUnmount, ref, watch } from 'vue';
import { getOrder, listOrders, submitOrderAttempt } from '../api';
import { useAuthStore } from '../../store/auth';
import {
  attemptStorageKey,
  readOrderAttempt,
  settlementAttempt,
  type AdminOrderAttempt,
} from '../order-attempts';
import OrderPayoutDetails from './OrderPayoutDetails.vue';
import OrderSupplementDetails from './OrderSupplementDetails.vue';
import { errorText } from '../logic';
import { dateText, moneyText, operationId } from '../../worker/logic';
import WorkerStatus from '../../worker/components/WorkerStatus.vue';
import ProtectedImage from '../../components/ProtectedImage.vue';
import SettlementSnapshotView from './SettlementSnapshotView.vue';
import type { AdminOrder } from '../types';
const props = defineProps<{ jobId?: string }>();
const rows = ref<AdminOrder[]>([]);
const total = ref(0);
const page = ref(1);
const q = ref('');
const status = ref('');
const loading = ref(false);
const error = ref('');
const detail = ref<AdminOrder | null>(null);
const detailOpen = ref(false);
const detailLoading = ref(false);
const actionBusy = ref(false);
const actionError = ref('');
const notice = ref('');
const stale = ref(false);
const undoOpen = ref(false);
const reason = ref('');
const auth = useAuthStore();
const storageKey = attemptStorageKey(auth.username, auth.activeShopId);
function savedAttempt() {
  try { return readOrderAttempt(sessionStorage, storageKey); } catch { return null; }
}
const pendingAttempt = ref<AdminOrderAttempt | null>(savedAttempt());
let alive = true;
function preserveAttempt(value: AdminOrderAttempt) {
  // 必须先可靠记录，再提交，避免刷新后换操作键重复确认。
  sessionStorage.setItem(storageKey, JSON.stringify(value));
  pendingAttempt.value = value;
}
function clearAttempt() {
  try { sessionStorage.removeItem(storageKey); } catch { /* 存储不可用时仍展示已确认的服务端结果。 */ }
  pendingAttempt.value = null;
}
let controller: AbortController | undefined;
let detailController: AbortController | undefined;
async function load() {
  controller?.abort();
  const current = new AbortController();
  controller = current;
  loading.value = true;
  error.value = '';
  try {
    const result = await listOrders(
      {
        page: page.value,
        page_size: 20,
        job_id: props.jobId,
        q: q.value.trim() || undefined,
        status: status.value || undefined,
      },
      current.signal,
    );
    if (!current.signal.aborted) {
      rows.value = result.items;
      total.value = result.total;
    }
  } catch (failure) {
    if (!current.signal.aborted) error.value = errorText(failure);
  } finally {
    if (!current.signal.aborted) loading.value = false;
  }
}
function search() {
  page.value = 1;
  void load();
}
async function openOrder(id: string) {
  if (actionBusy.value) return;
  detailController?.abort();
  const current = new AbortController();
  detailController = current;
  detailOpen.value = true;
  detailLoading.value = true;
  detail.value = null;
  actionError.value = '';
  notice.value = '';
  stale.value = false;
  try {
    const value = await getOrder(id, current.signal);
    if (!current.signal.aborted) {
      detail.value = value;
    }
  } catch (failure) {
    if (!current.signal.aborted) actionError.value = errorText(failure);
  } finally {
    if (!current.signal.aborted) detailLoading.value = false;
  }
}
async function sendAttempt() {
  const attempt = pendingAttempt.value;
  if (!alive || !attempt || actionBusy.value) return;
  actionBusy.value = true;
  actionError.value = '';
  try {
    const result = await submitOrderAttempt(attempt);
    if (!alive) return;
    clearAttempt();
    detail.value = result;
    undoOpen.value = false;
    notice.value = attempt.action === 'settle'
      ? '已确认返款，拍手可查看结果。'
      : '已撤销结算标记，原记录已保留，拍手可修改订单。';
    await load();
  } catch (failure) {
    if (!alive) return;
    actionError.value = errorText(failure);
    const code = (failure as { response?: { status: number } }).response?.status;
    if (code && code < 500) {
      clearAttempt();
      if (code === 409) stale.value = true;
    } else {
      actionError.value += ' 上次结果尚未确认，请点击“确认上次操作结果”继续核对。';
    }
  } finally {
    if (alive) actionBusy.value = false;
  }
}
async function settle() {
  const order = detail.value;
  if (!order || actionBusy.value || pendingAttempt.value) return;
  const payout = order.payout;
  if (!window.confirm(
    `确认订单“${order.order_number}”已经给拍手返款？\n已到货 ${order.arrived_count}/${order.parcel_count} 件\n返款金额 ¥${moneyText(order.job.refund_amount)}\n支付宝：${payout?.alipay_name || '未填写姓名'} / ${payout?.alipay_phone || '未填写手机号'}\n微信号：${payout?.wechat || '未填写'}\n请核对收款资料与收款码。此操作只记录结果，不执行转账。`,
  )) return;
  try { preserveAttempt(settlementAttempt(order, operationId())); }
  catch { actionError.value = '浏览器无法保存待确认操作，请检查存储权限后重试，尚未提交。'; return; }
  await sendAttempt();
}
function openUndo() {
  if (pendingAttempt.value) return;
  reason.value = '';
  undoOpen.value = true;
  actionError.value = '';
}
async function undo() {
  if (!detail.value || actionBusy.value || pendingAttempt.value) return;
  if (!reason.value.trim()) { actionError.value = '请填写撤销结算的原因。'; return; }
  try {
    preserveAttempt({
      action: 'reopen', orderId: detail.value.id, orderNumber: detail.value.order_number,
      input: { expected_version: detail.value.version, operation_id: operationId(), reason: reason.value.trim() },
    });
  } catch { actionError.value = '浏览器无法保存待确认操作，尚未提交，请检查存储权限。'; return; }
  await sendAttempt();
}
async function resumeAttempt() {
  if (!pendingAttempt.value || actionBusy.value) return;
  await openOrder(pendingAttempt.value.orderId);
  // 详情仅用于展示，提交始终使用原操作键和原版本，不采纳刚加载的新资料。
  await sendAttempt();
}
watch(
  () => props.jobId,
  () => {
    page.value = 1;
    void load();
  },
  { immediate: true },
);
watch(detailOpen, (open) => {
  if (!open) {
    detailController?.abort();
    detail.value = null;
    actionError.value = '';
  }
});
onBeforeUnmount(() => {
  alive = false;
  controller?.abort();
  detailController?.abort();
});
</script>
<template>
  <section class="admin-section">
    <div class="admin-heading">
      <div>
        <h1>报单与结算</h1>
        <p>按订单集中查看全部快递，核对入库照片及商品后确认结算。</p>
      </div>
      <button class="admin-btn" :disabled="loading" @click="load">
        刷新到货状态
      </button>
    </div>
    <div v-if="pendingAttempt" class="admin-notice pending-order-attempt" role="status">
      <span>订单 {{ pendingAttempt.orderNumber }} 有一笔{{ pendingAttempt.action === 'settle' ? '返款确认' : '撤销结算' }}结果尚未确认。请先确认，避免重复操作。</span>
      <button class="admin-btn primary" :disabled="actionBusy" @click="resumeAttempt">{{ actionBusy ? '正在确认…' : '确认上次操作结果' }}</button>
    </div>
    <form class="admin-toolbar" @submit.prevent="search">
      <input
        v-model="q"
        class="admin-input"
        aria-label="搜索订单快递或拍手"
        placeholder="订单号、快递号、拍手账号或称呼"
        maxlength="100"
      /><select
        v-model="status"
        class="admin-input"
        aria-label="订单状态"
        @change="search"
      >
        <option value="">全部状态</option>
        <option value="in_transit">运输中</option>
        <option value="arrived">已到货待结算</option>
        <option value="settled">已结算</option></select
      ><button class="admin-btn primary" :disabled="loading">查询</button>
    </form>
    <div v-if="error" class="admin-error" role="alert">{{ error }}</div>
    <div v-if="loading" class="admin-empty">正在读取订单…</div>
    <div v-else-if="!rows.length" class="admin-empty">
      暂无匹配报单。拍手提交订单后会出现在这里。
    </div>
    <div v-else class="admin-orders-grid">
      <article v-for="order in rows" :key="order.id" class="admin-order-card">
        <div class="order-card-top">
          <strong>{{ order.order_number }}</strong
          ><WorkerStatus :status="order.status" />
        </div>
        <p>
          {{ order.worker.display_name || order.worker.username }}
          <small>（{{ order.worker.username }}）</small>
        </p>
        <p v-if="!jobId" class="order-job-title">{{ order.job.title }}</p>
        <div class="arrival-progress">
          <div>
            <span
              :style="{
                width: `${order.parcel_count ? (order.arrived_count / order.parcel_count) * 100 : 0}%`,
              }"
            />
          </div>
          <small
            >已到 {{ order.arrived_count }} /
            {{ order.parcel_count }} 件快递</small
          >
        </div>
        <div class="parcel-chips">
          <span
            v-for="parcel in order.parcels"
            :key="parcel.id"
            :class="{
              arrived: parcel.arrived,
              duplicate: parcel.duplicate_claim,
            }"
            >{{ parcel.tracking_number }}
            <small
              >{{ parcel.arrived ? '已到' : '在途'
              }}{{ parcel.duplicate_claim ? ' · 重复声明' : '' }}</small
            ></span
          >
        </div>
        <div class="order-card-footer">
          <small>{{ dateText(order.updated_at) }}</small
          ><button class="admin-btn primary" @click="openOrder(order.id)">
            查看全部快递与商品 →
          </button>
        </div>
      </article>
    </div>
    <div class="admin-pagination">
      <span>共 {{ total }} 笔订单</span
      ><button
        class="admin-btn"
        :disabled="page === 1 || loading"
        @click="
          page--;
          load();
        "
      >
        上一页</button
      ><span>{{ page }}</span
      ><button
        class="admin-btn"
        :disabled="page * 20 >= total || loading"
        @click="
          page++;
          load();
        "
      >
        下一页
      </button>
    </div>
    <el-drawer
      :model-value="detailOpen"
      title="订单快递与结算"
      size="min(900px,96vw)"
      :close-on-click-modal="!actionBusy"
      :close-on-press-escape="!actionBusy"
      :show-close="!actionBusy"
      @close="detailOpen = false"
      ><div v-if="detailLoading" class="admin-empty">正在加载全部订单证据…</div>
      <div v-if="actionError" class="admin-error" role="alert">
        {{ actionError }}
      </div>
      <div v-if="notice" class="admin-notice">{{ notice }}</div>
      <template v-if="detail"
        ><div class="detail-order-header">
          <div>
            <h2>{{ detail.order_number }}</h2>
            <p>
              {{ detail.worker.display_name || detail.worker.username }} ·
              {{ detail.job.title }}
            </p>
          </div>
          <WorkerStatus :status="detail.status" />
        </div>
        <div class="detail-money">
          <span
            >作业成本
            <strong
              >¥{{
                moneyText(
                  detail.settlement?.cost_amount ?? detail.job.cost_amount,
                )
              }}</strong
            ></span
          ><span
            >返款金额
            <strong
              >¥{{
                moneyText(
                  detail.settlement?.refund_amount ?? detail.job.refund_amount,
                )
              }}</strong
            ></span
          ><span
            >快递到货
            <strong
              >{{ detail.arrived_count }}/{{ detail.parcel_count }}</strong
            ></span
          >
        </div>
        <OrderPayoutDetails :payout="detail.payout" :snapshot="detail.payout_is_snapshot" />
        <OrderSupplementDetails :note="detail.note" :photos="detail.photos" :snapshot="detail.payout_is_snapshot" />
        <div v-if="detail.evidence_changed" class="admin-notice">
          入库凭证后来发生过更新；本订单保留确认结算时的原记录，请留意核对。
        </div>
        <div class="detail-section-title">
          <h3>全部快递及入库凭证</h3>
          <button
            class="admin-btn"
            :disabled="actionBusy || !!pendingAttempt"
            @click="openOrder(detail.id)"
          >
            刷新证据
          </button>
        </div>
        <article
          v-for="parcel in detail.parcels"
          :key="parcel.id"
          class="detail-parcel"
        >
          <div class="parcel-detail-heading">
            <strong>{{ parcel.tracking_number }}</strong
            ><span class="admin-badge" :class="{ closed: !parcel.arrived }">{{
              parcel.arrived ? '已入库' : '运输中'
            }}</span>
          </div>
          <p v-if="parcel.duplicate_claim" class="duplicate-warning">
            此快递号也出现在其他报单中，结算前请核对是否重复申报。
          </p>
          <template v-if="parcel.receipt"
            ><p class="admin-subtle">
              入库时间 {{ dateText(parcel.receipt.created_at) }}
            </p>
            <ProtectedImage
              v-if="parcel.receipt.image_sha256"
              :digest="parcel.receipt.image_sha256"
            />
            <div v-else class="admin-notice">此入库记录暂无同步图片。</div>
            <div class="admin-table-wrap">
              <table class="admin-table">
                <thead>
                  <tr>
                    <th>商品编码</th>
                    <th>商品名称</th>
                    <th>数量</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    v-for="(item, index) in parcel.receipt.items"
                    :key="index"
                  >
                    <td class="admin-word-break">
                      {{ item.product_code || '未编码' }}
                    </td>
                    <td class="admin-word-break">{{ item.product_name }}</td>
                    <td>{{ item.quantity }}</td>
                  </tr>
                </tbody>
              </table>
            </div></template
          >
          <div v-else class="admin-notice">
            尚未找到本店已同步的入库记录。请核对快递号或等待手机同步。
          </div>
        </article>
        <div class="detail-section-title"><h3>整笔订单商品总清单</h3></div>
        <div class="admin-table-wrap">
          <table class="admin-table">
            <thead>
              <tr>
                <th>编码</th>
                <th>商品名称</th>
                <th>总数量</th>
                <th>来源快递</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="product in detail.products || []" :key="product.key">
                <td>{{ product.product_code || '未编码' }}</td>
                <td>{{ product.product_name }}</td>
                <td class="admin-amount">{{ product.quantity }}</td>
                <td class="admin-word-break">
                  {{ product.tracking_numbers.join('、') }}
                </td>
              </tr>
            </tbody>
          </table>
          <div v-if="!detail.products?.length" class="admin-empty">
            尚无可汇总的已入库商品。
          </div>
        </div>
        <div
          v-if="detail.settlement_history?.length"
          class="settlement-history"
        >
          <h3>结算记录</h3>
          <div v-for="record in detail.settlement_history" :key="record.id">
            <strong>¥{{ moneyText(record.refund_amount) }}</strong
            ><span
              >{{ record.is_active ? '有效结算' : '已撤销' }} ·
              {{ record.operator || '管理员' }} ·
              {{ dateText(record.created_at) }}</span
            >
            <p v-if="record.reopen_reason">
              撤销原因：{{ record.reopen_reason }}
            </p>
            <SettlementSnapshotView :snapshot="record.snapshot" />
          </div>
        </div>
        <div v-if="pendingAttempt" class="admin-notice">
          当前有未确认操作，不会改用当前收款资料重复提交。
          <button class="admin-btn primary" :disabled="actionBusy" @click="resumeAttempt">{{ actionBusy ? '正在确认…' : '确认上次操作结果' }}</button>
        </div>
        <div class="settlement-controls">
          <template v-if="detail.status === 'settled'"
            ><span class="admin-subtle">已结算订单已锁定拍手修改。</span
            ><button
              class="admin-btn danger"
              :disabled="actionBusy || !!pendingAttempt"
              @click="openUndo"
            >
              撤销结算标记
            </button></template
          ><template v-else
            ><span class="admin-subtle">{{
              detail.arrived_count === detail.parcel_count
                ? '全部快递已到货，请核对后确认。'
                : '尚有快递未入库，暂不能结算。'
            }}</span
            ><button
              class="admin-btn primary"
              :disabled="
                actionBusy ||
                !!pendingAttempt ||
                stale ||
                detail.arrived_count !== detail.parcel_count ||
                !detail.parcel_count
              "
              @click="settle"
            >
              {{
                actionBusy
                  ? '处理中…'
                  : '确认已给拍手返款'
              }}
            </button></template
          >
        </div></template
      ></el-drawer
    >
    <el-dialog
      v-model="undoOpen"
      title="撤销结算标记"
      width="min(440px,95vw)"
      :close-on-click-modal="!actionBusy"
      :close-on-press-escape="!actionBusy"
      ><div class="admin-notice">
        原结算记录会保留。撤销后拍手可修改订单，此操作不执行退款。
      </div>
      <label class="admin-form-field"
        ><span>撤销原因</span
        ><textarea
          v-model="reason"
          class="admin-input"
          rows="3"
          maxlength="1000"
          :disabled="actionBusy || !!pendingAttempt"
          placeholder="请填写更正原因"
        />
      </label>
      <div v-if="actionError" class="admin-error">{{ actionError }}</div>
      <div class="admin-dialog-footer">
        <button
          class="admin-btn"
          :disabled="actionBusy"
          @click="undoOpen = false"
        >
          取消</button
        ><button class="admin-btn danger" :disabled="actionBusy" @click="undo">
          {{ actionBusy ? '处理中…' : '确认撤销并留痕' }}
        </button>
      </div></el-dialog
    >
  </section>
</template>
<style scoped>
.pending-order-attempt { display: flex; align-items: center; flex-wrap: wrap; gap: 10px; }
.pending-order-attempt span { flex: 1; min-width: 180px; }

.admin-orders-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(min(350px, 100%), 1fr));
  gap: 15px;
}
.admin-order-card {
  border: 1px solid #e1e9e3;
  border-radius: 10px;
  padding: 18px;
  min-width: 0;
}
.order-card-top {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 9px;
}
.order-card-top > strong {
  min-width: 0;
  font-size: 15px;
  color: #2b583e;
  overflow-wrap: anywhere;
  font-variant-numeric: tabular-nums;
}
.admin-order-card p {
  font-size: 12px;
  color: #7b927f;
  line-height: 1.7;
  margin: 11px 0;
  overflow-wrap: anywhere;
}
.admin-order-card p small {
  font-size: 10px;
  color: #a4b0a6;
}
.order-job-title {
  color: #94a697 !important;
  font-size: 11px !important;
}
.arrival-progress > div {
  background: #edf2ee;
  height: 5px;
  border-radius: 9px;
  overflow: hidden;
  margin-bottom: 6px;
}
.arrival-progress > div > span {
  height: 100%;
  background: #63a67b;
  display: block;
}
.arrival-progress small {
  font-size: 10px;
  color: #8a9d90;
}
.parcel-chips {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin: 13px 0;
}
.parcel-chips > span {
  border: 1px solid #e5e9e5;
  background: #f7f8f6;
  color: #8a957f;
  border-radius: 6px;
  padding: 6px 8px;
  font-size: 11px;
  overflow-wrap: anywhere;
  max-width: 100%;
}
.parcel-chips > span.arrived {
  border-color: #d4e8db;
  color: #4a8860;
  background: #eff8f2;
}
.parcel-chips > span.duplicate {
  border-color: #eedbb2;
  background: #fff8e9;
}
.parcel-chips small {
  font-size: 9px;
  white-space: nowrap;
  opacity: 0.8;
}
.order-card-footer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  border-top: 1px solid #edf2ee;
  padding-top: 13px;
}
.order-card-footer small {
  font-size: 10px;
  color: #a0b0a4;
}
.order-card-footer button {
  font-size: 10px;
}
.detail-order-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 12px;
  margin: 3px 0 19px;
}
.detail-order-header h2 {
  font-size: 21px;
  color: #365b43;
  overflow-wrap: anywhere;
  font-weight: 700;
  margin: 0;
}
.detail-order-header p {
  font-size: 12px;
  color: #90a18f;
  margin: 9px 0 0;
}
.detail-money {
  display: flex;
  gap: 19px;
  flex-wrap: wrap;
  background: #f1f7f3;
  padding: 16px;
  border-radius: 8px;
  color: #8b9f8e;
  font-size: 11px;
}
.detail-money strong {
  font-size: 18px;
  color: #3c724c;
  margin-left: 6px;
}
.detail-section-title {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  margin: 25px 0 15px;
}
.detail-section-title h3,
.settlement-history h3 {
  font-size: 14px;
  color: #41664b;
  font-weight: 700;
  margin: 0;
}
.detail-parcel {
  padding: 17px;
  border: 1px solid #dfe8e1;
  border-radius: 10px;
  margin-bottom: 16px;
  min-width: 0;
}
.parcel-detail-heading {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 10px;
  margin-bottom: 9px;
}
.parcel-detail-heading strong {
  font-size: 15px;
  color: #477253;
  min-width: 0;
  overflow-wrap: anywhere;
}
.duplicate-warning {
  font-size: 11px;
  line-height: 1.8;
  color: #a77a32;
  background: #fff7e8;
  padding: 9px;
  border-radius: 6px;
}
.detail-parcel > .admin-subtle {
  margin-bottom: 13px;
}
.detail-parcel .admin-table-wrap {
  margin-top: 15px;
}
.settlement-history {
  padding: 18px;
  border: 1px solid #e1e9e2;
  border-radius: 8px;
  margin-top: 25px;
}
.settlement-history > div {
  border-top: 1px solid #ecf1ed;
  margin-top: 12px;
  padding-top: 12px;
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
  font-size: 11px;
  color: #879a8c;
}
.settlement-history strong {
  color: #477454;
}
.settlement-history p {
  flex-basis: 100%;
  margin: 0;
  font-size: 11px;
  color: #a29c87;
}
.settlement-controls {
  position: sticky;
  bottom: 0;
  padding: 18px 0 5px;
  background: #fffffff2;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  border-top: 1px solid #e7eee8;
  margin-top: 20px;
  flex-wrap: wrap;
}
@media (max-width: 500px) {
  .detail-order-header h2 {
    font-size: 18px;
  }
  .detail-parcel {
    padding: 12px;
  }
  .detail-money {
    gap: 10px;
  }
  .detail-money strong {
    font-size: 16px;
  }
  .settlement-controls > .admin-btn {
    width: 100%;
  }
}
</style>
