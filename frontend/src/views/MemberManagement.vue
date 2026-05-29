<template>
  <div class="bg-white border border-slate-200 rounded-md p-6 shadow-[0_1px_3px_rgba(0,0,0,0.02)]">
    <!-- 头部和店铺ID展示 -->
    <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between pb-6 border-b border-slate-100 gap-4 mb-6">
      <div>
        <h2 class="text-sm font-bold text-slate-800">本店铺店员成员审批与管理</h2>
        <p class="text-[11px] text-slate-400 mt-1">
          审批外部用户的加入申请，并调整已批准店员的角色权限（仅店铺创建人与管理员可用）。
        </p>
      </div>
      <div class="bg-slate-50 border border-slate-200 rounded-sm py-1.5 px-3 text-[11px] text-slate-500 font-mono">
        邀请店员使用的店铺ID: <strong class="text-slate-700 select-all font-bold">{{ authStore.activeShopId }}</strong>
      </div>
    </div>

    <!-- 无权限遮罩提示 -->
    <div v-if="noPermission" class="py-16 text-center max-w-md mx-auto">
      <div class="text-4xl mb-4">🔒</div>
      <h3 class="text-sm font-bold text-slate-700">权限不足</h3>
      <p class="text-xs text-slate-400 mt-2">
        只有当前店铺的创建人 (CREATOR) 或管理员 (ADMIN) 可以管理店员关系和审批加入申请。普通店员无权访问该板块。
      </p>
    </div>

    <!-- 数据表 -->
    <div v-else>
      <el-table 
        v-loading="loading" 
        :data="members" 
        border 
        style="width: 100%"
        class="custom-table"
        size="small"
      >
        <el-table-column type="index" label="#" width="60" align="center" />
        <el-table-column prop="user.username" label="申请人用户名" min-width="150" />
        <el-table-column prop="role" label="当前角色" width="130" align="center">
          <template #default="scope">
            <span class="font-medium text-xs">{{ roleText(scope.row.role) }}</span>
          </template>
        </el-table-column>
        <el-table-column prop="status" label="状态" width="130" align="center">
          <template #default="scope">
            <span 
              class="px-2 py-0.5 rounded-sm text-[10px] font-semibold"
              :class="statusClass(scope.row.status)"
            >
              {{ statusText(scope.row.status) }}
            </span>
          </template>
        </el-table-column>
        <el-table-column prop="joined_at" label="申请/加入时间" width="200" align="center">
          <template #default="scope">
            <span class="font-mono text-slate-500">{{ formatDate(scope.row.joined_at) }}</span>
          </template>
        </el-table-column>
        <el-table-column label="操作权限控制" width="220" align="center" fixed="right">
          <template #default="scope">
            <!-- 针对待审批的成员 -->
            <div v-if="scope.row.status === 'PENDING'" class="flex justify-center gap-2">
              <button 
                @click="handleApprove(scope.row.id, true)"
                class="text-xs text-teal-600 hover:underline font-medium cursor-pointer"
              >
                同意加入
              </button>
              <button 
                @click="handleApprove(scope.row.id, false)"
                class="text-xs text-rose-600 hover:underline font-medium cursor-pointer"
              >
                拒绝
              </button>
            </div>
            
            <!-- 针对已加入的普通店员 -->
            <div v-else-if="scope.row.status === 'APPROVED' && scope.row.role === 'MEMBER'" class="flex justify-center gap-2">
              <button 
                @click="handleRoleChange(scope.row.id, 'ADMIN')"
                class="text-xs text-primary hover:underline font-medium cursor-pointer"
              >
                提升为管理员
              </button>
            </div>

            <!-- 针对已加入的店铺管理员 -->
            <div v-else-if="scope.row.status === 'APPROVED' && scope.row.role === 'ADMIN'" class="flex justify-center gap-2">
              <button 
                @click="handleRoleChange(scope.row.id, 'MEMBER')"
                class="text-xs text-slate-500 hover:underline font-medium cursor-pointer"
              >
                降级为普通店员
              </button>
            </div>
            
            <div v-else class="text-xs text-slate-400 font-medium">-</div>
          </template>
        </el-table-column>
      </el-table>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { ElMessage } from 'element-plus'
import axios from '../utils/request'
import { useAuthStore } from '../store/auth'

const authStore = useAuthStore()

interface MemberItem {
  id: string
  user: {
    id: string
    username: string
  }
  role: string
  status: string
  joined_at: string
}

const loading = ref(false)
const noPermission = ref(false)
const members = ref<MemberItem[]>([])

const fetchMembers = async () => {
  loading.value = true
  noPermission.value = false
  try {
    const res: any = await axios.get('/api/shops/members')
    members.value = res
  } catch (err: any) {
    if (err.response && err.response.status === 403) {
      noPermission.value = true
    }
  } finally {
    loading.value = false
  }
}

onMounted(() => {
  fetchMembers()
})

const handleApprove = async (membershipId: string, approve: boolean) => {
  try {
    await axios.post('/api/shops/members/update', {
      membership_id: membershipId,
      status: approve ? 'APPROVED' : 'REJECTED'
    })
    ElMessage.success(approve ? '已批准该店员加入！' : '已拒绝该申请')
    await fetchMembers()
  } catch (err) {}
}

const handleRoleChange = async (membershipId: string, role: string) => {
  try {
    await axios.post('/api/shops/members/update', {
      membership_id: membershipId,
      role: role
    })
    ElMessage.success('成员权限配置修改成功！')
    await fetchMembers()
  } catch (err) {}
}

const roleText = (role: string) => {
  const map: Record<string, string> = { CREATOR: '店铺创建人', ADMIN: '店铺管理员', MEMBER: '普通店员' }
  return map[role] || role
}

const statusText = (status: string) => {
  const map: Record<string, string> = { PENDING: '待审核', APPROVED: '已加入', REJECTED: '已拒绝' }
  return map[status] || status
}

const statusClass = (status: string) => {
  if (status === 'APPROVED') return 'bg-teal-50 text-teal-600 border border-teal-200'
  if (status === 'PENDING') return 'bg-amber-50 text-amber-600 border border-amber-200'
  return 'bg-rose-50 text-rose-600 border border-rose-200'
}

const formatDate = (isoStr: string) => {
  if (!isoStr) return '-'
  const d = new Date(isoStr)
  return d.toLocaleString('zh-CN', { hour12: false })
}
</script>

<style scoped>
.custom-table {
  --el-table-border-color: #e2e8f0;
  --el-table-header-bg-color: #f8fafc;
  --el-table-header-text-color: #475569;
  --el-table-text-color: #1e293b;
}
:deep(.el-table__row) {
  background-color: #fff;
}
:deep(.el-table__cell) {
  padding: 8px 0;
}
</style>
