<script setup lang="ts">
import { onBeforeUnmount, ref } from 'vue';
import { useAuthStore } from '../store/auth';
import {
  listMembers,
  listWorkers,
  resetWorkerPassword,
  setMemberStatus,
  setWorkerEnabled,
} from '../admin/api';
import { errorText } from '../admin/logic';
import { dateText } from '../worker/logic';
import RegistrationLink from '../admin/components/RegistrationLink.vue';
import type { AdminWorker, Member } from '../admin/types';
const auth = useAuthStore();
const tab = ref<'workers' | 'admins'>('workers');
const workers = ref<AdminWorker[]>([]);
const members = ref<Member[]>([]);
const q = ref('');
const enabled = ref('');
const page = ref(1);
const total = ref(0);
const loading = ref(false);
const busy = ref(false);
const error = ref('');
const notice = ref('');
const resetting = ref<AdminWorker | null>(null);
const password = ref('');
const repeat = ref('');
let controller: AbortController | undefined;
async function fetchRows() {
  controller?.abort();
  const current = new AbortController();
  controller = current;
  loading.value = true;
  error.value = '';
  try {
    if (tab.value === 'admins')
      members.value = await listMembers(current.signal);
    else {
      const result = await listWorkers(
        {
          page: page.value,
          page_size: 20,
          q: q.value.trim() || undefined,
          enabled: enabled.value ? enabled.value === 'true' : undefined,
        },
        current.signal,
      );
      if (!current.signal.aborted) {
        workers.value = result.items;
        total.value = result.total;
      }
    }
  } catch (failure) {
    if (!current.signal.aborted) error.value = errorText(failure);
  } finally {
    if (!current.signal.aborted) loading.value = false;
  }
}
function selectTab(value: 'workers' | 'admins') {
  tab.value = value;
  page.value = 1;
  void fetchRows();
}
function search() {
  page.value = 1;
  void fetchRows();
}
async function toggle(worker: AdminWorker) {
  if (busy.value) return;
  if (
    !window.confirm(
      worker.enabled
        ? `禁用“${worker.display_name || worker.username}”后，该拍手无法登录，已有会话也会失效；历史报单和结算保留。确定禁用？`
        : `重新启用“${worker.display_name || worker.username}”？该拍手需要重新登录。`,
    )
  )
    return;
  busy.value = true;
  error.value = '';
  try {
    await setWorkerEnabled(worker, !worker.enabled);
    notice.value = worker.enabled
      ? '拍手已禁用，历史资料保留。'
      : '拍手已重新启用，需要重新登录。';
    await fetchRows();
  } catch (failure) {
    error.value = errorText(failure);
  } finally {
    busy.value = false;
  }
}
function openReset(worker: AdminWorker) {
  resetting.value = worker;
  password.value = '';
  repeat.value = '';
  error.value = '';
}
async function reset() {
  if (!resetting.value || busy.value) return;
  if (password.value.length < 8 || password.value.length > 128) {
    error.value = '新密码长度需为8至128位。';
    return;
  }
  if (password.value !== repeat.value) {
    error.value = '两次填写的新密码不一致。';
    return;
  }
  busy.value = true;
  error.value = '';
  try {
    await resetWorkerPassword(resetting.value, password.value);
    resetting.value = null;
    password.value = '';
    repeat.value = '';
    notice.value = '密码已重置，旧登录已失效。请将新密码告知该拍手。';
    await fetchRows();
  } catch (failure) {
    error.value = errorText(failure);
  } finally {
    busy.value = false;
  }
}
async function updateAdmin(member: Member, status: Member['status']) {
  if (busy.value) return;
  if (
    !window.confirm(
      status === 'APPROVED'
        ? `确认批准“${member.user.username}”成为本店管理员？`
        : `确认停止或拒绝“${member.user.username}”的本店管理员访问？`,
    )
  )
    return;
  busy.value = true;
  error.value = '';
  try {
    await setMemberStatus(member, status);
    notice.value = '管理员状态已更新。';
    await fetchRows();
  } catch (failure) {
    error.value = errorText(failure);
  } finally {
    busy.value = false;
  }
}
void fetchRows();
onBeforeUnmount(() => controller?.abort());
</script>
<template>
  <section class="admin-section">
    <div class="admin-heading">
      <div>
        <h1>人员与注册链接</h1>
        <p>店铺仅创建人、管理员、拍手三种角色。拍手只看自己的报单。</p>
      </div>
    </div>
    <RegistrationLink />
    <div class="member-tabs">
      <button
        :class="{ active: tab === 'workers' }"
        @click="selectTab('workers')"
      >
        拍手管理</button
      ><button
        :class="{ active: tab === 'admins' }"
        @click="selectTab('admins')"
      >
        管理人员
      </button>
    </div>
    <form
      v-if="tab === 'workers'"
      class="admin-toolbar"
      @submit.prevent="search"
    >
      <input
        v-model="q"
        class="admin-input"
        placeholder="搜索账号、称呼或电话"
        aria-label="搜索拍手"
        maxlength="100"
      /><select
        v-model="enabled"
        class="admin-input"
        aria-label="拍手启用状态"
        @change="search"
      >
        <option value="">全部状态</option>
        <option value="true">已启用</option>
        <option value="false">已禁用</option></select
      ><button class="admin-btn primary" :disabled="loading">查询</button
      ><button
        class="admin-btn"
        type="button"
        :disabled="loading"
        @click="fetchRows"
      >
        刷新
      </button>
    </form>
    <div v-if="error" class="admin-error" role="alert">{{ error }}</div>
    <div v-if="notice" class="admin-notice" role="status">{{ notice }}</div>
    <div v-if="loading" class="admin-empty">正在加载人员…</div>
    <template v-else-if="tab === 'workers'"
      ><div v-if="!workers.length" class="admin-empty">
        暂无匹配的拍手。复制上方注册链接即可邀请本店拍手注册。
      </div>
      <div class="worker-admin-grid">
        <article
          v-for="worker in workers"
          :key="worker.id"
          class="worker-admin-card"
        >
          <div class="worker-admin-title">
            <strong>{{ worker.display_name || worker.username }}</strong
            ><span class="admin-badge" :class="{ closed: !worker.enabled }">{{
              worker.enabled ? '已启用' : '已禁用'
            }}</span>
          </div>
          <p>
            账号 <span>{{ worker.username }}</span>
          </p>
          <p v-if="worker.phone">电话 {{ worker.phone }}</p>
          <small>注册 {{ dateText(worker.created_at) }}</small>
          <div class="admin-actions">
            <button
              class="admin-btn"
              :class="{ danger: worker.enabled }"
              :disabled="busy"
              @click="toggle(worker)"
            >
              {{ worker.enabled ? '禁用拍手' : '重新启用' }}</button
            ><button
              class="admin-btn"
              :disabled="busy"
              @click="openReset(worker)"
            >
              重置密码
            </button>
          </div>
        </article>
      </div>
      <div class="admin-pagination">
        <span>共 {{ total }} 位拍手</span
        ><button
          class="admin-btn"
          :disabled="page === 1 || loading"
          @click="
            page--;
            fetchRows();
          "
        >
          上一页</button
        ><span>{{ page }}</span
        ><button
          class="admin-btn"
          :disabled="page * 20 >= total || loading"
          @click="
            page++;
            fetchRows();
          "
        >
          下一页
        </button>
      </div></template
    ><template v-else
      ><div class="admin-notice">
        只有店铺创建人可以批准管理员申请或停止管理员权限。
      </div>
      <div class="worker-admin-grid">
        <article
          v-for="member in members"
          :key="member.id"
          class="worker-admin-card"
        >
          <div class="worker-admin-title">
            <strong>{{ member.user.username }}</strong
            ><span class="admin-badge">{{
              member.role === 'CREATOR' ? '创建人' : '管理员'
            }}</span>
          </div>
          <p>
            {{
              member.status === 'APPROVED'
                ? '已批准'
                : member.status === 'PENDING'
                  ? '等待创建人批准'
                  : '未批准或已停用'
            }}
          </p>
          <small>加入 {{ dateText(member.joined_at) }}</small>
          <div
            v-if="auth.activeShopRole === 'CREATOR' && member.role === 'ADMIN'"
            class="admin-actions"
          >
            <button
              v-if="member.status !== 'APPROVED'"
              class="admin-btn primary"
              :disabled="busy"
              @click="updateAdmin(member, 'APPROVED')"
            >
              批准管理员</button
            ><button
              v-if="member.status !== 'REJECTED'"
              class="admin-btn danger"
              :disabled="busy"
              @click="updateAdmin(member, 'REJECTED')"
            >
              {{ member.status === 'PENDING' ? '拒绝申请' : '停止权限' }}
            </button>
          </div>
        </article>
      </div></template
    ><el-dialog
      :model-value="!!resetting"
      title="重置拍手密码"
      width="min(440px,95vw)"
      :close-on-click-modal="!busy"
      :close-on-press-escape="!busy"
      @close="
        resetting = null;
        password = '';
        repeat = '';
      "
      ><p class="admin-notice">
        为
        {{ resetting?.display_name || resetting?.username }}
        设置新密码。旧登录会立即失效；禁用账号不会因此自动启用。
      </p>
      <form @submit.prevent="reset">
        <label class="admin-form-field"
          ><span>新密码</span
          ><input
            v-model="password"
            class="admin-input"
            type="password"
            autocomplete="new-password"
            minlength="8"
            maxlength="128"
            :disabled="busy" /></label
        ><label class="admin-form-field"
          ><span>再次填写新密码</span
          ><input
            v-model="repeat"
            class="admin-input"
            type="password"
            autocomplete="new-password"
            minlength="8"
            maxlength="128"
            :disabled="busy"
        /></label>
        <div v-if="error" class="admin-error">{{ error }}</div>
        <div class="admin-dialog-footer">
          <button
            type="button"
            class="admin-btn"
            :disabled="busy"
            @click="
              resetting = null;
              password = '';
              repeat = '';
            "
          >
            取消</button
          ><button class="admin-btn primary" :disabled="busy">
            {{ busy ? '重置中…' : '确认重置' }}
          </button>
        </div>
      </form></el-dialog
    >
  </section>
