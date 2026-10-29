<script setup lang="ts">
import { workerStatusText } from '../logic';
import type { OrderStatus } from '../types';
defineProps<{ status: OrderStatus }>();
</script>
<template>
  <span class="worker-status" :class="status">{{ workerStatusText(status) }}</span>
</template>
<style scoped>
.worker-status {
  display: inline-flex;
  align-items: center;
  white-space: nowrap;
  border-radius: 999px;
  padding: 5px 10px;
  font-size: 12px;
  font-weight: 650;
}
.in_transit {
  color: #92400e;
  background: #fef3c7;
}
.arrived {
  color: #0369a1;
  background: #e0f2fe;
}
.settled {
  color: #047857;
  background: #d1fae5;
}
</style>
