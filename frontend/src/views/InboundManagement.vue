<script setup lang="ts">
import { ref } from 'vue';
import InventoryViewer from '../components/InventoryViewer.vue';
import InboundBatchViewer from '../admin/components/InboundBatchViewer.vue';
const tab = ref('batch');
</script>
<template>
  <div>
    <div class="inbound-tabs" role="tablist" aria-label="入库查看方式">
      <button
        role="tab"
        :aria-selected="tab === 'batch'"
        :class="{ active: tab === 'batch' }"
        @click="tab = 'batch'"
      >
        批量查单看图与商品汇总</button
      ><button
        role="tab"
        :aria-selected="tab === 'list'"
        :class="{ active: tab === 'list' }"
        @click="tab = 'list'"
      >
        常规入库记录
      </button>
    </div>
    <InboundBatchViewer v-if="tab === 'batch'" /><InventoryViewer
      v-else
      collection="inbound"
      title="入库记录"
    />
  </div>
</template>
<style scoped>
.inbound-tabs {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
  margin-bottom: 18px;
}
.inbound-tabs button {
  border: 1px solid #dce6de;
  background: #fff;
  border-radius: 7px;
  color: #8a9d8e;
  padding: 11px 15px;
  font-size: 12px;
  cursor: pointer;
}
.inbound-tabs button.active {
  color: #fff;
  background: #4f7c5e;
  border-color: #4f7c5e;
}
</style>
