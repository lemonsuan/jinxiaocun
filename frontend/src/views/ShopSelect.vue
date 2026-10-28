<script setup lang="ts">
import { onMounted, ref } from 'vue';
import { useRouter } from 'vue-router';
import request from '../utils/request';
import { useAuthStore } from '../store/auth';
import { copyVisibleText, errorText } from '../admin/logic';
import { validShopNumber } from '../worker/logic';
interface ShopRow {
  shop_id: string;
  shop_name: string;
  shop_number: string;
  role: 'CREATOR' | 'ADMIN';
  status: 'APPROVED' | 'PENDING' | 'REJECTED';
}
const auth = useAuthStore();
const router = useRouter();
const rows = ref<ShopRow[]>([]);
const loading = ref(false);
const error = ref('');
const notice = ref('');
const creating = ref(false);
const joining = ref(false);
const saving = ref(false);
const name = ref('');
const number = ref('');
async function fetchRows() {
  loading.value = true;
  error.value = '';
  try {
    rows.value = await request.get<never, ShopRow[]>('/api/shops/my-shops');
  } catch (failure) {
    error.value = errorText(failure);
  } finally {
    loading.value = false;
  }
}
function enter(row: ShopRow) {
  if (row.status !== 'APPROVED') return;
  auth.setActiveShop(row.shop_id, row.shop_name, row.role, row.shop_number);
  void router.push('/shop');
}
async function create() {
  if (saving.value || !name.value.trim()) return;
  saving.value = true;
  error.value = '';
  try {
    await request.post('/api/shops/create', { name: name.value.trim() });
    creating.value = false;
    name.value = '';
    await fetchRows();
  } catch (failure) {
    error.value = errorText(failure);
  } finally {
    saving.value = false;
  }
}
async function join() {
  if (saving.value) return;
  if (!validShopNumber(number.value.trim())) {
    error.value = '请输入10000起的数字店铺 ID。';
    return;
  }
  saving.value = true;
  error.value = '';
  try {
    const result = await request.post<never, { message?: string }>(
      '/api/shops/join',
      { shop_number: number.value.trim() },
    );
    joining.value = false;
    number.value = '';
    notice.value = result.message || '已申请管理员身份，请联系店铺创建人批准。';
    await fetchRows();
  } catch (failure) {
    error.value = errorText(failure);
  } finally {
    saving.value = false;
  }
}
async function copy(value: string) {
  notice.value = (await copyVisibleText(value))
    ? `店铺 ID ${value} 已复制。`
    : '浏览器未允许自动复制，可长按数字店铺 ID 选择复制。';
}
function logout() {
  auth.logout();
  void router.push('/login');
}
onMounted(fetchRows);
</script>
<template>
  <div class="shop-select-page">
    <header>
      <strong>🏪 店铺管理中心</strong>
      <div>
        <span>{{ auth.username }}</span
        ><button class="admin-btn" @click="logout">退出登录</button>
      </div>
    </header>
    <main>
      <div class="admin-heading">
        <div>
          <h1>选择管理店铺</h1>
          <p>
            创建人和管理员可以查看库存、管理作业与结算；拍手使用店铺专属注册入口。
          </p>
        </div>
        <div class="admin-actions">
          <button class="admin-btn" :disabled="loading" @click="fetchRows">
            刷新状态</button
          ><button
            class="admin-btn"
            @click="
              joining = true;
              error = '';
            "
          >
            申请管理员</button
          ><button
            class="admin-btn primary"
            @click="
              creating = true;
              error = '';
            "
          >
            新建店铺
          </button>
        </div>
      </div>
      <div v-if="error" class="admin-error" role="alert">{{ error }}</div>
      <div v-if="notice" class="admin-notice" role="status">{{ notice }}</div>
      <div v-if="loading" class="admin-empty">正在读取店铺…</div>
      <div v-else-if="!rows.length" class="admin-empty">
        当前没有可管理的店铺。<br />你可以创建店铺，或向现有店铺创建人申请管理员身份。
      </div>
      <div v-else class="shop-grid">
        <article
          v-for="row in rows"
          :key="row.shop_id"
          class="shop-select-card"
        >
          <div class="card-meta">
            <span
              class="admin-badge"
              :class="{ closed: row.status !== 'APPROVED' }"
              >{{
                row.status === 'APPROVED'
                  ? '可管理'
                  : row.status === 'PENDING'
                    ? '等待创建人批准'
                    : '未批准'
              }}</span
            ><small>{{ row.role === 'CREATOR' ? '创建人' : '管理员' }}</small>
          </div>
          <h2>{{ row.shop_name }}</h2>
          <div class="shop-code">
            店铺 ID <strong>{{ row.shop_number || '—' }}</strong
            ><button
              :disabled="!row.shop_number"
              @click="copy(row.shop_number)"
            >
              复制
            </button>
          </div>
          <button
            class="admin-btn primary"
            :disabled="row.status !== 'APPROVED'"
            @click="enter(row)"
          >
            进入店铺 →
          </button>
        </article>
      </div>
    </main>
    <el-dialog
      v-model="creating"
      title="新建店铺"
      width="min(440px,95vw)"
      :close-on-click-modal="!saving"
      :close-on-press-escape="!saving"
      ><form @submit.prevent="create">
        <label class="admin-form-field"
          ><span>店铺名称</span
          ><input
            v-model="name"
            class="admin-input"
            maxlength="100"
            placeholder="填写便于辨认的店铺名称"
            :disabled="saving"
        /></label>
        <p class="admin-notice">创建成功后自动分配10000起的数字店铺 ID。</p>
        <div v-if="error" class="admin-error">{{ error }}</div>
        <div class="admin-dialog-footer">
          <button
            type="button"
            class="admin-btn"
            :disabled="saving"
            @click="creating = false"
          >
            取消</button
          ><button
            class="admin-btn primary"
            type="submit"
            :disabled="saving || !name.trim()"
          >
            {{ saving ? '正在创建…' : '创建店铺' }}
          </button>
        </div>
      </form></el-dialog
    ><el-dialog
      v-model="joining"
      title="申请店铺管理员"
      width="min(440px,95vw)"
      :close-on-click-modal="!saving"
      :close-on-press-escape="!saving"
      ><form @submit.prevent="join">
        <label class="admin-form-field"
          ><span>数字店铺 ID</span
          ><input
            v-model="number"
            class="admin-input"
            inputmode="numeric"
            maxlength="19"
            placeholder="例如 10000"
            :disabled="saving"
        /></label>
        <p class="admin-notice">
          管理员申请需由该店铺创建人批准。拍手不需要申请管理员，请使用本店拍手注册链接注册。
        </p>
        <div v-if="error" class="admin-error">{{ error }}</div>
        <div class="admin-dialog-footer">
          <button
            class="admin-btn"
            type="button"
            :disabled="saving"
            @click="joining = false"
          >
            取消</button
          ><button class="admin-btn primary" type="submit" :disabled="saving">
            {{ saving ? '提交中…' : '提交管理员申请' }}
          </button>
        </div>
      </form></el-dialog
    >
  </div>
