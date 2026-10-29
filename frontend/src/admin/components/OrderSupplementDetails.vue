<script setup lang="ts">
import type { WorkerMedia } from '../../worker/types';
import ProtectedImage from '../../components/ProtectedImage.vue';
defineProps<{ note?: string; photos?: WorkerMedia[]; snapshot?: boolean }>();
</script>
<template>
  <section v-if="note || photos?.length" class="order-supplement">
    <h3>{{ snapshot ? '结算时拍手补充资料' : '拍手补充资料' }}</h3>
    <p v-if="note" class="supplement-note">{{ note }}</p>
    <details v-if="photos?.length">
      <summary>查看补充照片（{{ photos.length }} 张）</summary>
      <div class="supplement-photos">
        <figure v-for="(photo, index) in photos" :key="photo.sha256">
          <ProtectedImage :digest="photo.sha256" />
          <figcaption>{{ photo.name || `补充照片 ${index + 1}` }}</figcaption>
        </figure>
      </div>
    </details>
  </section>
</template>
<style scoped>
.order-supplement { padding: 14px; border: 1px solid #dce7df; border-radius: 8px; margin-top: 16px; min-width: 0; }
h3 { margin: 0 0 10px; color: #355b42; font-size: 14px; font-weight: 650; }
.supplement-note { white-space: pre-wrap; overflow-wrap: anywhere; font-size: 12px; line-height: 1.9; color: #5e7867; margin: 0; }
summary { cursor: pointer; color: #35684c; font-size: 12px; padding: 10px 0; }
.supplement-photos { display: grid; grid-template-columns: repeat(auto-fit,minmax(min(220px,100%),1fr)); gap: 12px; }
figure { min-width: 0; margin: 0; }
figcaption { color: #85968b; font-size: 11px; margin-top: 5px; overflow-wrap: anywhere; }
</style>
