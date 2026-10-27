<script setup lang="ts">
import { ref, watch, onBeforeUnmount } from 'vue'
import { useAuthStore } from '../store/auth'
import request from '../utils/request'
const props = defineProps<{ digest: string }>()
const auth = useAuthStore()
const url = ref('')
const failed = ref(false)
let controller: AbortController | undefined
function clear() { controller?.abort(); if (url.value) URL.revokeObjectURL(url.value); url.value = '' }
watch(() => [props.digest, auth.token, auth.activeShopId, auth.scopeVersion], async (_value, _old, onCleanup) => {
  clear(); failed.value = false
  const current = new AbortController(); controller = current
  onCleanup(() => current.abort())
  if (!/^[a-f0-9]{64}$/.test(props.digest) || !auth.token || !auth.activeShopId) { failed.value = true; return }
  try {
    const blob = await request.get<never, Blob>(`/api/sync/v2/media/${props.digest}`, { responseType: 'blob', signal: current.signal })
    if (!current.signal.aborted) url.value = URL.createObjectURL(blob)
  } catch { if (!current.signal.aborted) failed.value = true }
}, { immediate: true })
onBeforeUnmount(clear)
</script>
<template>
  <el-image v-if="url" :src="url" :preview-src-list="[url]" fit="contain" class="proof-image" :preview-teleported="true" />
  <div v-else class="proof-placeholder">{{ failed ? '图片暂不可用，请重新打开详情重试' : '正在加载凭证…' }}</div>
</template>
<style scoped>
.proof-image,.proof-placeholder { width: 100%; height: 260px; border: 1px solid #e2e8f0; border-radius: 6px; background: #f8fafc; }
.proof-placeholder { display: grid; place-items: center; color: #64748b; font-size: 12px; }
</style>
