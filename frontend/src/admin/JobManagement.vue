<script setup lang="ts">
import { onBeforeUnmount, ref } from 'vue';
import { RouterLink } from 'vue-router';
import { listJobs } from './api';
import { errorText } from './logic';
import { moneyText, dateText } from '../worker/logic';
import JobEditor from './components/JobEditor.vue';
import JobShareLink from './components/JobShareLink.vue';
import type { AdminJob } from './types';
const rows = ref<AdminJob[]>([]);
const total = ref(0);
const page = ref(1);
const q = ref('');
const status = ref('');
const loading = ref(false);
const error = ref('');
const editorOpen = ref(false);
const editing = ref<AdminJob | null>(null);
let controller: AbortController | undefined;
async function load() {
  controller?.abort();
  const current = new AbortController();
  controller = current;
  loading.value = true;
  error.value = '';
  try {
    const result = await listJobs(
      {
        page: page.value,
        page_size: 12,
        q: q.value.trim() || undefined,
        status: status.value || undefined,
      },
      current.signal,
    );
    if (!current.signal.aborted) {
      rows.value = result.items;
      total.value = result.total;
    }
  } catch (failure) {
    if (!current.signal.aborted) error.value = errorText(failure);
  } finally {
    if (!current.signal.aborted) loading.value = false;
  }
}
function search() {
  page.value = 1;
  void load();
}
function create() {
  editing.value = null;
  editorOpen.value = true;
}
function edit(job: AdminJob) {
  editing.value = job;
  editorOpen.value = true;
}
void load();
onBeforeUnmount(() => controller?.abort());
</script>
<template>
  <section class="admin-section">
    <div class="admin-heading">
      <div>
        <h1>作业管理</h1>
        <p>发布作业后，拍手登录本店即可直接报单，无需报名。</p>
      </div>
      <button class="admin-btn primary" @click="create">＋ 创建作业</button>
    </div>
    <form class="admin-toolbar" @submit.prevent="search">
      <input
        v-model="q"
        class="admin-input"
        placeholder="搜索作业名称"
        aria-label="搜索作业"
        maxlength="150"
      /><select
        v-model="status"
        class="admin-input"
        aria-label="作业开放状态"
        @change="search"
      >
        <option value="">全部作业</option>
        <option value="open">开放报单</option>
        <option value="closed">已关闭</option></select
      ><button class="admin-btn primary" :disabled="loading">查询</button
      ><button
        type="button"
        class="admin-btn"
        :disabled="loading"
        @click="load"
      >
        刷新
      </button>
    </form>
    <div v-if="error" class="admin-error" role="alert">{{ error }}</div>
    <div v-if="loading" class="admin-empty">正在读取作业…</div>
    <div v-else-if="!rows.length" class="admin-empty">
      暂无匹配作业，点击“创建作业”开始发布。
    </div>
    <div v-else class="admin-job-grid">
      <article v-for="job in rows" :key="job.id" class="admin-job-card">
        <div class="job-card-heading">
          <span
            class="admin-badge"
            :class="{ closed: job.status === 'closed' }"
            >{{ job.status === 'open' ? '开放报单' : '已关闭' }}</span
          ><small>{{ job.order_count }} 笔报单</small>
        </div>
        <h2>{{ job.title }}</h2>
        <p class="job-card-description">
          {{ job.description || '暂无附加说明' }}
        </p>
        <div class="job-card-money">
          <div>
            <span>作业成本</span
            ><strong>¥{{ moneyText(job.cost_amount) }}</strong>
          </div>
          <div>
            <span>返款金额</span
            ><strong>¥{{ moneyText(job.refund_amount) }}</strong>
          </div>
        </div>
        <div class="admin-actions">
          <RouterLink class="admin-btn primary" :to="`/shop/jobs/${job.id}`"
            >订单、快递与结算</RouterLink
          ><button class="admin-btn" @click="edit(job)">编辑作业</button><JobShareLink :job-id="job.id" :job-title="job.title" />
        </div>
        <small class="job-updated"
          >更新 {{ dateText(job.updated_at) }} ·
          {{ job.photos.length }} 张作业照片</small
        >
      </article>
    </div>
    <div class="admin-pagination">
      <span>共 {{ total }} 个作业</span
      ><button
        class="admin-btn"
        :disabled="page === 1 || loading"
        @click="
          page--;
          load();
        "
      >
        上一页</button
      ><span>{{ page }}</span
      ><button
        class="admin-btn"
        :disabled="page * 12 >= total || loading"
        @click="
          page++;
          load();
        "
      >
        下一页
      </button>
    </div>
    <JobEditor v-model="editorOpen" :job="editing" @saved="load" />
  </section>
</template>
<style scoped>
.admin-job-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(min(310px, 100%), 1fr));
  gap: 17px;
}
.admin-job-card {
  border: 1px solid #e2e9e4;
  border-radius: 11px;
  padding: 20px;
}
.job-card-heading {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}
.job-card-heading small {
  font-size: 11px;
  color: #91a193;
}
.admin-job-card h2 {
  font-size: 18px;
  font-weight: 700;
  color: #345b43;
  margin: 17px 0 10px;
  overflow-wrap: anywhere;
}
.job-card-description {
  font-size: 12px;
  color: #85998a;
  line-height: 1.8;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
  min-height: 43px;
}
.job-card-money {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 10px;
  padding: 14px 0 18px;
  border-bottom: 1px solid #edf2ee;
  margin-bottom: 16px;
}
.job-card-money > div {
  display: flex;
  flex-direction: column;
  gap: 5px;
}
.job-card-money span {
  font-size: 10px;
  color: #91a394;
}
.job-card-money strong {
  font-size: 20px;
  color: #316447;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}
.job-updated {
  display: block;
  color: #a0afa2;
  font-size: 10px;
  margin-top: 17px;
}
.admin-job-card .admin-actions .admin-btn {
  font-size: 11px;
}
</style>
