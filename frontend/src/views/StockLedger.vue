<template>
  <div class="bg-white border border-slate-200 rounded-md p-6 shadow-[0_1px_3px_rgba(0,0,0,0.02)]">
    <!-- 头部搜索和动作 -->
    <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between pb-6 border-b border-slate-100 gap-4 mb-6">
      <div>
        <h2 class="text-sm font-bold text-slate-800">库存异动日志账本</h2>
        <p class="text-[11px] text-slate-400 mt-1">只读追踪本店铺内所有商品的出入库和校准的历史流水变动记录，方便账目审计。</p>
      </div>
      <div class="flex gap-2">
        <el-input 
          v-model="searchQuery" 
          placeholder="过滤商品/编码..." 
          clearable
          size="small"
          class="w-56"
        />
      </div>
    </div>

    <!-- 数据表 -->
    <el-table 
      v-loading="loading" 
      :data="filteredData" 
      border 
      style="width: 100%"
      class="custom-table"
      size="small"
    >
      <el-table-column type="index" label="#" width="60" align="center" />
      <el-table-column prop="created_at" label="记录时间" width="200" align="center">
        <template #default="scope">
          <span class="font-mono text-slate-500">{{ formatDate(scope.row.created_at) }}</span>
        </template>
      </el-table-column>
      <el-table-column prop="product_code" label="商品编码" width="160" font-mono />
      <el-table-column prop="product_name" label="商品名称" min-width="200" />
      <el-table-column prop="delta" label="变动量" width="120" align="right">
        <template #default="scope">
          <span 
            class="font-mono font-bold"
            :class="scope.row.delta > 0 ? 'text-emerald-600' : 'text-rose-600'"
          >
            {{ scope.row.delta > 0 ? `+${scope.row.delta}` : scope.row.delta }}
          </span>
        </template>
      </el-table-column>
      <el-table-column prop="reason" label="变更原因" width="130" align="center">
        <template #default="scope">
          <span 
            class="px-2 py-0.5 rounded-sm text-[10px] font-semibold"
            :class="reasonClass(scope.row.reason)"
          >
            {{ reasonText(scope.row.reason) }}
          </span>
        </template>
      </el-table-column>
      <el-table-column prop="source_id" label="关联业务单据 ID" min-width="180" font-mono>
        <template #default="scope">
          <span class="text-xs text-slate-400 font-mono">{{ scope.row.source_id }}</span>
        </template>
      </el-table-column>
    </el-table>

    <!-- 底部统计 -->
    <div class="mt-6 text-xs text-slate-500">
      共有 <strong class="text-slate-700 font-mono">{{ filteredData.length }}</strong> 条日志异动记录被归档。
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import axios from '../utils/request'

interface LedgerItem {
  id: string
  product_code: string
  product_name: string
  delta: number
  reason: string
  source_id: string
  created_at: string
}

const loading = ref(false)
const ledgerData = ref<LedgerItem[]>([])
const searchQuery = ref('')

const fetchLedger = async () => {
  loading.value = true
  try {
    const res: any = await axios.get('/api/inventory/ledger')
    ledgerData.value = res
  } catch (err) {
  } finally {
    loading.value = false
  }
}

onMounted(() => {
  fetchLedger()
})

const filteredData = computed(() => {
  const query = searchQuery.value.trim().toLowerCase()
  if (!query) return ledgerData.value
  return ledgerData.value.filter(
    item => 
      item.product_name.toLowerCase().includes(query) || 
      item.product_code.toLowerCase().includes(query) ||
      item.source_id.toLowerCase().includes(query)
  )
})

const reasonText = (reason: string) => {
  const map: Record<string, string> = {
    inbound: '扫码入库',
    outbound: '出库发货',
    adjustment: '库存校准'
  }
  return map[reason] || reason
}

const reasonClass = (reason: string) => {
  if (reason === 'inbound') return 'bg-emerald-50 text-emerald-600 border border-emerald-200'
  if (reason === 'outbound') return 'bg-rose-50 text-rose-600 border border-rose-200'
  return 'bg-amber-50 text-amber-600 border border-amber-200'
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