</template>
<style src="../admin/admin.css"></style>
<style scoped>
.shop-select-page {
  min-height: 100dvh;
  background: #f6f8f7;
  color: #284836;
}
.shop-select-page > header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 15px;
  padding: 18px max(20px, calc((100vw - 1100px) / 2));
  background: white;
  border-bottom: 1px solid #e1e9e3;
}
.shop-select-page > header strong {
  font-size: 16px;
}
.shop-select-page > header > div {
  display: flex;
  gap: 13px;
  align-items: center;
  font-size: 12px;
  color: #819587;
}
.shop-select-page > main {
  max-width: 1100px;
  padding: 32px 20px;
  margin: 0 auto;
}
.shop-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(min(285px, 100%), 1fr));
  gap: 19px;
}
.shop-select-card {
  background: white;
  border: 1px solid #e0e8e2;
  border-radius: 12px;
  padding: 23px;
}
.card-meta {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 9px;
}
.card-meta small {
  color: #9aa89e;
  font-size: 11px;
}
.shop-select-card h2 {
  font-size: 18px;
  margin: 22px 0 10px;
  overflow-wrap: anywhere;
  font-weight: 700;
}
.shop-code {
  display: flex;
  align-items: center;
  gap: 8px;
  color: #8c9b91;
  font-size: 11px;
  margin-bottom: 28px;
}
.shop-code strong {
  font-size: 18px;
  letter-spacing: 1px;
  color: #416a4f;
  user-select: all;
}
.shop-code button {
  border: 0;
  background: #f0f6f2;
  color: #5a8064;
  font-size: 10px;
  border-radius: 5px;
  padding: 6px;
}
.shop-select-card > .admin-btn {
  width: 100%;
}
@media (max-width: 500px) {
  .shop-select-page > header {
    padding: 14px;
  }
  .shop-select-page > header > div > span {
    display: none;
  }
  .shop-select-page > main {
    padding: 22px 14px;
  }
}
</style>
