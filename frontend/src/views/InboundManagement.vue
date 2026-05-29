<template>
  <div class="bg-white border border-slate-200 rounded-md shadow-[0_1px_3px_rgba(0,0,0,0.02)]">
    <!-- 主 Tabs 切换，极简理性的 Tab 设计 -->
    <el-tabs v-model="activeTab" class="custom-tabs" @tab-change="handleTabChange">
      
      <!-- TAB 1: 入库单记账维护 -->
      <el-tab-pane label="📋 商品入库记账单" name="list" class="p-6">
        <!-- 头部搜索和动作 -->
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between pb-6 border-b border-slate-100 gap-4 mb-6">
          <div>
            <h2 class="text-sm font-bold text-slate-800">商品入库记账单列表</h2>
            <p class="text-[11px] text-slate-400 mt-1">查看和录入与供应商/物流方对接的商品入库单据记录。</p>
          </div>
          <div class="flex gap-2 shrink-0">
            <el-input 
              v-model="searchQuery" 
              placeholder="搜索运单号/订单号/计划号..." 
              clearable
              size="small"
              class="w-56"
            />
            <el-button type="primary" size="small" @click="openCreateDialog" class="!bg-primary hover:!bg-primary-hover !border-none !rounded-sm">
              登记新入库单
            </el-button>
          </div>
        </div>

        <!-- 入库单数据表格 -->
        <el-table :data="filteredInboundList" v-loading="loading" border style="width: 100%" class="custom-table" size="small">
          <el-table-column type="expand">
            <template #default="props">
              <div class="p-6 bg-slate-50 border-y border-slate-200">
                <h4 class="text-xs font-bold text-slate-700 mb-3 flex items-center gap-1.5">
                  <span>📋</span> <span>入库商品明细 (可直接修改数量)</span>
                </h4>
                <el-table :data="props.row.items" size="small" border class="inner-table">
                  <el-table-column prop="product_code" label="商品编码" width="150" font-mono />
                  <el-table-column prop="product_name" label="商品名称" min-width="200" />
                  
                  <!-- 可编辑的入库数量列 -->
                  <el-table-column prop="quantity" label="入库数量" width="180" align="right">
                    <template #default="scope">
                      <div v-if="editingItemId === scope.row.id" class="flex items-center gap-1 justify-end">
                        <el-input-number v-model="editingQty" :min="1" size="small" controls-position="right" class="!w-24" />
                        <button @click="saveItemQty(scope.row)" class="text-xs text-teal-600 font-bold p-1 hover:underline cursor-pointer">保存</button>
                        <button @click="cancelEditItem" class="text-xs text-slate-400 p-1 hover:underline cursor-pointer">取消</button>
                      </div>
                      <div v-else class="flex items-center justify-end gap-2">
                        <span class="font-mono">{{ scope.row.quantity }}</span>
                        <button @click="startEditItem(scope.row)" class="text-[10px] text-primary hover:underline cursor-pointer">修改</button>
                      </div>
                    </template>
                  </el-table-column>
                  
                  <el-table-column prop="purchase_price" label="入库采购价" width="120" align="right">
                    <template #default="scope">￥{{ scope.row.purchase_price }}</template>
                  </el-table-column>
                  <el-table-column prop="sale_price" label="建议零售价" width="120" align="right">
                    <template #default="scope">￥{{ scope.row.sale_price }}</template>
                  </el-table-column>
                </el-table>
              </div>
            </template>
          </el-table-column>
          <el-table-column prop="tracking_number" label="快递物流单号" width="180" font-mono />
          <el-table-column prop="seller_order_number" label="商家订单号" width="180" font-mono>
            <template #default="scope">{{ scope.row.seller_order_number || '-' }}</template>
          </el-table-column>
          <el-table-column prop="scheme_number" label="计划单号" width="150" font-mono>
            <template #default="scope">{{ scope.row.scheme_number || '-' }}</template>
          </el-table-column>
          
          <!-- 一键切换结算状态列 -->
          <el-table-column prop="is_settled" label="结算状态" width="140" align="center">
            <template #default="scope">
              <el-switch
                v-model="scope.row.is_settled"
                active-text="已结清"
                inactive-text="未结清"
                inline-prompt
                :loading="statusLoadingMap[scope.row.id]"
                @change="(val: boolean) => handleStatusChange(scope.row.id, val)"
              />
            </template>
          </el-table-column>
          
          <el-table-column prop="created_at" label="入库登记时间" width="180" align="center">
            <template #default="scope">
              <span class="font-mono text-slate-500">{{ formatDate(scope.row.created_at) }}</span>
            </template>
          </el-table-column>

          <!-- 新增删除操作列 -->
          <el-table-column label="操作" width="100" align="center" fixed="right">
            <template #default="scope">
              <el-popconfirm title="确定彻底删除此单据并扣除对应库存吗？" @confirm="handleDeleteInbound(scope.row.id)">
                <template #reference>
                  <button class="text-xs text-rose-600 hover:underline font-medium cursor-pointer">删除单据</button>
                </template>
              </el-popconfirm>
            </template>
          </el-table-column>
        </el-table>
      </el-tab-pane>

      <!-- TAB 2: 操作日志审计 (详细到人) -->
      <el-tab-pane label="🛡️ 入库操作审计日志" name="logs" class="p-6">
        <div class="pb-6 border-b border-slate-100 mb-6">
          <h2 class="text-sm font-bold text-slate-800">入库审计操作流水</h2>
          <p class="text-[11px] text-slate-400 mt-1">自动追溯和留存店铺成员对入库单增、删、改的操作历史记录，保障数据可信。</p>
        </div>

        <el-table :data="inboundLogs" v-loading="logsLoading" border style="width: 100%" class="custom-table" size="small">
          <el-table-column type="index" label="#" width="60" align="center" />
          <el-table-column prop="created_at" label="操作时间" width="180" align="center">
            <template #default="scope">
              <span class="font-mono text-slate-500">{{ formatDate(scope.row.created_at) }}</span>
            </template>
          </el-table-column>
          <el-table-column prop="user.username" label="操作人" width="150">
            <template #default="scope">
              <span class="font-semibold text-slate-700">{{ scope.row.user?.username || '系统/未知' }}</span>
            </template>
          </el-table-column>
          <el-table-column prop="action_type" label="动作类型" width="110" align="center">
            <template #default="scope">
              <span 
                class="px-2 py-0.5 rounded-sm text-[10px] font-semibold"
                :class="actionClass(scope.row.action_type)"
              >
                {{ actionText(scope.row.action_type) }}
              </span>
            </template>
          </el-table-column>
          <el-table-column prop="tracking_number" label="快递单号" width="180" font-mono />
          <el-table-column prop="detail" label="变更详细日志说明" min-width="250" />
        </el-table>
      </el-tab-pane>

    </el-tabs>

    <!-- 弹窗：登记新入库单 -->
    <el-dialog 
      v-model="showDialog" 
      title="登记新入库单 (自动累加库存)" 
      width="780px"
      class="custom-dialog"
    >
      <el-form :model="form" ref="formRef" :rules="rules" size="small" label-width="100px">
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4 mb-4">
          <el-form-item label="快递单号" prop="tracking_number" class="!mb-0">
            <el-input v-model="form.tracking_number" placeholder="必填物流运单号" />
          </el-form-item>
          <el-form-item label="商家订单号" prop="seller_order_number" class="!mb-0">
            <el-input v-model="form.seller_order_number" placeholder="选填订单号" />
          </el-form-item>
          <el-form-item label="计划单号" prop="scheme_number" class="!mb-0">
            <el-input v-model="form.scheme_number" placeholder="选填计划单号" />
          </el-form-item>
        </div>

        <div class="border border-slate-200 rounded-sm p-4 bg-slate-50/50 mt-6">
          <div class="flex justify-between items-center mb-4">
            <h3 class="text-xs font-bold text-slate-700">录入入库商品明细</h3>
            <button type="button" @click="addItemRow" class="text-xs text-primary hover:underline font-semibold cursor-pointer">
              + 添加一行商品
            </button>
          </div>

          <div class="space-y-3">
            <div 
              v-for="(item, index) in form.items" 
              :key="index"
              class="flex items-center gap-3 bg-white p-3 border border-slate-200 rounded-sm"
            >
              <div class="w-1/4">
                <el-select 
                  v-model="item.product_code" 
                  placeholder="选择或输入编码" 
                  filterable 
                  allow-create
                  default-first-option
                  @change="(val: string) => handleProductSelect(val, index)"
                  size="small"
                  class="w-full"
                >
                  <el-option 
                    v-for="p in existingProducts" 
                    :key="p.code" 
                    :label="p.code" 
                    :value="p.code" 
                  />
                </el-select>
              </div>

              <div class="w-1/4">
                <el-input v-model="item.product_name" placeholder="商品名称" size="small" />
              </div>

              <div class="w-1/6">
                <el-input-number v-model="item.quantity" :min="1" :step="1" controls-position="right" size="small" class="!w-full" />
              </div>

              <div class="w-1/6">
                <el-input-number v-model="item.purchase_price" :min="0" :precision="2" :controls="false" placeholder="采购价" size="small" class="!w-full" />
              </div>

              <div class="w-1/6">
                <el-input-number v-model="item.sale_price" :min="0" :precision="2" :controls="false" placeholder="零售价" size="small" class="!w-full" />
              </div>

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
          <el-button type="primary" :loading="submitLoading" @click="handleSubmit" size="small" class="!bg-primary !border-none !rounded-sm">确认入库并记账</el-button>
        </div>
      </template>
    </el-dialog>

  </div>
