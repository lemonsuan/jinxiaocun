<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue';
import { createOrder, loadOrder, loadPayout, updateOrder, uploadWorkerMedia } from '../api';
import { orderDraftKey, readOrderDraft, removeOrderDraft, saveOrderDraft } from '../drafts';
import { operationId, parseTrackingNumbers, sameWorkerScope } from '../logic';
import { isWorkerCancellation, workerError, WorkerRequestError } from '../request';
import { useWorkerStore } from '../store';
import type { CreateOrderInput, UpdateOrderInput, WorkerJob, WorkerMedia, WorkerOrder, WorkerPayout } from '../types';
import WorkerModal from './WorkerModal.vue';
import WorkerPayoutModal from './WorkerPayoutModal.vue';
const props = defineProps<{ modelValue: boolean; job: WorkerJob | WorkerOrder['job']; orderId?: string }>();
const emit = defineEmits<{ 'update:modelValue': [boolean]; saved: [WorkerOrder] }>();
const auth = useWorkerStore();
const scope = auth.scope();
const order = ref<WorkerOrder | null>(null);
const orderNumber = ref(''), tracking = ref(''), note = ref(''), error = ref('');
const draftWarning = ref(false);
const photos = ref<WorkerMedia[]>([]);
const pending = ref<{ id: string; name: string; file?: File; status: 'uploading' | 'failed'; error: string }[]>([]);
const payout = ref<WorkerPayout | null>(null), payoutOpen = ref(false);
const loading = ref(false), saving = ref(false), conflict = ref(false), checking = ref(false);
const latest = ref<WorkerOrder | null>(null);
const attempt = ref<CreateOrderInput | UpdateOrderInput | null>(null);
const uploading = computed(() => pending.value.some(x => x.status === 'uploading'));
const locked = computed(() => order.value?.status === 'settled');
const frozen = computed(() => saving.value || locked.value || !!attempt.value);
const key = computed(() => orderDraftKey(scope, props.job.id, props.orderId));
const payoutIncomplete = computed(() => !payout.value?.wechat || !payout.value?.alipay_phone || !payout.value?.alipay_name || !payout.value?.qr_sha256);
let controller: AbortController | undefined;
let alive = true, restored = false, successful = false;
function persist(): boolean {
  if (!restored || successful || locked.value || !sameWorkerScope(scope, auth.scope())) return false;
  if (!attempt.value && !pending.value.length && (order.value ? orderNumber.value === order.value.order_number && tracking.value === order.value.parcels.map(x => x.tracking_number).join('\n') && note.value === (order.value.note || '') && JSON.stringify(photos.value.map(x => x.sha256)) === JSON.stringify((order.value.photos || []).map(x => x.sha256)) : !orderNumber.value && !tracking.value && !note.value && !photos.value.length)) { removeOrderDraft(key.value); return true; }
  draftWarning.value = !saveOrderDraft(key.value, { baseVersion: order.value?.version, orderNumber: orderNumber.value, trackingText: tracking.value, note: note.value, photos: photos.value, pendingPhotos: pending.value.map(x => ({ id: x.id, name: x.name })), attempt: attempt.value });
  return !draftWarning.value;
}
function adopt(value: WorkerOrder) {
  order.value = value; orderNumber.value = value.order_number; tracking.value = value.parcels.map(x => x.tracking_number).join('\n'); note.value = value.note || ''; photos.value = value.photos || []; pending.value = [];
}
async function initialize() {
  controller?.abort(); const current = controller = new AbortController();
  restored = false; successful = false; loading.value = true; error.value = ''; conflict.value = false; latest.value = null; attempt.value = null;
  order.value = null; orderNumber.value = ''; tracking.value = ''; note.value = ''; photos.value = []; pending.value = [];
  try {
    if (props.orderId) {
      const result = await loadOrder(props.orderId, current.signal);
      if (current.signal.aborted || !alive) return;
      adopt(result);
    }
    const draft = readOrderDraft(key.value);
    if (draft && !locked.value) {
      orderNumber.value = draft.orderNumber; tracking.value = draft.trackingText; note.value = draft.note; photos.value = draft.photos;
      pending.value = draft.pendingPhotos.map(x => ({ ...x, status: 'failed', error: '刷新后请重新选择这张照片。' }));
      // 草稿的请求身份必须与当前打开的表单一致。
      const saved = draft.attempt;
      if (props.orderId && !saved && draft.baseVersion !== (order.value as WorkerOrder | null)?.version) { conflict.value = true; latest.value = order.value; }
      if (saved && (props.orderId ? 'expected_version' in saved : 'job_id' in saved && saved.job_id === props.job.id)) attempt.value = saved;
    }
    restored = true;
    // 收款资料不阻塞订单输入，低速网络下也能立即填报。
    void loadPayout(current.signal).then(value => { if (alive && !current.signal.aborted) payout.value = value; }).catch(() => { /* 收款按钮仍可独立重试，不阻塞报单。 */ });
  } catch (failure) { if (!isWorkerCancellation(failure)) error.value = workerError(failure); }
  finally { if (!current.signal.aborted && alive) loading.value = false; }
}
async function sendPhoto(id: string) {
  const item = pending.value.find(x => x.id === id);
  if (!item?.file || frozen.value) return;
  item.status = 'uploading'; item.error = '';
  try {
    const value = await uploadWorkerMedia(item.file, 'order', controller?.signal);
    if (!alive || controller?.signal.aborted) return;
    if (!photos.value.some(x => x.sha256 === value.sha256)) photos.value.push(value);
    pending.value = pending.value.filter(x => x.id !== id);
  } catch (failure) { if (!isWorkerCancellation(failure)) { item.status = 'failed'; item.error = workerError(failure); } }
  finally { persist(); }
}
function addPhotos(event: Event) {
  const input = event.target as HTMLInputElement;
  const files = Array.from(input.files || []); input.value = '';
  if (frozen.value) return;
  if (photos.value.length + pending.value.length + files.length > 10) { error.value = '一个订单最多上传10张补充照片。'; return; }
  for (const file of files) {
    if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type) || file.size > 15 * 1024 * 1024) { error.value = '请选择15MB以内的JPG、PNG或WebP图片。'; continue; }
    const id = operationId(); pending.value.push({ id, name: file.name, file, status: 'uploading', error: '' }); void sendPhoto(id);
  }
  persist();
}
async function save() {
  if (saving.value || locked.value || uploading.value || conflict.value || (!attempt.value && !props.orderId && props.job.status !== 'open')) return;
  error.value = '';
  const retrying = !!attempt.value;
  if (!attempt.value) {
    if (!orderNumber.value.trim()) { error.value = '请填写订单号。'; return; }
    const parsed = parseTrackingNumbers([tracking.value]);
    if (parsed.error || !parsed.values.length) { error.value = parsed.error || '请至少填写一个快递单号。'; return; }
    if (pending.value.length) { error.value = '请先重试上传失败的照片，或移除后提交。'; return; }
    const common = { order_number: orderNumber.value.trim(), tracking_numbers: parsed.values, note: note.value, photo_sha256s: photos.value.map(x => x.sha256), operation_id: operationId() };
    attempt.value = props.orderId ? { ...common, expected_version: order.value!.version } : { ...common, job_id: props.job.id };
  }
  if (!persist()) {
    if (!retrying) attempt.value = null;
    error.value = retrying ? '浏览器无法保存提交凭据，暂不能确认上次结果。请恢复浏览器存储后重试。' : '浏览器无法保存提交凭据，本次尚未提交。请允许浏览器存储后重试。';
    return;
  }
  saving.value = true;
  try {
    const value = props.orderId ? await updateOrder(props.orderId, attempt.value as UpdateOrderInput) : await createOrder(attempt.value as CreateOrderInput);
    if (!alive) return;
    successful = true; attempt.value = null; removeOrderDraft(key.value);
    emit('saved', value); emit('update:modelValue', false);
  } catch (failure) {
    if (!alive || isWorkerCancellation(failure)) return;
    error.value = workerError(failure);
    if (failure instanceof WorkerRequestError && !failure.outcomeUnknown) {
      attempt.value = null;
      if (failure.status === 409 && props.orderId) conflict.value = true;
    }
    persist();
  } finally { if (alive) saving.value = false; }
}
async function checkLatest() {
  if (!props.orderId || checking.value) return;
  checking.value = true;
  try { latest.value = await loadOrder(props.orderId, controller?.signal); }
  catch (failure) { if (!isWorkerCancellation(failure)) error.value = workerError(failure); }
  finally { if (alive) checking.value = false; }
}
function acceptLatest(keep: boolean) {
  if (!latest.value) return;
  if (keep && latest.value.status !== 'settled') order.value = latest.value;
  else adopt(latest.value);
  latest.value = null; conflict.value = false; error.value = ''; persist();
}
watch(() => props.modelValue, value => { if (value) void initialize(); else persist(); }, { immediate: true });
watch([orderNumber, tracking, note, photos, pending, attempt], persist, { deep: true });
onBeforeUnmount(() => { persist(); alive = false; controller?.abort(); });
</script>
<template>
  <WorkerModal :model-value="modelValue" :title="locked ? '已返款订单' : orderId ? '编辑订单' : '填报作业'" :busy="saving || uploading || payoutOpen" @update:model-value="emit('update:modelValue', $event)">
    <p class="worker-muted modal-job-title">{{ job.title }}</p>
    <div v-if="loading" class="worker-empty">正在读取…</div>
    <form v-else-if="!orderId || order" @submit.prevent="save">
      <button type="button" class="worker-button secondary wide payout-entry" @click="payoutOpen = true">查看 / 编辑我的收款信息</button>
      <p class="worker-muted" :class="{ 'worker-warning': payoutIncomplete }">{{ payoutIncomplete ? '收款信息尚未完整，请及时核对。' : '所有作业默认使用我的收款信息。' }}</p>
      <label class="worker-field"><span>订单号</span><input v-model="orderNumber" class="worker-input" name="order_number" placeholder="填写订单号" maxlength="100" :disabled="frozen" autocapitalize="none" autocorrect="off" /></label>
      <label class="worker-field"><span>快递单号</span><textarea v-model="tracking" class="worker-input" name="tracking_numbers" rows="4" maxlength="5000" placeholder="每行一个，可直接粘贴多个快递号" :disabled="frozen" autocapitalize="none" autocorrect="off" /><small>同一个订单可填多个快递号，最多20个。</small></label>
      <label class="worker-field"><span>补充说明（选填）</span><textarea v-model="note" class="worker-input" name="note" rows="2" maxlength="2000" :disabled="frozen" placeholder="需要补充的内容写在这里" /></label>
      <section class="worker-field"><span>补充照片（选填） · {{ photos.length + pending.length }}/10</span>
        <label v-if="!locked" class="worker-button secondary upload-label" :class="{ disabled: frozen }">上传照片<input type="file" accept="image/jpeg,image/png,image/webp" multiple :disabled="frozen" @change="addPhotos" /></label>
        <div v-for="photo in photos" :key="photo.sha256" class="worker-upload-row"><span>{{ photo.name || '补充照片' }} · 已上传</span><button v-if="!locked" type="button" class="worker-button ghost" :disabled="frozen" @click="photos = photos.filter(x => x.sha256 !== photo.sha256)">移除</button></div>
        <div v-for="photo in pending" :key="photo.id" class="worker-upload-row"><span>{{ photo.name }} · {{ photo.status === 'uploading' ? '上传中…' : photo.error }}</span><button v-if="photo.status === 'failed' && photo.file" type="button" class="worker-button ghost" :disabled="frozen" @click="sendPhoto(photo.id)">重试</button><button v-if="photo.status === 'failed'" type="button" class="worker-button ghost" :disabled="frozen" @click="pending = pending.filter(x => x.id !== photo.id)">移除</button></div>
      </section>
      <p v-if="locked" class="worker-info">此订单已返款，不能修改。修改个人收款信息不会改变本单的返款记录。</p>
      <p v-if="draftWarning" class="worker-error">浏览器无法保存草稿，请勿刷新或关闭页面；若提交结果未知，请先在已做作业核对再重新填写。</p>
      <p v-if="attempt" class="worker-info">上次提交结果尚未确认，输入已保留并锁定。请使用下方按钮确认，避免重复报单。</p>
      <section v-if="conflict" class="worker-info">订单已变化，当前输入已保留。<button type="button" class="worker-button secondary wide" :disabled="checking" @click="checkLatest">{{ checking ? '读取中…' : '核对最新订单' }}</button></section>
      <section v-if="latest" class="worker-info"><strong>服务器最新订单：{{ latest.order_number }}</strong><p v-for="parcel in latest.parcels" :key="parcel.id">{{ parcel.tracking_number }}</p><p>{{ latest.note || '没有补充说明' }} · 补充照片{{ latest.photos?.length || 0 }}张</p><div class="worker-actions"><button type="button" class="worker-button secondary" @click="acceptLatest(false)">采用最新记录</button><button v-if="latest.status !== 'settled'" type="button" class="worker-button secondary" @click="acceptLatest(true)">保留输入再核对</button></div></section>
      <p v-if="error" class="worker-error" role="alert">{{ error }}</p>
      <button v-if="!locked" class="worker-button wide" :disabled="saving || uploading || conflict || (!attempt && !orderId && job.status !== 'open')">{{ saving ? '提交中…' : attempt ? '确认上次提交结果' : orderId ? '保存修改' : '提交订单' }}</button>
    </form>
    <p v-else class="worker-error">{{ error }}<button class="worker-button ghost" @click="initialize">重试</button></p>
  </WorkerModal>
  <WorkerPayoutModal v-if="payoutOpen" v-model="payoutOpen" @saved="payout = $event" />
</template>
