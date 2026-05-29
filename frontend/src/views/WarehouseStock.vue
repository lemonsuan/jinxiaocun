<template>
  <div class="bg-white border border-slate-200 rounded-md p-6 shadow-[0_1px_3px_rgba(0,0,0,0.02)]">
    <!-- 头部搜索和动作 -->
    <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between pb-6 border-b border-slate-100 gap-4 mb-6">
      <div>
        <h2 class="text-sm font-bold text-slate-800">当前即时库存状态</h2>
        <p class="text-[11px] text-slate-400 mt-1">只读查看当前店铺中所有在线托管商品的仓储即时结余数据。</p>
      </div>
      <div class="w-64">
        <el-input 
          v-model="searchQuery" 
          placeholder="搜索商品名称/编码..." 
          clearable
          size="small"
          class="custom-search"
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
      <el-table-column prop="product_code" label="商品编码" width="180" font-mono />
      <el-table-column prop="product_name" label="商品名称" min-width="250" />
      <el-table-column prop="quantity" label="当前库存结余" width="150" align="right">
        <template #default="scope">
          <span 
            class="font-mono font-bold"
            :class="scope.row.quantity <= 10 ? 'text-rose-600' : 'text-slate-700'"
          >
            {{ scope.row.quantity }}
          </span>
        </template>
      </el-table-column>
      <el-table-column prop="updated_at" label="最后异动时间" width="200" align="center">
        <template #default="scope">
          <span class="font-mono text-slate-500">{{ formatDate(scope.row.updated_at) }}</span>
        </template>
      </el-table-column>
    </el-table>

    <!-- 底部简易统计统计 -->
    <div class="mt-6 flex justify-between items-center text-xs text-slate-500">
      <div>
        共有 <strong class="text-slate-700 font-mono">{{ filteredData.length }}</strong> 款商品有仓储记录。
      </div>
      <div class="flex gap-4">
        <span>低库存告警值: &lt;= 10 件</span>
      </div>
    </div>

  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import axios from '../utils/request'

interface StockItem {
  id: string
  product_code: string
  product_name: string
  quantity: number
  updated_at: string
}

const loading = ref(false)
const stockData = ref<StockItem[]>([])
const searchQuery = ref('')

const fetchStocks = async () => {
  loading.value = true
  try {
    const res: any = await axios.get('/api/inventory/stocks')
    stockData.value = res
  } catch (err) {
  } finally {
    loading.value = false
  }
}

onMounted(() => {
  fetchStocks()
})

const filteredData = computed(() => {
  const query = searchQuery.value.trim().toLowerCase()
  if (!query) return stockData.value
  return stockData.value.filter(
    item => 
      item.product_name.toLowerCase().includes(query) || 
      item.product_code.toLowerCase().includes(query)
  )
})

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
