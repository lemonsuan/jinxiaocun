<template>
  <div class="bg-white border border-slate-200 rounded-md p-6 shadow-[0_1px_3px_rgba(0,0,0,0.02)]">
    <!-- 头部搜索和动作 -->
    <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between pb-6 border-b border-slate-100 gap-4 mb-6">
      <div>
        <h2 class="text-sm font-bold text-slate-800">店铺商品清单</h2>
        <p class="text-[11px] text-slate-400 mt-1">创建和维护本店铺内所有流转商品的商品规格定义表。</p>
      </div>
      <div class="flex gap-2 shrink-0">
        <el-input 
          v-model="searchQuery" 
          placeholder="搜索商品名称/编码..." 
          clearable
          size="small"
          class="w-56"
        />
        <el-button type="primary" size="small" @click="openCreateDialog" class="!bg-primary hover:!bg-primary-hover !border-none !rounded-sm">
          新增商品规格
        </el-button>
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
      <el-table-column prop="code" label="商品编码" width="180" font-mono />
      <el-table-column prop="name" label="商品名称" min-width="200" />
      <el-table-column prop="default_purchase_price" label="默认采购价" width="130" align="right">
        <template #default="scope">
          <span class="font-mono text-slate-600">
            {{ scope.row.default_purchase_price ? `￥${scope.row.default_purchase_price}` : '-' }}
          </span>
        </template>
      </el-table-column>
      <el-table-column prop="default_sale_price" label="默认零售价" width="130" align="right">
        <template #default="scope">
          <span class="font-mono text-slate-600">
            {{ scope.row.default_sale_price ? `￥${scope.row.default_sale_price}` : '-' }}
          </span>
        </template>
      </el-table-column>
      <el-table-column label="操作" width="130" align="center" fixed="right">
        <template #default="scope">
          <div class="flex justify-center gap-2">
            <button @click="openEditDialog(scope.row)" class="text-xs text-primary hover:underline font-medium cursor-pointer">修改</button>
            <el-popconfirm title="确定软删除这件商品吗？" @confirm="handleDelete(scope.row.id)">
              <template #reference>
                <button class="text-xs text-rose-600 hover:underline font-medium cursor-pointer">删除</button>
              </template>
            </el-popconfirm>
          </div>
        </template>
      </el-table-column>
    </el-table>

    <!-- 弹窗：新建/编辑商品 -->
    <el-dialog 
      v-model="showDialog" 
      :title="dialogTitle" 
      width="420px"
      class="custom-dialog"
    >
      <el-form :model="form" ref="formRef" :rules="rules" label-width="100px" size="small">
        <el-form-item label="商品编码" prop="code">
          <el-input v-model="form.code" placeholder="如 ESTEE-ANR-50" :disabled="isEdit" />
        </el-form-item>
        <el-form-item label="商品名称" prop="name">
          <el-input v-model="form.name" placeholder="请输入商品名称" />
        </el-form-item>
        <el-form-item label="默认采购价" prop="default_purchase_price">
          <el-input-number v-model="form.default_purchase_price" :precision="2" :step="1" :min="0" class="!w-full" />
        </el-form-item>
        <el-form-item label="默认零售价" prop="default_sale_price">
          <el-input-number v-model="form.default_sale_price" :precision="2" :step="1" :min="0" class="!w-full" />
        </el-form-item>
      </el-form>
      <template #footer>
        <div class="dialog-footer">
          <el-button @click="showDialog = false" size="small" class="!rounded-sm">取消</el-button>
          <el-button type="primary" :loading="submitLoading" @click="handleSubmit" size="small" class="!bg-primary !border-none !rounded-sm">确定</el-button>
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

interface ProductItem {
  id: string
  code: string
  name: string
  default_purchase_price: number | null
  default_sale_price: number | null
}

const loading = ref(false)
const submitLoading = ref(false)
const products = ref<ProductItem[]>([])
const searchQuery = ref('')

const showDialog = ref(false)
const isEdit = ref(false)
const editId = ref('')
const formRef = ref<FormInstance>()

const form = reactive({
  code: '',
  name: '',
  default_purchase_price: 0,
  default_sale_price: 0
})

const rules = {
  code: [{ required: true, message: '商品编码不能为空', trigger: 'blur' }],
  name: [{ required: true, message: '商品名称不能为空', trigger: 'blur' }]
}

const dialogTitle = computed(() => isEdit.value ? '编辑商品规格' : '新增商品规格')

const fetchProducts = async () => {
  loading.value = true
  try {
    const res: any = await axios.get('/api/inventory/products')
    products.value = res
  } catch (err) {
  } finally {
    loading.value = false
  }
}

onMounted(() => {
  fetchProducts()
})

const filteredData = computed(() => {
  const query = searchQuery.value.trim().toLowerCase()
  if (!query) return products.value
  return products.value.filter(
    item => 
      item.name.toLowerCase().includes(query) || 
      item.code.toLowerCase().includes(query)
  )
})

const openCreateDialog = () => {
  isEdit.value = false
  editId.value = ''
  form.code = ''
  form.name = ''
  form.default_purchase_price = 0
  form.default_sale_price = 0
  showDialog.value = true
}

const openEditDialog = (row: ProductItem) => {
  isEdit.value = true
  editId.value = row.id
  form.code = row.code
  form.name = row.name
  form.default_purchase_price = row.default_purchase_price || 0
  form.default_sale_price = row.default_sale_price || 0
  showDialog.value = true
}

const handleSubmit = async () => {
  if (!formRef.value) return
  await formRef.value.validate(async (valid) => {
    if (!valid) return
    submitLoading.value = true
    
    try {
      if (isEdit.value) {
        await axios.put(`/api/inventory/products/${editId.value}`, form)
        ElMessage.success('商品信息更新成功')
      } else {
        await axios.post('/api/inventory/products', form)
        ElMessage.success('商品规格新增成功')
      }
      showDialog.value = false
      await fetchProducts()
    } catch (err) {
    } finally {
      submitLoading.value = false
    }
  })
}

const handleDelete = async (id: string) => {
  try {
    await axios.delete(`/api/inventory/products/${id}`)
    ElMessage.success('商品删除成功')
    await fetchProducts()
  } catch (err) {}
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
:deep(.custom-dialog .el-input-number .el-input__wrapper) {
  border-radius: 4px;
}
</style>
