<script setup lang="ts">
import WorkerIcon from '../components/WorkerIcon.vue';
import { onBeforeUnmount, ref } from 'vue';
import { loadPayout } from '../api';
import { isWorkerCancellation, workerError } from '../request';
import { useWorkerStore } from '../store';
import type { WorkerPayout } from '../types';
import WorkerPayoutModal from '../components/WorkerPayoutModal.vue';
const auth = useWorkerStore();
const payout = ref<WorkerPayout | null>(null), editing = ref(false), error = ref('');
const controller = new AbortController();
async function load() {
  error.value = '';
  try { payout.value = await loadPayout(controller.signal); }
  catch (failure) { if (!isWorkerCancellation(failure)) error.value = workerError(failure); }
}
void load();
onBeforeUnmount(() => controller.abort());
</script>
<template>
  <div><div class="worker-page-heading"><h1>我的</h1></div><section class="worker-card"><h2>{{ auth.worker?.display_name || auth.worker?.username }}</h2><p class="worker-muted">{{ auth.worker?.shop_name }} · 店铺 {{ auth.worker?.shop_number }}</p></section>
    <section class="worker-card"><h2>收款信息</h2><p class="worker-muted">所有作业默认使用这份收款信息，无需重复填写，请确认信息准确。</p><dl class="worker-profile-fields"><div><dt>微信号</dt><dd>{{ payout?.wechat || '未填写' }}</dd></div><div><dt>支付宝手机号</dt><dd>{{ payout?.alipay_phone || '未填写' }}</dd></div><div><dt>支付宝收款人</dt><dd>{{ payout?.alipay_name || '未填写' }}</dd></div><div><dt>支付宝收款码</dt><dd>{{ payout?.qr_sha256 ? '已上传' : '未上传' }}</dd></div></dl><button class="worker-button wide" @click="editing = true"><WorkerIcon name="edit" />编辑收款信息</button></section>
    <p v-if="error" class="worker-error">{{ error }}<button class="worker-button ghost" @click="load">重试</button></p>
    <WorkerPayoutModal v-if="editing" v-model="editing" @saved="payout = $event" />
  </div>
</template>
