<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue';
import { loadPayout, savePayout, uploadWorkerMedia } from '../api';
import { operationId, sameWorkerScope } from '../logic';
import { isWorkerCancellation, workerError, WorkerRequestError } from '../request';
import { useWorkerStore } from '../store';
import type { WorkerPayout, WorkerPayoutInput } from '../types';
import WorkerModal from './WorkerModal.vue';
const props = defineProps<{ modelValue: boolean }>();
const emit = defineEmits<{ 'update:modelValue': [boolean]; saved: [WorkerPayout] }>();
const auth = useWorkerStore();
const scope = auth.scope();
const profile = ref<WorkerPayout | null>(null);
const wechat = ref(''), phone = ref(''), name = ref(''), qr = ref<string | null>(null);
const loading = ref(false), saving = ref(false), uploading = ref(false), error = ref('');
const attempt = ref<WorkerPayoutInput | null>(null);
const latest = ref<WorkerPayout | null>(null);
const frozen = computed(() => saving.value || uploading.value || !!attempt.value);
const key = `worker_payout_draft_v1:${auth.worker?.shop_number}:${auth.worker?.id}`;
let controller: AbortController | undefined;
let alive = true, successful = false;
function persist(): boolean {
  if (!profile.value || successful || !sameWorkerScope(scope, auth.scope())) return false;
  if (!attempt.value && wechat.value === profile.value.wechat && phone.value === profile.value.alipay_phone && name.value === profile.value.alipay_name && qr.value === profile.value.qr_sha256) { try { sessionStorage.removeItem(key); } catch { /* 不阻断编辑。 */ } return true; }
  try { sessionStorage.setItem(key, JSON.stringify({ wechat: wechat.value, phone: phone.value, name: name.value, qr: qr.value, version: profile.value.version, attempt: attempt.value })); return true; } catch { return false; }
}
function adopt(value: WorkerPayout) {
  profile.value = value; wechat.value = value.wechat; phone.value = value.alipay_phone; name.value = value.alipay_name; qr.value = value.qr_sha256;
}
async function open() {
  controller?.abort();
  const current = controller = new AbortController();
  successful = false; attempt.value = null; loading.value = true; error.value = ''; latest.value = null;
  try {
    const value = await loadPayout(current.signal);
    if (current.signal.aborted || !alive) return;
    adopt(value);
    try {
      const x = JSON.parse(sessionStorage.getItem(key) || 'null');
      if (x && typeof x.wechat === 'string' && x.wechat.length <= 80 && typeof x.phone === 'string' && x.phone.length <= 20 && typeof x.name === 'string' && x.name.length <= 100 && (x.qr === null || /^[a-f0-9]{64}$/.test(x.qr)) && Number.isInteger(x.version)) {
        wechat.value = x.wechat; phone.value = x.phone; name.value = x.name; qr.value = x.qr;
        if (x.attempt && typeof x.attempt.operation_id === 'string' && x.attempt.expected_version === x.version && x.attempt.wechat === x.wechat && x.attempt.alipay_phone === x.phone && x.attempt.alipay_name === x.name && x.attempt.qr_sha256 === x.qr) {
          attempt.value = { wechat: x.wechat, alipay_phone: x.phone, alipay_name: x.name, qr_sha256: x.qr, expected_version: x.version, operation_id: x.attempt.operation_id };
        } else attempt.value = null;
        if (x.version !== value.version && !attempt.value) latest.value = value;
        profile.value = { ...value, version: x.version };
      }
    } catch { /* 损坏草稿不覆盖服务器资料。 */ }
  } catch (failure) { if (!isWorkerCancellation(failure)) error.value = workerError(failure); }
  finally { if (!current.signal.aborted && alive) loading.value = false; }
}
async function upload(event: Event) {
  const input = event.target as HTMLInputElement;
  const file = input.files?.[0]; input.value = '';
  if (!file || frozen.value) return;
  if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type) || file.size > 15 * 1024 * 1024) { error.value = '请选择15MB以内的JPG、PNG或WebP图片。'; return; }
  uploading.value = true; error.value = '';
  try { const value = await uploadWorkerMedia(file, 'payout', controller?.signal); if (alive) { qr.value = value.sha256; persist(); } }
  catch (failure) { if (!isWorkerCancellation(failure)) error.value = workerError(failure); }
  finally { if (alive) uploading.value = false; }
}
async function save() {
  if (!profile.value || saving.value || uploading.value || latest.value) return;
  const retrying = !!attempt.value;
  if (!attempt.value) attempt.value = { wechat: wechat.value.trim(), alipay_phone: phone.value.trim(), alipay_name: name.value.trim(), qr_sha256: qr.value, expected_version: profile.value.version, operation_id: operationId() };
  // 未知结果的请求在发出前持久化，刷新后仍复用原操作键和内容。
  wechat.value = attempt.value.wechat; phone.value = attempt.value.alipay_phone; name.value = attempt.value.alipay_name;
  if (!persist()) {
    if (!retrying) attempt.value = null;
    error.value = retrying ? '浏览器无法保存提交凭据，暂不能确认上次结果。请恢复浏览器存储后重试。' : '浏览器无法保存提交凭据，本次尚未提交。请允许浏览器存储后重试。';
    return;
  }
  saving.value = true; error.value = '';
  try {
    const value = await savePayout(attempt.value);
    if (!alive) return;
    successful = true; attempt.value = null; adopt(value);
    try { sessionStorage.removeItem(key); } catch { /* 不影响已保存结果。 */ }
    emit('saved', value); emit('update:modelValue', false);
  } catch (failure) {
    if (!alive || isWorkerCancellation(failure)) return;
    error.value = workerError(failure);
    if (failure instanceof WorkerRequestError && !failure.outcomeUnknown) {
      attempt.value = null;
      if (failure.status === 409) {
        try { latest.value = await loadPayout(controller?.signal); } catch (next) { error.value = workerError(next); }
      }
    }
    persist();
  } finally { if (alive) saving.value = false; }
}
function acceptLatest(keep: boolean) {
  if (!latest.value) return;
  if (keep) profile.value = latest.value; else adopt(latest.value);
  latest.value = null; error.value = ''; persist();
}
watch(() => props.modelValue, value => { if (value) void open(); else persist(); }, { immediate: true });
watch([wechat, phone, name, qr], persist);
onBeforeUnmount(() => { persist(); alive = false; controller?.abort(); });
</script>
<template>
  <WorkerModal :model-value="modelValue" title="我的收款信息" :busy="saving || uploading" @update:model-value="emit('update:modelValue', $event)">
    <p class="worker-info">所有作业默认使用这份收款信息，无需重复填写，请确认信息准确。未返款订单使用最新信息，已返款订单保留当时信息。</p>
    <p v-if="loading" class="worker-empty">正在读取…</p>
    <form v-else-if="profile" @submit.prevent="save">
      <label class="worker-field"><span>微信号</span><input v-model="wechat" class="worker-input" maxlength="80" :disabled="frozen" autocomplete="off" /></label>
      <label class="worker-field"><span>支付宝手机号</span><input v-model="phone" class="worker-input" maxlength="20" inputmode="tel" :disabled="frozen" autocomplete="tel" /></label>
      <label class="worker-field"><span>支付宝收款人姓名</span><input v-model="name" class="worker-input" maxlength="100" :disabled="frozen" autocomplete="name" /></label>
      <div class="worker-field"><span>支付宝收款码</span><p class="worker-muted">{{ uploading ? '上传中…' : qr ? '已上传收款码，可重新上传替换' : '尚未上传' }}</p><label class="worker-button secondary upload-label" :class="{ disabled: frozen }">{{ qr ? '替换收款码' : '上传收款码' }}<input type="file" accept="image/jpeg,image/png,image/webp" :disabled="frozen" @change="upload" /></label></div>
      <p v-if="attempt" class="worker-info">上次保存结果尚未确认，请点击下方按钮确认，期间不能修改内容。</p>
      <section v-if="latest" class="worker-info"><strong>收款资料已变化，请核对最新信息</strong><p>微信：{{ latest.wechat || '未填' }}<br>支付宝：{{ latest.alipay_phone || '未填' }} · {{ latest.alipay_name || '未填' }}<br>收款码：{{ latest.qr_sha256 ? '已上传' : '未上传' }}</p><div class="worker-actions"><button type="button" class="worker-button secondary" @click="acceptLatest(false)">采用最新信息</button><button type="button" class="worker-button secondary" @click="acceptLatest(true)">保留输入再核对</button></div></section>
      <p v-if="error" class="worker-error" role="alert">{{ error }}</p>
      <button class="worker-button wide" :disabled="saving || uploading || !!latest">{{ saving ? '保存中…' : attempt ? '确认上次保存结果' : '保存收款信息' }}</button>
    </form>
    <div v-else-if="error" class="worker-error">{{ error }}<button class="worker-button ghost" @click="open">重试</button></div>
  </WorkerModal>
</template>
