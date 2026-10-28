<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue';
import { useRouter, useRoute } from 'vue-router';
import {
  Box,
  Goods,
  Download,
  Upload,
  Memo,
  UserFilled,
  DocumentChecked,
} from '@element-plus/icons-vue';
import { useAuthStore } from '../store/auth';
import request from '../utils/request';
import { copyVisibleText } from '../admin/logic';
const router = useRouter();
const route = useRoute();
const auth = useAuthStore();
const menuOpen = ref(false);
const copied = ref(false);
const items = [
  { path: '/shop/stock', title: '即时库存', icon: Box },
  { path: '/shop/products', title: '商品清单', icon: Goods },
  { path: '/shop/inbound', title: '入库记录', icon: Download },
  { path: '/shop/outbound', title: '出库记录', icon: Upload },
  { path: '/shop/jobs', title: '作业管理', icon: DocumentChecked },
  { path: '/shop/orders', title: '报单与结算', icon: Memo },
  { path: '/shop/members', title: '人员与注册链接', icon: UserFilled },
  { path: '/shop/ledger', title: '库存流水', icon: Memo },
  { path: '/shop/logs', title: '操作记录', icon: Memo },
];
const title = computed(
  () =>
    items.find((item) => route.path.startsWith(item.path))?.title || '店铺管理',
);
watch(
  () => route.path,
  () => (menuOpen.value = false),
);
function switchShop() {
  auth.clearShop();
  void router.push('/');
}
function logout() {
  auth.logout();
  void router.push('/login');
}
async function copyId() {
  copied.value = await copyVisibleText(auth.activeShopNumber);
  setTimeout(() => (copied.value = false), 1800);
}
onMounted(async () => {
  if (auth.activeShopNumber) return;
  try {
    const rows = await request.get<
      never,
      {
        shop_id: string;
        shop_name: string;
        shop_number: string;
        role: string;
        status: string;
      }[]
    >('/api/shops/my-shops');
    const shop = rows.find(
      (row) => row.shop_id === auth.activeShopId && row.status === 'APPROVED',
    );
    if (shop)
      auth.setActiveShop(
        shop.shop_id,
        shop.shop_name,
        shop.role,
        shop.shop_number,
      );
  } catch {
    /* 请求层负责失效反馈，保留可返回店铺列表的入口。 */
  }
});
</script>
<template>
  <div class="shop-layout">
    <button
      v-if="menuOpen"
      class="shop-menu-shade"
      aria-label="关闭导航菜单"
      @click="menuOpen = false"
    />
    <aside class="shop-sidebar" :class="{ open: menuOpen }">
      <div class="shop-brand">
        <span>🏪</span>
        <div>
          <strong>{{ auth.activeShopName }}</strong
          ><button @click="copyId">
            店铺 ID {{ auth.activeShopNumber || '—' }}
            {{ copied ? '· 已复制' : '' }}
          </button>
        </div>
      </div>
      <nav>
        <RouterLink
          v-for="item in items"
          :key="item.path"
          :to="item.path"
          :class="{ active: route.path.startsWith(item.path) }"
          ><el-icon><component :is="item.icon" /></el-icon
          ><span>{{ item.title }}</span></RouterLink
        >
      </nav>
      <div class="shop-sidebar-footer">
        <button @click="switchShop">↩ 切换管理店铺</button>
      </div>
    </aside>
    <div class="shop-body">
      <header class="shop-topbar">
        <div class="shop-topbar-title">
          <button
            class="shop-menu-button"
            aria-label="打开导航菜单"
            @click="menuOpen = true"
          >
            ☰</button
          ><span>{{ title }}</span>
        </div>
        <div class="shop-account">
          <span
            >{{ auth.username }}
            <small>{{
              auth.activeShopRole === 'CREATOR' ? '创建人' : '管理员'
            }}</small></span
          ><button @click="logout">退出登录</button>
        </div>
      </header>
      <main class="shop-main">
        <RouterView
          :key="`${auth.activeShopId}:${auth.scopeVersion}:${route.path}`"
        />
      </main>
    </div>
  </div>
</template>
<style src="../admin/admin.css"></style>
<style scoped>
.shop-layout {
  min-height: 100dvh;
  display: flex;
  background: #f6f8f7;
}
.shop-sidebar {
  width: 230px;
  flex: none;
  background: white;
  border-right: 1px solid #e2e9e5;
  display: flex;
  flex-direction: column;
  position: sticky;
  top: 0;
  height: 100dvh;
  z-index: 120;
}
.shop-brand {
  display: flex;
  align-items: center;
  gap: 11px;
  padding: 24px 19px;
  border-bottom: 1px solid #e9eeeb;
  min-width: 0;
}
.shop-brand > span {
  font-size: 23px;
}
.shop-brand > div {
  min-width: 0;
}
.shop-brand strong {
  font-size: 14px;
  display: block;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  color: #264b37;
}
.shop-brand button {
  border: 0;
  background: none;
  padding: 7px 0 0;
  font-size: 10px;
  color: #839488;
  cursor: pointer;
  text-align: left;
}
.shop-sidebar nav {
  padding: 20px 12px;
  flex: 1;
  overflow-y: auto;
}
.shop-sidebar nav a {
  display: flex;
  align-items: center;
  gap: 11px;
  padding: 12px 15px;
  margin-bottom: 5px;
  border-radius: 7px;
  color: #718276;
  font-size: 12px;
  text-decoration: none;
  font-weight: 600;
}
.shop-sidebar nav a.active {
  background: #edf7f1;
  color: #0f766e;
}
.shop-sidebar nav a:hover {
  background: #f5f8f5;
}
.shop-sidebar-footer {
  padding: 17px;
  border-top: 1px solid #e6ece8;
}
.shop-sidebar-footer button {
  width: 100%;
  border: 1px solid #dce5df;
  border-radius: 7px;
  min-height: 40px;
  background: white;
  font-size: 11px;
  color: #718777;
}
.shop-body {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
}
.shop-topbar {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 12px;
  background: white;
  border-bottom: 1px solid #e2e9e5;
  min-height: 69px;
  padding: 12px 28px;
  box-sizing: border-box;
}
.shop-topbar-title {
  display: flex;
  gap: 12px;
  align-items: center;
  font-size: 13px;
  color: #526e5b;
  min-width: 0;
}
.shop-account {
  display: flex;
  gap: 16px;
  align-items: center;
  font-size: 11px;
  color: #6f8375;
  flex-wrap: wrap;
}
.shop-account small {
  color: #a1afa4;
  font-size: 10px;
  margin-left: 4px;
}
.shop-account button {
  background: none;
  border: 0;
  padding: 9px 0;
  color: #a65d61;
  font-size: 11px;
}
.shop-main {
  padding: 27px;
  min-width: 0;
  flex: 1;
}
.shop-menu-button {
  display: none;
  min-height: 40px;
  min-width: 40px;
  border: 1px solid #dce7df;
  background: white;
  border-radius: 7px;
  color: #51725d;
}
.shop-menu-shade {
  position: fixed;
  inset: 0;
  background: #12312350;
  border: 0;
  z-index: 110;
}
@media (max-width: 900px) {
  .shop-sidebar {
    position: fixed;
    left: 0;
    transform: translateX(-100%);
    transition: transform 0.18s;
  }
  .shop-sidebar.open {
    transform: none;
  }
  .shop-menu-button {
    display: block;
  }
  .shop-topbar {
    padding: 10px 14px;
  }
  .shop-main {
    padding: 16px 12px;
  }
  .shop-account {
    gap: 10px;
  }
  .shop-account small {
    display: none;
  }
}
</style>
