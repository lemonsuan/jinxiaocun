<template>
  <div class="min-h-screen bg-slate-50 flex">
    <!-- 左侧导航边栏 -->
    <aside class="w-64 bg-white border-r border-slate-200 flex flex-col shrink-0">
      
      <!-- 边栏头部 Logo -->
      <div class="h-16 border-b border-slate-200 flex items-center px-6 gap-3">
        <span class="text-xl">🏪</span>
        <div class="overflow-hidden">
          <h2 class="font-bold text-slate-800 text-sm truncate">{{ authStore.activeShopName }}</h2>
          <p class="text-[10px] text-slate-400 truncate">当前管理工坊</p>
        </div>
      </div>

      <!-- 导航项列表 -->
      <nav class="flex-1 p-4 space-y-1">
        <router-link 
          v-for="item in menuItems" 
          :key="item.path"
          :to="item.path"
          class="flex items-center gap-3 px-4 py-2.5 rounded-sm text-xs font-semibold tracking-wide transition-colors duration-150 group"
          :class="isRouteActive(item.path) ? 'bg-teal-50 text-teal-700' : 'text-slate-600 hover:bg-slate-50 hover:text-slate-800'"
        >
          <el-icon class="text-md group-hover:scale-105 transition-transform duration-150" :class="isRouteActive(item.path) ? 'text-teal-700' : 'text-slate-400'">
            <component :is="item.icon" />
          </el-icon>
          <span>{{ item.title }}</span>
        </router-link>
      </nav>

      <!-- 边栏底部切换店铺 -->
      <div class="p-4 border-t border-slate-200 bg-slate-50/50">
        <button 
          @click="switchShop"
          class="w-full py-2 border border-slate-200 hover:border-slate-300 hover:bg-white text-slate-600 font-medium rounded-sm text-xs transition-colors duration-150 cursor-pointer flex items-center justify-center gap-1.5"
        >
          <span>↩</span>
          <span>切换管理店铺</span>
        </button>
      </div>

    </aside>

    <!-- 右侧主体内容区域 -->
    <div class="flex-1 flex flex-col min-w-0">
      <!-- 顶部信息头 -->
      <header class="h-16 bg-white border-b border-slate-200 px-8 flex justify-between items-center shadow-[0_1px_3px_rgba(0,0,0,0.01)] shrink-0">
        <!-- 路由标题面包屑 -->
        <div>
          <span class="text-xs text-slate-400">店铺管理</span>
          <span class="text-xs text-slate-300 mx-2">/</span>
          <span class="text-xs text-slate-700 font-medium">{{ currentActiveTitle }}</span>
        </div>

        <!-- 个人信息 -->
        <div class="flex items-center gap-4 text-xs">
          <span class="text-slate-500 font-medium">当前操作员: <strong class="text-slate-700">{{ authStore.username }}</strong></span>
          <div class="w-px h-4 bg-slate-200"></div>
          <button @click="handleLogout" class="text-rose-600 hover:underline cursor-pointer">安全注销</button>
        </div>
      </header>

      <!-- 主要子页面视图区 -->
      <main class="flex-1 overflow-y-auto p-8">
        <router-view />
      </main>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import { useAuthStore } from '../store/auth'
import { 
  Box, 
  Goods, 
  Download, 
  Upload, 
  Memo, 
  UserFilled 
} from '@element-plus/icons-vue'

const router = useRouter()
const route = useRoute()
const authStore = useAuthStore()

const menuItems = [
  { path: '/shop/stock', title: '即时库存看板', icon: Box },
  { path: '/shop/products', title: '商品清单维护', icon: Goods },
  { path: '/shop/inbound', title: '商品入库记账', icon: Download },
  { path: '/shop/outbound', title: '商品出库记账', icon: Upload },
  { path: '/shop/ledger', title: '库存异动日志', icon: Memo },
  { path: '/shop/members', title: '店员成员审批', icon: UserFilled },
]

const isRouteActive = (path: string) => {
  return route.path.startsWith(path)
}

const currentActiveTitle = computed(() => {
  const item = menuItems.find(i => route.path.startsWith(i.path))
  return item ? item.title : '概览'
})

const switchShop = () => {
  // 清除 activeShop 上下文并回到大厅
  authStore.setActiveShop('', '')
  router.push('/')
}

const handleLogout = () => {
  authStore.logout()
  router.push('/login')
}
</script>

<style scoped>
/* 可以在此处添加通用过渡效果 */
</style>
