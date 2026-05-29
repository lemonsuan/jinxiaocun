import { createRouter, createWebHashHistory } from 'vue-router'
import type { RouteRecordRaw } from 'vue-router'
import { useAuthStore } from '../store/auth'

const routes: RouteRecordRaw[] = [
  {
    path: '/login',
    name: 'Login',
    component: () => import('../views/Login.vue'),
    meta: { requireAuth: false }
  },
  {
    path: '/',
    name: 'ShopSelect',
    component: () => import('../views/ShopSelect.vue'),
    meta: { requireAuth: true }
  },
  {
    path: '/shop',
    name: 'ShopLayout',
    component: () => import('../views/ShopLayout.vue'),
    meta: { requireAuth: true, requireActiveShop: true },
    redirect: '/shop/stock',
    children: [
      {
        path: 'stock',
        name: 'WarehouseStock',
        component: () => import('../views/WarehouseStock.vue')
      },
      {
        path: 'products',
        name: 'ProductManagement',
        component: () => import('../views/ProductManagement.vue')
      },
      {
        path: 'inbound',
        name: 'InboundManagement',
        component: () => import('../views/InboundManagement.vue')
      },
      {
        path: 'outbound',
        name: 'OutboundManagement',
        component: () => import('../views/OutboundManagement.vue')
      },
      {
        path: 'ledger',
        name: 'StockLedger',
        component: () => import('../views/StockLedger.vue')
      },
      {
        path: 'members',
        name: 'MemberManagement',
        component: () => import('../views/MemberManagement.vue')
      }
    ]
  }
]

const router = createRouter({
  history: createWebHashHistory(),
  routes
})

// 路由鉴权守卫
router.beforeEach((to, _from, next) => {
  const authStore = useAuthStore()
  
  if (to.meta.requireAuth) {
    if (!authStore.token) {
      next('/login')
    } else if (to.meta.requireActiveShop && !authStore.activeShopId) {
      next('/')
    } else {
      next()
    }
  } else {
    // 已登录状态下不能再进入登录页，直接跳转主页
    if (to.path === '/login' && authStore.token) {
      next('/')
    } else {
      next()
    }
  }
})

export default router
