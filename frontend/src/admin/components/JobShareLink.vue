<script setup lang="ts">
import { computed, ref } from 'vue';
import { useAuthStore } from '../../store/auth';
import { copyVisibleText, jobReportLink } from '../logic';
const props = defineProps<{ jobId: string; jobTitle?: string }>();
const auth = useAuthStore();
const message = ref('');
const manualOpen = ref(false);
const copying = ref(false);
const link = computed(() => jobReportLink(
  import.meta.env.VITE_PUBLIC_APP_URL || window.location.origin,
  auth.activeShopNumber,
  props.jobId,
));
async function copy() {
  if (copying.value || !link.value) return;
  copying.value = true;
  try {
    if (await copyVisibleText(link.value)) message.value = '填报链接已复制';
    else {
      message.value = '请在弹窗中全选复制链接';
      manualOpen.value = true;
    }
  } finally { copying.value = false; }
}
function select(event: Event) { (event.target as HTMLInputElement).select(); }
</script>
<template>
  <span class="job-share">
    <button type="button" class="admin-btn" :disabled="copying || !link" @click="copy">
      {{ copying ? '正在复制…' : '复制填报链接' }}
    </button>
    <small v-if="message" role="status">{{ message }}</small>
    <el-dialog v-model="manualOpen" title="复制本作业填报链接" width="min(560px,92vw)" append-to-body>
      <p>{{ jobTitle || '本作业' }}</p>
      <p class="admin-subtle">拍手打开后登录或注册，即可进入这个作业。</p>
      <input class="admin-input" :value="link" readonly aria-label="本作业填报链接" @focus="select" @click="select" />
      <div class="admin-dialog-footer"><button class="admin-btn primary" @click="manualOpen = false">完成</button></div>
    </el-dialog>
  </span>
</template>
<style scoped>
.job-share { display: inline-flex; flex-wrap: wrap; align-items: center; gap: 6px; max-width: 100%; }
.job-share small { font-size: 11px; color: #47735b; }
.job-share input { width: 100%; }
</style>