</template>
<style scoped>
.member-tabs {
  display: flex;
  gap: 7px;
  margin-bottom: 20px;
  border-bottom: 1px solid #e8eeea;
  padding-bottom: 12px;
}
.member-tabs button {
  border: 0;
  background: #f2f6f3;
  padding: 11px 18px;
  border-radius: 7px;
  font-size: 12px;
  color: #85978b;
}
.member-tabs button.active {
  background: #e5f3eb;
  color: #26734c;
  font-weight: 650;
}
.worker-admin-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(min(270px, 100%), 1fr));
  gap: 14px;
}
.worker-admin-card {
  border: 1px solid #e2eae4;
  border-radius: 9px;
  padding: 17px;
}
.worker-admin-title {
  display: flex;
  justify-content: space-between;
  gap: 10px;
  align-items: flex-start;
}
.worker-admin-title strong {
  font-size: 14px;
  overflow-wrap: anywhere;
  min-width: 0;
  color: #305941;
}
.worker-admin-card p {
  font-size: 12px;
  color: #809485;
  margin: 10px 0;
  overflow-wrap: anywhere;
}
.worker-admin-card small {
  font-size: 10px;
  color: #a0afa3;
}
.worker-admin-card .admin-actions {
  margin-top: 17px;
}
.worker-admin-card .admin-actions button {
  font-size: 11px;
}
</style>
