<script setup lang="ts">
import { onBeforeUnmount, ref, watch } from 'vue';
import { loadJobPhoto } from '../api';
import { useWorkerStore } from '../store';
const props = defineProps<{ jobId: string; digest: string }>();
const auth = useWorkerStore();
const url = ref('');
const failed = ref(false);
const retry = ref(0);
let controller: AbortController | undefined;
function clear() {
  controller?.abort();
  if (url.value) URL.revokeObjectURL(url.value);
  url.value = '';
}
watch(
  () => [props.jobId, props.digest, auth.epoch, retry.value],
  async (_value, _old, onCleanup) => {
    clear();
    failed.value = false;
    const current = new AbortController();
    controller = current;
    onCleanup(() => current.abort());
    if (!auth.token || !/^[a-f0-9]{64}$/.test(props.digest)) {
      failed.value = true;
      return;
    }
    try {
      const blob = await loadJobPhoto(
        props.jobId,
        props.digest,
        current.signal,
      );
      if (!current.signal.aborted) url.value = URL.createObjectURL(blob);
    } catch {
      if (!current.signal.aborted) failed.value = true;
    }
  },
  { immediate: true },
);
onBeforeUnmount(clear);
</script>
<template>
  <el-image
    v-if="url"
    :src="url"
    :preview-src-list="[url]"
    :preview-teleported="true"
    fit="contain"
    class="worker-job-photo"
    alt="作业参考照片"
  />
  <div v-else class="worker-photo-placeholder">
    <span>{{ failed ? '照片暂时加载失败' : '正在加载照片…' }}</span
    ><button v-if="failed" type="button" @click="retry++">重新加载</button>
  </div>
</template>
<style scoped>
.worker-job-photo {
  display: block;
  width: 100%;
  height: 260px;
  border: 1px solid #e2e8f0;
  background: #f8fafc;
  border-radius: 12px;
}
.worker-photo-placeholder {
  min-height: 150px;
  border: 1px dashed #cbd5e1;
  background: #f8fafc;
  border-radius: 12px;
  display: flex;
  align-items: center;
  justify-content: center;
  flex-direction: column;
  gap: 12px;
  color: #64748b;
  font-size: 13px;
}
button {
  padding: 10px 18px;
  border: 1px solid #cbd5e1;
  background: white;
  color: #0f766e;
  border-radius: 8px;
}
</style>
