<script setup lang="ts">
import { computed, ref } from 'vue';
import { RouterLink } from 'vue-router';
import { dateText, moneyText } from '../logic';
import type { WorkerOrder } from '../types';
import WorkerStatus from './WorkerStatus.vue';
import WorkerIcon from './WorkerIcon.vue';
import WorkerOrderModal from './WorkerOrderModal.vue';
const props = defineProps<{ orders: WorkerOrder[]; showJob?: boolean }>();
const emit = defineEmits<{ saved: [WorkerOrder] }>();
const expanded = ref<string[]>([]);
const editing = ref<WorkerOrder | null>(null);
const allExpanded = computed(() => props.orders.length > 0 && props.orders.every(x => expanded.value.includes(x.id)));
function toggle(id: string) { expanded.value = expanded.value.includes(id) ? expanded.value.filter(x => x !== id) : [...expanded.value, id]; }
function toggleAll() { expanded.value = allExpanded.value ? [] : props.orders.map(x => x.id); }
</script>
<template>
  <div v-if="orders.length" class="worker-list-tools"><button type="button" class="worker-button ghost" :aria-label="allExpanded ? '全部收起' : '全部展开'" :title="allExpanded ? '全部收起' : '全部展开'" @click="toggleAll"><WorkerIcon :name="allExpanded ? 'collapse' : 'expand'" />{{ allExpanded ? '全部收起' : '全部展开' }}</button></div>
  <article v-for="order in orders" :key="order.id" class="worker-order-row">
    <button type="button" class="worker-order-toggle" :aria-label="`${expanded.includes(order.id) ? '收起' : '展开'}订单 ${order.order_number}`" :aria-expanded="expanded.includes(order.id)" @click="toggle(order.id)">
      <span class="worker-order-overview">
        <span class="worker-order-number">{{ order.order_number }}</span>
        <span class="worker-order-brief">已到 {{ order.arrived_count }}/{{ order.parcel_count }} · {{ order.status === 'settled' ? '已返款' : '返款' }} ¥{{ moneyText(order.settlement?.refund_amount ?? order.job.refund_amount) }}</span>
        <span v-if="showJob" class="worker-order-job-name">{{ order.job.title }}</span>
      </span>
      <WorkerStatus :status="order.status" /><WorkerIcon :name="expanded.includes(order.id) ? 'collapse' : 'expand'" />
    </button>
    <div v-if="expanded.includes(order.id)">
      <RouterLink v-if="showJob" class="worker-order-job" :to="`/worker/jobs/${order.job.id}`">查看作业：{{ order.job.title }}<WorkerIcon name="next" /></RouterLink>
      <p v-if="order.status === 'settled'" class="worker-order-brief">返款时间 {{ dateText(order.settlement?.settled_at ?? order.settled_at) }}</p>
      <div class="worker-parcels"><div v-for="parcel in order.parcels" :key="parcel.id" class="worker-parcel"><span class="worker-parcel-number">{{ parcel.tracking_number }}</span><span class="worker-parcel-state" :class="{ arrived: parcel.arrived }">{{ parcel.arrived ? '已签收' : '运输中' }}</span></div></div>
      <p v-if="order.note" class="worker-order-note">{{ order.note }}</p>
      <p v-if="order.photos?.length" class="worker-muted">已上传 {{ order.photos.length }} 张补充照片</p>
      <button v-if="order.status !== 'settled'" type="button" class="worker-button secondary" :aria-label="`编辑订单 ${order.order_number}`" title="编辑订单" @click="editing = order"><WorkerIcon name="edit" />编辑订单</button>
    </div>
  </article>
  <WorkerOrderModal v-if="editing" :key="editing.id" :model-value="true" :job="editing.job" :order-id="editing.id" @update:model-value="editing = null" @saved="emit('saved', $event)" />
</template>
