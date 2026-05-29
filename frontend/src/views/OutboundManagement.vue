<template>
  <div class="space-y-6">
    
    <!-- 列表展示区 -->
    <div class="bg-white border border-slate-200 rounded-md p-6 shadow-[0_1px_3px_rgba(0,0,0,0.02)]">
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between pb-6 border-b border-slate-100 gap-4 mb-6">
        <div>
          <h2 class="text-sm font-bold text-slate-800">商品出库记账单列表</h2>
          <p class="text-[11px] text-slate-400 mt-1">查看和登记发货或退货相关的商品出库单据记录。</p>
        </div>
        <el-button type="primary" size="small" @click="openCreateDialog" class="!bg-primary hover:!bg-primary-hover !border-none !rounded-sm">
          登记新出库单
        </el-button>
      </div>

      <!-- 出库单数据表格 -->
      <el-table :data="outboundList" v-loading="loading" border style="width: 100%" class="custom-table" size="small">
        <el-table-column type="expand">
          <template #default="props">
            <div class="p-6 bg-slate-50 border-y border-slate-200">
              <h4 class="text-xs font-bold text-slate-700 mb-3 flex items-center gap-1.5">
                <span>📋</span> <span>出库商品明细</span>
              </h4>
              <el-table :data="props.row.items" size="small" border class="inner-table">
                <el-table-column prop="product_code" label="商品编码" width="150" font-mono />
                <el-table-column prop="product_name" label="商品名称" min-width="200" />
                <el-table-column prop="quantity" label="出库数量" width="100" align="right" />
                <el-table-column prop="sale_price" label="出库售价" width="120" align="right">
                  <template #default="scope">￥{{ scope.row.sale_price }}</template>
                </el-table-column>
              </el-table>
            </div>
          </template>
        </el-table-column>
        <el-table-column prop="id" label="系统出库单 ID" width="220" font-mono />
        <el-table-column prop="logistics_number" label="物流单号" width="180" font-mono>
          <template #default="scope">{{ scope.row.logistics_number || '-' }}</template>
        </el-table-column>
        <el-table-column prop="note" label="备注说明" min-width="150">
          <template #default="scope">{{ scope.row.note || '-' }}</template>
        </el-table-column>
        <el-table-column prop="created_at" label="出库记账时间" width="200" align="center">
          <template #default="scope">
            <span class="font-mono text-slate-500">{{ formatDate(scope.row.created_at) }}</span>
          </template>
        </el-table-column>
      </el-table>
    </div>

    <!-- 弹窗：登记新出库单 -->
    <el-dialog 
      v-model="showDialog" 
      title="登记新出库单 (自动扣减库存)" 
      width="780px"
      class="custom-dialog"
    >
      <el-form :model="form" ref="formRef" size="small" label-width="100px">
        <!-- 基础单据信息 -->
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mb-4">
          <el-form-item label="物流单号" prop="logistics_number" class="!mb-0">
            <el-input v-model="form.logistics_number" placeholder="选填出货物流快递单号" />
          </el-form-item>
          <el-form-item label="备注说明" prop="note" class="!mb-0">
            <el-input v-model="form.note" placeholder="如退货入仓、扫码销售等" />
          </el-form-item>
        </div>

        <!-- 商品明细输入网格 -->
        <div class="border border-slate-200 rounded-sm p-4 bg-slate-50/50 mt-6">
          <div class="flex justify-between items-center mb-4">
            <h3 class="text-xs font-bold text-slate-700">录入出库商品明细</h3>
            <button type="button" @click="addItemRow" class="text-xs text-primary hover:underline font-semibold cursor-pointer">
              + 添加一行为商品
            </button>
          </div>

          <div class="space-y-3">
            <div 
              v-for="(item, index) in form.items" 
              :key="index"
              class="flex items-center gap-3 bg-white p-3 border border-slate-200 rounded-sm"
            >
              <!-- 仅支持选择当前有库存的商品编码 -->
              <div class="w-1/3">
                <el-select 
                  v-model="item.product_code" 
                  placeholder="选择当前库存商品" 
                  filterable 
                  @change="(val: string) => handleProductSelect(val, index)"
                  size="small"
                  class="w-full"
                >
                  <el-option 
                    v-for="stock in availableStocks" 
                    :key="stock.product_code" 
                    :label="`${stock.product_code} (余量: ${stock.quantity})`" 
                    :value="stock.product_code" 
                  />
                </el-select>
              </div>

              <!-- 商品名称 -->
              <div class="w-1/3">
                <el-input v-model="item.product_name" placeholder="商品名称" size="small" disabled />
              </div>

              <!-- 数量 -->
              <div class="w-1/6">
                <el-input-number v-model="item.quantity" :min="1" :step="1" controls-position="right" size="small" class="!w-full" />
              </div>

              <!-- 售价 -->
              <div class="w-1/6">
                <el-input-number v-model="item.sale_price" :min="0" :precision="2" :controls="false" placeholder="销售售价" size="small" class="!w-full" />
              </div>

              <!-- 移除按钮 -->
              <button 
                type="button" 
                @click="removeItemRow(index)"
                :disabled="form.items.length === 1"
                class="text-rose-600 hover:text-rose-700 disabled:text-slate-300 cursor-pointer text-sm font-bold p-1 shrink-0"
              >
                ✕
              </button>
            </div>
          </div>
        </div>
      </el-form>
      <template #footer>
        <div class="dialog-footer">
          <el-button @click="showDialog = false" size="small" class="!rounded-sm">取消</el-button>
          <el-button type="primary" :loading="submitLoading" @click="handleSubmit" size="small" class="!bg-primary !border-none !rounded-sm">确认出库并记账</el-button>
        </div>
      </template>
    </el-dialog>

  </div>