</template>

<script setup lang="ts">
import { ref, reactive, computed, onMounted } from 'vue'
import { ElMessage } from 'element-plus'
import type { FormInstance } from 'element-plus'
import axios from '../utils/request'

interface InboundItem {
  id: string
  product_code: string
  product_name: string
  quantity: number
  purchase_price: number
  sale_price: number
}

interface InboundReceiptItem {
  id: string
  tracking_number: string
  seller_order_number: string | null
  scheme_number: string | null
  is_settled: boolean
  created_at: string
  items: InboundItem[]
}

interface ProductItem {
  code: string
  name: string
  default_purchase_price: number | null
  default_sale_price: number | null
}

interface ActionLogItem {
  id: string
  user: { username: string } | null
  action_type: string
  tracking_number: string
  detail: string
  created_at: string
}

const activeTab = ref('list')
const loading = ref(false)
const logsLoading = ref(false)
const submitLoading = ref(false)

const inboundList = ref<InboundReceiptItem[]>([])
const inboundLogs = ref<ActionLogItem[]>([])
const existingProducts = ref<ProductItem[]>([])
const searchQuery = ref('')

const statusLoadingMap = ref<Record<string, boolean>>({})
const editingItemId = ref('')
const editingQty = ref(0)

const showDialog = ref(false)
const formRef = ref<FormInstance>()

