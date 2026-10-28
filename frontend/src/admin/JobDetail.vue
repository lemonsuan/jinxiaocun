<script setup lang="ts">
import { onBeforeUnmount, ref, watch } from 'vue';
import { RouterLink, useRoute } from 'vue-router';
import { getJob } from './api';
import { errorText } from './logic';
import { moneyText } from '../worker/logic';
import type { AdminJob } from './types';
import JobEditor from './components/JobEditor.vue';
import JobOrdersPanel from './components/JobOrdersPanel.vue';
import ProtectedImage from '../components/ProtectedImage.vue';
const route = useRoute();
const job = ref<AdminJob | null>(null);
const loading = ref(false);
const error = ref('');
const editing = ref(false);
let controller: AbortController | undefined;
async function load() {
  controller?.abort();
  const current = new AbortController();
  controller = current;
  loading.value = true;
  error.value = '';
  try {
    const result = await getJob(String(route.params.jobId), current.signal);
    if (!current.signal.aborted) job.value = result;
  } catch (failure) {
    if (!current.signal.aborted) error.value = errorText(failure);
  } finally {
    if (!current.signal.aborted) loading.value = false;
  }
}
watch(() => route.params.jobId, load, { immediate: true });
onBeforeUnmount(() => controller?.abort());
</script>
<template>
  <div>
    <RouterLink class="job-back" to="/shop/jobs">← 返回作业列表</RouterLink>
    <div v-if="loading" class="admin-empty">正在打开作业…</div>
    <div v-else-if="error" class="admin-error">{{ error }}</div>
    <template v-if="job"
      ><section class="admin-section job-overview">
        <div class="admin-heading">
          <div>
            <h1>{{ job.title }}</h1>
            <p>
              <span
                class="admin-badge"
                :class="{ closed: job.status === 'closed' }"
                >{{ job.status === 'open' ? '开放报单' : '已关闭' }}</span
              >
              · {{ job.order_count }} 笔报单
            </p>
          </div>
          <button class="admin-btn" @click="editing = true">编辑作业</button>
        </div>
        <div class="job-detail-money">
          <div>
            <span>作业成本</span
            ><strong>¥{{ moneyText(job.cost_amount) }}</strong>
          </div>
          <div>
            <span>返款金额</span
            ><strong>¥{{ moneyText(job.refund_amount) }}</strong>
          </div>
        </div>
        <p class="job-description">{{ job.description || '暂无附加说明' }}</p>
        <details v-if="job.photos.length" class="job-photo-details">
          <summary>查看 {{ job.photos.length }} 张作业照片</summary>
          <div class="job-photo-grid">
            <ProtectedImage
              v-for="photo in job.photos"
              :key="photo.sha256"
              :digest="photo.sha256"
            />
          </div>
        </details>
      </section>
      <JobOrdersPanel :job-id="job.id" /><JobEditor
        v-model="editing"
        :job="job"
        @saved="load"
    /></template>
  </div>
</template>
<style scoped>
.job-back {
  display: inline-block;
  margin: 0 0 16px;
  color: #678673;
  font-size: 12px;
  text-decoration: none;
}
.job-overview {
  margin-bottom: 22px;
}
.job-detail-money {
  display: flex;
  gap: 40px;
  margin-bottom: 20px;
}
.job-detail-money > div {
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.job-detail-money span {
  font-size: 11px;
  color: #91a393;
}
.job-detail-money strong {
  font-size: 24px;
  color: #356548;
  font-weight: 700;
}
.job-description {
  font-size: 13px;
  line-height: 1.9;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  color: #7b907f;
}
.job-photo-details {
  border-top: 1px solid #e5ede7;
  padding-top: 15px;
  margin-top: 20px;
}
.job-photo-details summary {
  cursor: pointer;
  font-size: 12px;
  color: #668974;
  min-height: 30px;
}
.job-photo-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(250px, 100%), 1fr));
  gap: 12px;
  padding-top: 12px;
}
</style>
