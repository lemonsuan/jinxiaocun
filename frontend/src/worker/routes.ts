import type { Router, RouteRecordRaw } from 'vue-router';
import { useWorkerStore } from './store';

export const workerRoutes: RouteRecordRaw[] = [
  {
    path: '/worker/login',
    name: 'WorkerLogin',
    component: () => import('./pages/WorkerAuthPage.vue'),
    meta: { worker: true },
  },
  {
    path: '/worker/register',
    name: 'WorkerRegister',
    component: () => import('./pages/WorkerAuthPage.vue'),
    meta: { worker: true },
  },
  {
    path: '/worker',
    component: () => import('./WorkerShell.vue'),
    meta: { worker: true, workerAuth: true },
    redirect: '/worker/jobs',
    children: [
      {
        path: 'jobs',
        name: 'WorkerJobs',
        component: () => import('./pages/WorkerJobsPage.vue'),
      },
      {
        path: 'jobs/:jobId',
        name: 'WorkerJob',
        component: () => import('./pages/WorkerJobPage.vue'),
      },
      {
        path: 'orders',
        name: 'WorkerOrders',
        component: () => import('./pages/WorkerOrdersPage.vue'),
      },
      {
        path: 'orders/new',
        name: 'WorkerNewOrder',
        component: () => import('./pages/WorkerOrderEditor.vue'),
      },
      {
        path: 'orders/:orderId',
        name: 'WorkerOrder',
        component: () => import('./pages/WorkerOrderEditor.vue'),
      },
    ],
  },
];

export function installWorkerGuard(router: Router) {
  router.beforeEach((to) => {
    if (!to.meta.workerAuth) return true;
    const auth = useWorkerStore();
    if (auth.token && auth.worker) return true;
    return {
      path: '/worker/login',
      query: {
        ...(auth.lastShop ? { shop: auth.lastShop } : {}),
        redirect: to.fullPath,
      },
    };
  });
}