const form = reactive({
  tracking_number: '',
  seller_order_number: '',
  scheme_number: '',
  items: [
    { product_code: '', product_name: '', quantity: 1, purchase_price: 0, sale_price: 0 }
  ]
})

const rules = {
  tracking_number: [{ required: true, message: '快递物流单号不能为空', trigger: 'blur' }]
}

const filteredInboundList = computed(() => {
  const query = searchQuery.value.trim().toLowerCase()
  if (!query) return inboundList.value
  return inboundList.value.filter(
    item => 
      (item.tracking_number && item.tracking_number.toLowerCase().includes(query)) ||
      (item.seller_order_number && item.seller_order_number.toLowerCase().includes(query)) ||
      (item.scheme_number && item.scheme_number.toLowerCase().includes(query))
  )
})

const fetchInboundList = async () => {
  loading.value = true
  try {
    const res: any = await axios.get('/api/inventory/inbound')
    inboundList.value = res
  } catch (err) {
  } finally {
    loading.value = false
  }
}

const fetchInboundLogs = async () => {
  logsLoading.value = true
  try {
    const res: any = await axios.get('/api/inventory/inbound/logs')
    inboundLogs.value = res
  } catch (err) {
  } finally {
    logsLoading.value = false
  }
}

const fetchExistingProducts = async () => {
  try {
    const res: any = await axios.get('/api/inventory/products')
    existingProducts.value = res
  } catch (err) {}
}

onMounted(() => {
  fetchInboundList()
  fetchExistingProducts()
})

