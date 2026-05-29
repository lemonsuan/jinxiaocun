<template>
  <div class="min-h-screen bg-slate-50 flex flex-col">
    <!-- 顶部状态栏 -->
    <header class="bg-white border-b border-slate-200 py-4 px-6 flex justify-between items-center shadow-[0_1px_3px_rgba(0,0,0,0.02)]">
      <div class="flex items-center gap-2">
        <span class="text-xl">🏪</span>
        <span class="font-bold text-slate-800 tracking-tight text-md">店铺管理中心</span>
      </div>
      <div class="flex items-center gap-4 text-xs">
        <span class="text-slate-500 font-medium">当前用户: <strong class="text-slate-700">{{ authStore.username }}</strong></span>
        <el-button size="small" @click="handleLogout" class="!rounded-sm">退出登录</el-button>
      </div>
    </header>

    <!-- 主要区域 -->
    <main class="flex-1 max-w-5xl w-full mx-auto p-8">
      
      <!-- 头部大字及操作 -->
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between mb-8 pb-4 border-b border-slate-200 gap-4">
        <div>
          <h1 class="text-xl font-bold text-slate-800">请选择要进入的店铺</h1>
          <p class="text-xs text-slate-400 mt-1">进入店铺后，即可对其所属的商品、出入库和库存数据进行日常维护。</p>
        </div>
        <div class="flex gap-2 shrink-0">
          <el-button type="primary" @click="showCreateDialog = true" class="!bg-primary hover:!bg-primary-hover !border-none !rounded-sm !text-xs py-2 px-3">
            新建店铺
          </el-button>
          <el-button @click="showJoinDialog = true" class="!rounded-sm !text-xs py-2 px-3">
            申请加入店铺
          </el-button>
        </div>
      </div>

      <!-- 我的店铺列表 (卡片网格) -->
      <div v-if="loading" class="py-12 flex justify-center">
        <el-icon class="is-loading text-slate-400 text-2xl"><Loading /></el-icon>
      </div>
      
      <div v-else-if="myShops.length === 0" class="bg-white border border-slate-200 rounded-md p-10 text-center shadow-[0_1px_3px_rgba(0,0,0,0.02)]">
        <div class="text-4xl mb-4">📭</div>
        <h3 class="text-sm font-bold text-slate-700">暂无可管理的店铺</h3>
        <p class="text-xs text-slate-400 mt-2 max-w-sm mx-auto">
          您当前没有所属的店铺。请创建一个新店铺，或向现有店铺管理员索要店铺 ID 申请加入，审核通过后即可在此处查看。
        </p>
      </div>

      <div v-else class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        <div 
          v-for="item in myShops" 
          :key="item.shop_id"
          class="bg-white border border-slate-200 hover:border-primary rounded-md p-6 shadow-[0_1px_3px_rgba(0,0,0,0.02)] hover:shadow-[0_4px_12px_rgba(0,0,0,0.05)] transition-all duration-200 flex flex-col justify-between"
        >
          <div>
            <div class="flex items-center justify-between mb-4">
              <span 
                class="px-2 py-0.5 rounded-sm text-[10px] font-semibold"
                :class="statusClass(item.status)"
              >
                {{ statusText(item.status) }}
              </span>
              <span class="text-xs text-slate-400 font-mono">角色: {{ roleText(item.role) }}</span>
            </div>
            
            <h3 class="text-md font-bold text-slate-800 mb-2 truncate">{{ item.shop_name }}</h3>
            <p class="text-[11px] text-slate-400 font-mono select-all">店铺ID: {{ item.shop_id }}</p>
          </div>

          <div class="mt-6 pt-4 border-t border-slate-100 flex justify-end">
            <el-button 
              type="primary" 
              size="small"
              :disabled="item.status !== 'APPROVED'"
              @click="enterShop(item.shop_id, item.shop_name)"
              class="!bg-primary hover:!bg-primary-hover disabled:!bg-slate-100 disabled:!text-slate-400 !border-none !rounded-sm !text-xs"
            >
              进入管理 ➔
            </el-button>
          </div>
        </div>
      </div>
    </main>

    <!-- 新建店铺弹窗 -->
    <el-dialog v-model="showCreateDialog" title="新建店铺" width="400px" class="custom-dialog">
      <el-form :model="createForm" ref="createFormRef" :rules="createRules">
        <el-form-item label="店铺名称" prop="name">
          <el-input v-model="createForm.name" placeholder="例如：雅诗兰黛官方旗舰店" />
        </el-form-item>
      </el-form>
      <template #footer>
        <span class="dialog-footer">
          <el-button @click="showCreateDialog = false" size="small" class="!rounded-sm">取消</el-button>
          <el-button type="primary" :loading="submitLoading" @click="handleCreateShop" size="small" class="!bg-primary !border-none !rounded-sm">确认创建</el-button>
        </span>
      </template>
    </el-dialog>

    <!-- 申请加入店铺弹窗 -->
    <el-dialog v-model="showJoinDialog" title="申请加入店铺" width="400px" class="custom-dialog">
      <el-form :model="joinForm" ref="joinFormRef" :rules="joinRules">
        <el-form-item label="店铺 ID (UUID)" prop="shop_id">
          <el-input v-model="joinForm.shop_id" placeholder="请输入店铺 ID (UUID 格式)" />
        </el-form-item>
      </el-form>
      <template #footer>
        <span class="dialog-footer">
          <el-button @click="showJoinDialog = false" size="small" class="!rounded-sm">取消</el-button>
          <el-button type="primary" :loading="submitLoading" @click="handleJoinShop" size="small" class="!bg-primary !border-none !rounded-sm">提交申请</el-button>
        </span>
      </template>
    </el-dialog>
  </div>