</template>

<script setup lang="ts">
import { ref, reactive, onMounted } from 'vue'
import { ElMessage } from 'element-plus'
import type { FormInstance } from 'element-plus'
import axios from '../utils/request'

interface OutboundItem {
  product_code: string
  product_name: string
  quantity: number
  sale_price: number
}

interface OutboundReceiptItem {
  id: string
  logistics_number: string | null
  note: string | null
  created_at: string
  items: OutboundItem[]
}

interface WarehouseStockItem {
  product_code: string
  product_name: string
  quantity: number
}

interface ProductItem {
  code: string
  name: string
  default_sale_price: number | null
}

const loading = ref(false)
const submitLoading = ref(false)
const outboundList = ref<OutboundReceiptItem[]>([])
const availableStocks = ref<WarehouseStockItem[]>([])
const existingProducts = ref<ProductItem[]>([])

const showDialog = ref(false)
const formRef = ref<FormInstance>()

const form = reactive({
  logistics_number: '',
  note: '',
  items: [
    { product_code: '', product_name: '', quantity: 1, sale_price: 0 }
  ]
})

const fetchOutboundList = async () => {
  loading.value = true
  try {
    const res: any = await axios.get('/api/inventory/outbound')
    outboundList.value = res
  } catch (err) {
  } finally {
    loading.value = false
  }
}

const fetchStocks = async () => {
  try {
    const res: any = await axios.get('/api/inventory/stocks')
    // 过滤库存量大于 0 的商品
    availableStocks.value = res.filter((s: any) => s.quantity > 0)
  } catch (err) {}
}

const fetchExistingProducts = async () => {
  try {
    const res: any = await axios.get('/api/inventory/products')
    existingProducts.value = res
  } catch (err) {}
}

onMounted(() => {
  fetchOutboundList()
  fetchStocks()
  fetchExistingProducts()
})

const openCreateDialog = () => {
  form.logistics_number = ''
  form.note = ''
  form.items = [
    { product_code: '', product_name: '', quantity: 1, sale_price: 0 }
  ]
  showDialog.value = true
  fetchStocks()
  fetchExistingProducts()
}

const addItemRow = () => {
  form.items.push({ product_code: '', product_name: '', quantity: 1, sale_price: 0 })
}

const removeItemRow = (index: number) => {
  form.items.splice(index, 1)
}

const handleProductSelect = (code: string, index: number) => {
  const stock = availableStocks.value.find(s => s.product_code === code)
  const product = existingProducts.value.find(p => p.code === code)
  if (stock) {
    form.items[index].product_name = stock.product_name
    form.items[index].sale_price = product?.default_sale_price || 0
  }
}

const handleSubmit = async () => {
  if (!formRef.value) return
  
  // 校检明细行及库存是否足量
  for (let i = 0; i < form.items.length; i++) {
    const item = form.items[i]
    if (!item.product_code || !item.product_name) {
      ElMessage.warning(`第 ${i + 1} 行商品不能为空`)
      return
    }
    
    // 校验前台库存
    const stock = availableStocks.value.find(s => s.product_code === item.product_code)
    if (!stock || stock.quantity < item.quantity) {
      ElMessage.warning(`第 ${i + 1} 行商品 [${item.product_name}] 库存不足，当前库存为: ${stock ? stock.quantity : 0}`)
      return
    }
  }

  submitLoading.value = true
  try {
    await axios.post('/api/inventory/outbound', form)
    ElMessage.success('出库单登记成功，库存已扣减')
    showDialog.value = false
    await fetchOutboundList()
  } catch (err) {
  } finally {
    submitLoading.value = false
  }
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
.inner-table {
  --el-table-border-color: #e2e8f0;
  --el-table-header-bg-color: #f1f5f9;
}
</style>