const handleTabChange = (tabName: any) => {
  if (tabName === 'logs') {
    fetchInboundLogs()
  } else {
    fetchInboundList()
  }
}

const handleStatusChange = async (receiptId: string, val: boolean) => {
  statusLoadingMap.value[receiptId] = true
  try {
    await axios.put(`/api/inventory/inbound/${receiptId}/status`, { is_settled: val })
    ElMessage.success('结算状态更新成功')
  } catch (err) {
    const receipt = inboundList.value.find(r => r.id === receiptId)
    if (receipt) receipt.is_settled = !val
  } finally {
    statusLoadingMap.value[receiptId] = false
  }
}

const handleDeleteInbound = async (receiptId: string) => {
  try {
    const res: any = await axios.delete(`/api/inventory/inbound/${receiptId}`)
    ElMessage.success(res.message || '入库单已彻底删除，库存自动回扣修正')
    await fetchInboundList()
  } catch (err) {}
}

const startEditItem = (item: InboundItem) => {
  editingItemId.value = item.id
  editingQty.value = item.quantity
}

const cancelEditItem = () => {
  editingItemId.value = ''
}

const saveItemQty = async (item: InboundItem) => {
  if (editingQty.value <= 0) {
    ElMessage.warning('入库数量必须大于 0')
    return
  }
  try {
    await axios.put(`/api/inventory/inbound/item/${item.id}`, { quantity: editingQty.value })
    ElMessage.success('数量已更新，仓储即时库存已校准')
    editingItemId.value = ''
    await fetchInboundList()
  } catch (err) {}
}

const openCreateDialog = () => {
  form.tracking_number = ''
  form.seller_order_number = ''
  form.scheme_number = ''
  form.items = [
    { product_code: '', product_name: '', quantity: 1, purchase_price: 0, sale_price: 0 }
  ]
  showDialog.value = true
  fetchExistingProducts()
}

const addItemRow = () => {
  form.items.push({ product_code: '', product_name: '', quantity: 1, purchase_price: 0, sale_price: 0 })
}

const removeItemRow = (index: number) => {
  form.items.splice(index, 1)
}

const handleProductSelect = (code: string, index: number) => {
  const product = existingProducts.value.find(p => p.code === code)
  if (product) {
    form.items[index].product_name = product.name
    form.items[index].purchase_price = product.default_purchase_price || 0
    form.items[index].sale_price = product.default_sale_price || 0
  }
}

const handleSubmit = async () => {
  if (!formRef.value) return
  
  for (let i = 0; i < form.items.length; i++) {
    const item = form.items[i]
    if (!item.product_code || !item.product_name) {
      ElMessage.warning(`第 ${i + 1} 行商品编码和商品名称不能为空`)
      return
    }
  }

  await formRef.value.validate(async (valid) => {
    if (!valid) return
    submitLoading.value = true
    try {
      await axios.post('/api/inventory/inbound', form)
      ElMessage.success('入库单登记成功，库存已自动更新')
      showDialog.value = false
      await fetchInboundList()
    } catch (err) {
    } finally {
      submitLoading.value = false
    }
  })
}

const actionText = (action: string) => {
  const map: Record<string, string> = { CREATE: '新增单据', UPDATE: '修改数据', DELETE: '删除单据' }
  return map[action] || action
}

const actionClass = (action: string) => {
  if (action === 'CREATE') return 'bg-emerald-50 text-emerald-600 border border-emerald-200'
  if (action === 'UPDATE') return 'bg-amber-50 text-amber-600 border border-amber-200'
  return 'bg-rose-50 text-rose-600 border border-rose-200'
}

const formatDate = (isoStr: string) => {
  if (!isoStr) return '-'
  const d = new Date(isoStr)
  return d.toLocaleString('zh-CN', { hour12: false })
}
</script>

<style scoped>
.custom-tabs :deep(.el-tabs__header) {
  margin: 0;
  border-bottom: 1px solid #e2e8f0;
  padding: 0 24px;
  background-color: #f8fafc;
}
.custom-tabs :deep(.el-tabs__item) {
  font-size: 12px;
  font-weight: 600;
  padding: 18px 16px;
  height: auto;
}
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
