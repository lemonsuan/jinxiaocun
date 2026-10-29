<script setup lang="ts">
import { ref, watch } from 'vue';
import { saveJob, uploadJobPhoto } from '../api';
import { errorText } from '../logic';
import { moneyText } from '../../worker/logic';
import ProtectedImage from '../../components/ProtectedImage.vue';
import type { AdminJob, JobInput } from '../types';
const props = defineProps<{ modelValue: boolean; job: AdminJob | null }>();
const emit = defineEmits<{
  'update:modelValue': [boolean];
  saved: [AdminJob];
}>();
const form = ref<JobInput>({
  title: '',
  description: '',
  cost_amount: '0.00',
  refund_amount: '0.00',
  status: 'open',
  photo_sha256s: [],
});
const error = ref('');
const busy = ref(false);
const uploading = ref(false);
const fileInput = ref<HTMLInputElement | null>(null);
watch(
  () => props.modelValue,
  (open) => {
    if (!open) return;
    error.value = '';
    const job = props.job;
    form.value = job
      ? {
          title: job.title,
          description: job.description,
          cost_amount: job.cost_amount,
          refund_amount: job.refund_amount,
          status: job.status,
          photo_sha256s: job.photos.map((photo) => photo.sha256),
        }
      : {
          title: '',
          description: '',
          cost_amount: '0.00',
          refund_amount: '0.00',
          status: 'open',
          photo_sha256s: [],
        };
  },
);
function close() {
  if (!busy.value && !uploading.value) emit('update:modelValue', false);
}
async function upload(event: Event) {
  const input = event.target as HTMLInputElement;
  const files = [...(input.files || [])];
  input.value = '';
  if (form.value.photo_sha256s.length + files.length > 10) {
    error.value = '每个作业最多10张照片。';
    return;
  }
  uploading.value = true;
  error.value = '';
  try {
    for (const file of files) {
      if (file.size > 15 * 1024 * 1024) {
        error.value = `“${file.name}”超过15MB，请压缩后再上传。`;
        continue;
      }
      const result = await uploadJobPhoto(file);
      if (!form.value.photo_sha256s.includes(result.sha256))
        form.value.photo_sha256s.push(result.sha256);
    }
  } catch (failure) {
    error.value = errorText(failure);
  } finally {
    uploading.value = false;
  }
}
async function save() {
  if (busy.value || uploading.value) return;
  if (!form.value.title.trim()) {
    error.value = '请填写作业名称。';
    return;
  }
  if (
    !/^\d{1,10}(\.\d{1,2})?$/.test(form.value.cost_amount) ||
    !/^\d{1,10}(\.\d{1,2})?$/.test(form.value.refund_amount)
  ) {
    error.value = '金额需为不小于0的数字，最多两位小数。';
    return;
  }
  busy.value = true;
  error.value = '';
  try {
    const result = await saveJob(
      {
        ...form.value,
        title: form.value.title.trim(),
        cost_amount: moneyText(form.value.cost_amount),
        refund_amount: moneyText(form.value.refund_amount),
      },
      props.job?.id,
      props.job?.version,
    );
    emit('saved', result);
    emit('update:modelValue', false);
  } catch (failure) {
    error.value = errorText(failure);
  } finally {
    busy.value = false;
  }
}
</script>
<template>
  <el-dialog
    :model-value="modelValue"
    :title="job ? '编辑作业' : '创建作业'"
    width="min(720px,95vw)"
    :close-on-click-modal="!busy && !uploading"
    :close-on-press-escape="!busy && !uploading"
    :show-close="!busy && !uploading"
    @close="close"
    ><form @submit.prevent="save">
      <div class="admin-dialog-body">
        <label class="admin-form-field"
          ><span>作业名称</span
          ><input
            v-model="form.title"
            class="admin-input"
            placeholder="填写便于拍手辨认的作业名称"
            maxlength="150"
            :disabled="busy" /></label
        ><label class="admin-form-field"
          ><span>作业说明</span
          ><textarea
            v-model="form.description"
            class="admin-input"
            rows="4"
            maxlength="10000"
            placeholder="填写商品、下单或报单要求"
            :disabled="busy"
          />
        </label>
        <div class="admin-two-columns">
          <label class="admin-form-field"
            ><span>作业成本（元）</span
            ><input
              v-model="form.cost_amount"
              class="admin-input"
              inputmode="decimal"
              :disabled="busy" /></label
          ><label class="admin-form-field"
            ><span>返款金额（元）</span
            ><input
              v-model="form.refund_amount"
              class="admin-input"
              inputmode="decimal"
              :disabled="busy"
          /></label>
        </div>
        <label class="admin-form-field"
          ><span>作业状态</span
          ><select v-model="form.status" class="admin-input" :disabled="busy">
            <option value="open">开放报单</option>
            <option value="closed">关闭新报单</option></select
          ><small
            >关闭后不接收新订单，已有未结算订单仍可补充快递。</small
          ></label
        >
        <div class="admin-form-field">
          <span>作业照片（{{ form.photo_sha256s.length }}/10）</span
          ><input
            ref="fileInput"
            class="photo-file-input"
            type="file"
            accept="image/jpeg,image/png,image/webp"
            multiple
            @change="upload"
          /><button
            type="button"
            class="admin-btn"
            :disabled="uploading || busy || form.photo_sha256s.length >= 10"
            @click="fileInput?.click()"
          >
            {{ uploading ? '正在上传…' : '＋ 上传作业照片' }}</button
          ><small
            >支持JPEG、PNG、WebP，每张不超过15MB；用于管理员留档核对。拍手端仅展示作业文字与金额。</small
          >
          <div class="editor-photo-grid">
            <div
              v-for="(digest, index) in form.photo_sha256s"
              :key="digest"
              class="editor-photo"
            >
              <ProtectedImage :digest="digest" /><button
                class="admin-btn danger"
                type="button"
                :disabled="busy || uploading"
                @click="form.photo_sha256s.splice(index, 1)"
              >
                移除此照片
              </button>
            </div>
          </div>
        </div>
        <div v-if="job" class="admin-notice">
          修改作业金额不会改写历史结算记录。已结算订单以确认时的金额为准。
        </div>
        <div v-if="error" class="admin-error" role="alert">{{ error }}</div>
      </div>
      <div class="admin-dialog-footer">
        <button
          type="button"
          class="admin-btn"
          :disabled="busy || uploading"
          @click="close"
        >
          取消</button
        ><button class="admin-btn primary" :disabled="busy || uploading">
          {{ busy ? '保存中…' : job ? '保存作业修改' : '创建并发布作业' }}
        </button>
      </div>
    </form></el-dialog
  >
</template>
<style scoped>
.photo-file-input {
  display: none;
}
.editor-photo-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 12px;
  margin-top: 14px;
}
.editor-photo {
  min-width: 0;
}
.editor-photo > .admin-btn {
  margin-top: 8px;
  font-size: 10px;
  min-height: 32px;
}
@media (max-width: 500px) {
  .editor-photo-grid {
    grid-template-columns: 1fr;
  }
}
</style>