</template>

<script setup lang="ts">
import { ref, reactive, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { ElMessage } from 'element-plus'
import type { FormInstance } from 'element-plus'
import { Loading } from '@element-plus/icons-vue'
import axios from '../utils/request'
import { useAuthStore } from '../store/auth'

const router = useRouter()
const authStore = useAuthStore()

interface ShopMembershipItem {
  shop_id: string
  shop_name: string
  role: string
  status: string
  joined_at: string
}

const loading = ref(false)
const submitLoading = ref(false)
const myShops = ref<ShopMembershipItem[]>([])

const showCreateDialog = ref(false)
const createFormRef = ref<FormInstance>()
const createForm = reactive({ name: '' })
const createRules = {
  name: [{ required: true, message: '店铺名称不能为空', trigger: 'blur' }]
}

const showJoinDialog = ref(false)
const joinFormRef = ref<FormInstance>()
const joinForm = reactive({ shop_id: '' })
const joinRules = {
  shop_id: [
    { required: true, message: '店铺 ID 不能为空', trigger: 'blur' },
    { pattern: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, message: '店铺 ID 格式不正确 (UUID)', trigger: 'blur' }
  ]
}

const fetchShops = async () => {
  loading.value = true
  try {
    const res: any = await axios.get('/api/shops/my-shops')
    myShops.value = res
  } catch (err) {
    // 错误已由 Axios 拦截器展示
  } finally {
    loading.value = false
  }
}

onMounted(() => {
  fetchShops()
})

const enterShop = (shopId: string, shopName: string) => {
  authStore.setActiveShop(shopId, shopName)
  router.push('/shop')
}

const handleCreateShop = async () => {
  if (!createFormRef.value) return
  await createFormRef.value.validate(async (valid) => {
    if (!valid) return
    submitLoading.value = true
    try {
      await axios.post('/api/shops/create', { name: createForm.name })
      ElMessage.success('店铺创建成功！')
      showCreateDialog.value = false
      createForm.name = ''
      await fetchShops()
    } catch (err) {
    } finally {
      submitLoading.value = false
    }
  })
}

const handleJoinShop = async () => {
  if (!joinFormRef.value) return
  await joinFormRef.value.validate(async (valid) => {
    if (!valid) return
    submitLoading.value = true
    try {
      const res: any = await axios.post('/api/shops/join', { shop_id: joinForm.shop_id })
      ElMessage.success(res.message || '申请提交成功，请联系管理员审批！')
      showJoinDialog.value = false
      joinForm.shop_id = ''
      await fetchShops()
    } catch (err) {
    } finally {
      submitLoading.value = false
    }
  })
}

const handleLogout = () => {
  authStore.logout()
  router.push('/login')
}

const roleText = (role: string) => {
  const map: Record<string, string> = { CREATOR: '创建人', ADMIN: '管理员', MEMBER: '普通店员' }
  return map[role] || role
}

const statusText = (status: string) => {
  const map: Record<string, string> = { PENDING: '审批中', APPROVED: '正常可用', REJECTED: '已拒绝' }
  return map[status] || status
}

const statusClass = (status: string) => {
  if (status === 'APPROVED') return 'bg-teal-50 text-teal-600 border border-teal-200'
  if (status === 'PENDING') return 'bg-amber-50 text-amber-600 border border-amber-200'
  return 'bg-rose-50 text-rose-600 border border-rose-200'
}
</script>

<style scoped>
:deep(.el-dialog) {
  border-radius: 6px;
  box-shadow: 0 4px 16px rgba(0,0,0,0.08);
}
:deep(.custom-dialog .el-form-item__label) {
  font-size: 11px;
  font-weight: 500;
  color: #64748b;
}
:deep(.custom-dialog .el-input__wrapper) {
  border-radius: 4px;
}
</style>
