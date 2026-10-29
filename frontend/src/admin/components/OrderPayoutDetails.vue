<script setup lang="ts">
import type { WorkerPayout } from '../../worker/types';
import ProtectedImage from '../../components/ProtectedImage.vue';
defineProps<{ payout?: WorkerPayout | null; snapshot?: boolean }>();
</script>
<template>
  <section class="payout-details" aria-label="拍手收款信息">
    <h3>{{ snapshot ? '结算时收款信息' : '当前收款信息' }}</h3>
    <template v-if="payout">
      <dl>
        <div><dt>微信号</dt><dd>{{ payout.wechat || '未填写' }}</dd></div>
        <div><dt>支付宝手机号</dt><dd>{{ payout.alipay_phone || '未填写' }}</dd></div>
        <div><dt>支付宝收款人</dt><dd>{{ payout.alipay_name || '未填写' }}</dd></div>
      </dl>
      <p v-if="!snapshot" class="admin-subtle">未返款订单使用拍手最新资料，请在实际返款前核对。</p>
      <p v-else class="admin-subtle">此处为当时留存资料，不随后续修改变化。</p>
      <details v-if="payout.qr_sha256">
        <summary>查看支付宝收款码</summary>
        <ProtectedImage :digest="payout.qr_sha256" />
      </details>
      <p v-else class="payout-missing">{{ snapshot ? '当时未留存收款码。' : '拍手尚未上传收款码，请联系核实。' }}</p>
    </template>
    <p v-else class="admin-subtle">{{ snapshot ? '该历史结算未留存收款资料。' : '暂未填写收款资料，请联系拍手核实。' }}</p>
  </section>
</template>
<style scoped>
.payout-details { border: 1px solid #dce7df; border-radius: 8px; padding: 14px; margin-top: 16px; min-width: 0; }
h3 { margin: 0 0 10px; color: #355b42; font-size: 14px; font-weight: 650; }
dl { display: grid; gap: 8px; margin: 0 0 10px; }
dl > div { display: grid; grid-template-columns: 104px 1fr; gap: 8px; font-size: 12px; }
dt { color: #7f9284; } dd { margin: 0; color: #355541; overflow-wrap: anywhere; }
summary { cursor: pointer; color: #35684c; padding: 10px 0; font-size: 12px; }
.payout-missing { color: #9a7339; font-size: 12px; line-height: 1.8; margin-bottom: 0; }
</style>
