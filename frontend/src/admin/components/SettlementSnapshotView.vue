<script setup lang="ts">
import ProtectedImage from '../../components/ProtectedImage.vue';
import OrderPayoutDetails from './OrderPayoutDetails.vue';
import OrderSupplementDetails from './OrderSupplementDetails.vue';
import { dateText, moneyText } from '../../worker/logic';
import type { SettlementSnapshot } from '../types';
defineProps<{ snapshot: SettlementSnapshot | null }>();
</script>
<template>
  <details class="settlement-snapshot">
    <summary>查看结算时凭证与原商品</summary>
    <template v-if="snapshot">
      <div class="snapshot-meta">
        <p>
          原订单号 <strong>{{ snapshot.order_number }}</strong>
        </p>
        <p>
          原作业 {{ snapshot.job?.title || snapshot.job_title }} · 版本
          {{ snapshot.job?.version ?? snapshot.job_version }}
        </p>
        <p>拍手 {{ snapshot.worker_name }}</p>
        <p v-if="snapshot.job">
          结算成本 ¥{{ moneyText(snapshot.job.cost_amount) }} · 返款 ¥{{
            moneyText(snapshot.job.refund_amount)
          }}
        </p>
        <p>原快递号 {{ snapshot.tracking_numbers?.join('、') }}</p>
      </div>
      <OrderPayoutDetails :payout="snapshot.payout" snapshot />
      <OrderSupplementDetails :note="snapshot.note" :photos="snapshot.photos" snapshot />
      <div class="admin-notice">
        以下为本次确认结算时保存的原凭证及商品。上方到货和商品区域显示当前入库信息。
      </div>
      <article
        v-for="receipt in snapshot.receipt_snapshots || []"
        :key="receipt.receipt_id"
        class="snapshot-receipt"
      >
        <strong>{{ receipt.tracking_number }}</strong>
        <p class="admin-subtle">
          凭证版本 {{ receipt.revision }} · 入库
          {{ dateText(receipt.created_at) }}<br />单据标识
          {{ receipt.document_key || receipt.receipt_id }}
        </p>
        <ProtectedImage
          v-if="receipt.image_sha256"
          :digest="receipt.image_sha256"
        />
        <p v-else class="admin-notice">本次结算时没有保存凭证图片。</p>
        <div class="admin-table-wrap">
          <table class="admin-table">
            <thead>
              <tr>
                <th>原商品编码</th>
                <th>原商品名称</th>
                <th>原数量</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="(item, index) in receipt.items" :key="index">
                <td>{{ item.product_code || '未编码' }}</td>
                <td>{{ item.product_name }}</td>
                <td>{{ item.quantity }}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </article>
      <p v-if="!snapshot.receipt_snapshots?.length" class="admin-notice">
        这条历史记录未保存原商品明细快照，无法从当前入库信息还原。
      </p>
      <details
        v-if="snapshot.job?.photo_sha256s?.length"
        class="snapshot-job-photos"
      >
        <summary>
          查看结算时作业照片（{{ snapshot.job.photo_sha256s.length }}张）
        </summary>
        <div>
          <ProtectedImage
            v-for="digest in snapshot.job.photo_sha256s"
            :key="digest"
            :digest="digest"
          />
        </div>
      </details>
    </template>
    <p v-else class="admin-notice">这条历史记录未保存可查看的凭证快照。</p>
  </details>
</template>
<style scoped>
.settlement-snapshot {
  flex-basis: 100%;
  min-width: 0;
  margin-top: 9px;
}
.settlement-snapshot > summary {
  cursor: pointer;
  color: #4a775b;
  font-size: 12px;
  min-height: 34px;
  line-height: 1.8;
}
.snapshot-meta {
  background: #f4f7f4;
  border-radius: 7px;
  padding: 12px;
  margin: 8px 0 12px;
}
.snapshot-meta p {
  display: block;
  margin: 4px 0;
  color: #7b8d7e;
  font-size: 11px;
  overflow-wrap: anywhere;
  line-height: 1.8;
}
.snapshot-meta strong {
  color: #3b6347;
}
.snapshot-receipt {
  border: 1px solid #e2e9e3;
  border-radius: 8px;
  padding: 13px;
  margin: 12px 0;
  min-width: 0;
}
.snapshot-receipt > strong {
  display: block;
  color: #416a50;
  font-size: 13px;
  overflow-wrap: anywhere;
}
.snapshot-receipt > p {
  margin: 9px 0;
  font-size: 10px;
  overflow-wrap: anywhere;
  line-height: 1.8;
}
.snapshot-receipt .admin-table-wrap {
  margin-top: 12px;
}
.snapshot-receipt td {
  overflow-wrap: anywhere;
}
.snapshot-job-photos > summary {
  cursor: pointer;
  font-size: 11px;
  color: #6b8b76;
  line-height: 1.8;
  padding: 7px 0;
}
.snapshot-job-photos > div {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(240px, 100%), 1fr));
  gap: 10px;
  margin-top: 10px;
}
</style>
