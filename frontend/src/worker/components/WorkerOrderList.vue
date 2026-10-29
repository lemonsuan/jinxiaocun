<script setup lang="ts">
import { computed, ref } from 'vue';
import { RouterLink } from 'vue-router';
import { dateText, moneyText } from '../logic';
import type { WorkerOrder } from '../types';
import WorkerStatus from './WorkerStatus.vue';
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
  <div v-if="orders.length" class="worker-list-tools"><button class="worker-button ghost" @click="toggleAll">{{ allExpanded ? '全部收起' : '全部展开' }}</button></div>
  <article v-for="order in orders" :key="order.id" class="worker-order-row">
    <button type="button" class="worker-order-toggle" :aria-expanded="expanded.includes(order.id)" @click="toggle(order.id)"><span class="worker-order-number">{{ order.order_number }}</span><WorkerStatus :status="order.status" /><span aria-hidden="true">{{ expanded.includes(order.id) ? '⌃' : '⌄' }}</span></button>
    <RouterLink v-if="showJob" class="worker-order-job" :to="`/worker/jobs/${order.job.id}`">{{ order.job.title }}</RouterLink>
    <p class="worker-order-brief">快递已到 {{ order.arrived_count }}/{{ order.parcel_count }} · {{ order.status === 'settled' ? '已返款' : '返款' }} ¥{{ moneyText(order.settlement?.refund_amount ?? order.job.refund_amount) }}<span v-if="order.status === 'settled'"> · {{ dateText(order.settlement?.settled_at ?? order.settled_at) }}</span></p>
    <div v-if="expanded.includes(order.id)">
      <div class="worker-parcels"><div v-for="parcel in order.parcels" :key="parcel.id" class="worker-parcel"><span class="worker-parcel-number">{{ parcel.tracking_number }}</span><span class="worker-parcel-state" :class="{ arrived: parcel.arrived }">{{ parcel.arrived ? '已签收' : '运输中' }}</span></div></div>
      <p v-if="order.note" class="worker-order-note">{{ order.note }}</p>
      <p v-if="order.photos?.length" class="worker-muted">已上传 {{ order.photos.length }} 张补充照片</p>
      <button v-if="order.status !== 'settled'" class="worker-button secondary wide" @click="editing = order">编辑订单</button>
    </div>
  </article>
  <WorkerOrderModal v-if="editing" :key="editing.id" :model-value="true" :job="editing.job" :order-id="editing.id" @update:model-value="editing = null" @saved="emit('saved', $event)" />
</template>
