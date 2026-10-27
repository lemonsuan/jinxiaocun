<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue'
import { loadPage, loadDocument, formatDate, type Collection, type ViewRow, type DocumentRecord } from '../api/view'
import { useAuthStore } from '../store/auth'
import ProtectedImage from './ProtectedImage.vue'
const props = defineProps<{ collection: Collection; title: string }>()
const auth = useAuthStore()
const q = ref(''); const dates = ref<[string, string] | null>(null); const settled = ref<string>(''); const archived = ref(false)
const page = ref(1); const pageSize = ref(20); const total = ref(0); const rows = ref<ViewRow[]>([])
const loading = ref(false); const failed = ref(false); const detailOpen = ref(false); const detailLoading = ref(false); const detail = ref<DocumentRecord>()
let listController: AbortController | undefined; let detailController: AbortController | undefined
const isDocument = computed(() => ['inbound', 'outbound'].includes(props.collection))
const hasDate = computed(() => !['stocks'].includes(props.collection))
interface Column { key: keyof ViewRow; label: string; width?: number }
const columns = computed<Column[]>(() => {
  switch (props.collection) {
    case 'products': return [{key:'code',label:'商品编码'}, {key:'name',label:'商品名称'}, {key:'default_purchase_price',label:'默认采购价'}, {key:'default_sale_price',label:'默认销售价'}, {key:'updated_at',label:'更新时间',width:185}]
    case 'inbound': return [{key:'tracking_number',label:'快递单号'}, {key:'seller_order_number',label:'商家单号'}, {key:'is_settled',label:'结算状态',width:100}, {key:'ocr_status',label:'识别状态',width:110}, {key:'created_at',label:'入库时间',width:185}]
    case 'outbound': return [{key:'logistics_number',label:'物流单号'}, {key:'note',label:'备注'}, {key:'created_at',label:'出库时间',width:185}]
    case 'stocks': return [{key:'product_code',label:'商品编码'}, {key:'product_name',label:'商品名称'}, {key:'quantity',label:'当前数量',width:150}]
    case 'ledger': return [{key:'product_code',label:'商品编码'}, {key:'product_name',label:'商品名称'}, {key:'delta',label:'数量变化',width:100}, {key:'reason',label:'变更原因'}, {key:'source_id',label:'来源单据'}, {key:'created_at',label:'记录时间',width:185}]
    default: return [{key:'username',label:'操作人'}, {key:'action_type',label:'操作'}, {key:'tracking_number',label:'快递单号'}, {key:'detail',label:'详情'}, {key:'created_at',label:'操作时间',width:185}]
  }
})
function ocrStatus(value: unknown) {
  return ({pending:'待识别',processing:'识别中',needsReview:'待核对',confirmed:'已确认',failed:'识别失败'} as Record<string,string>)[String(value)] || '待核对'
}
function cell(row: ViewRow, key: keyof ViewRow) {
  const value = row[key]
  if (key === 'created_at' || key === 'updated_at') return formatDate(typeof value === 'string' ? value : undefined)
  if (key === 'ocr_status') return ocrStatus(value)
  if (key === 'is_settled') return value ? '已结算' : '未结算'
  if (key === 'delta' && typeof value === 'number') return value > 0 ? `+${value}` : value
  return value === undefined || value === null || value === '' ? '—' : value
}
async function fetchRows() {
  listController?.abort(); const current = new AbortController(); listController = current
  rows.value = []; loading.value = false; failed.value = false
  if (!auth.token || !auth.activeShopId) { total.value = 0; return }
  loading.value = true
  try {
    const result = await loadPage(props.collection, { page: page.value, page_size: pageSize.value, q: q.value.trim() || undefined, date_from: dates.value?.[0], date_to: dates.value?.[1], is_settled: settled.value ? settled.value === 'true' : undefined, include_archived: archived.value }, current.signal)
    if (!current.signal.aborted) { rows.value = result.items; total.value = result.total }
  } catch { if (!current.signal.aborted) { failed.value = true; total.value = 0 } }
  finally { if (!current.signal.aborted) loading.value = false }
}
function search() { page.value = 1; fetchRows() }
function reset() { q.value = ''; dates.value = null; settled.value = ''; archived.value = false; search() }
async function openDetail(row: ViewRow) {
  if (!row.id || (props.collection !== 'inbound' && props.collection !== 'outbound')) return
  detailController?.abort(); const current = new AbortController(); detailController = current
  detail.value = undefined; detailOpen.value = true; detailLoading.value = true
  try { const result = await loadDocument(props.collection, row.id, current.signal); if (!current.signal.aborted) detail.value = result }
  catch { /* global request feedback; drawer retains retry instruction */ }
  finally { if (!current.signal.aborted) detailLoading.value = false }
}
const photos = computed(() => detail.value?.data.image_sha256 ? [detail.value.data.image_sha256] : detail.value?.data.image_sha256s || [])
watch(detailOpen, open => { if (!open) { detailController?.abort(); detail.value = undefined } })
watch(() => [auth.token, auth.activeShopId, auth.scopeVersion, props.collection], () => { detailOpen.value = false; total.value = 0; page.value = 1; fetchRows() }, { immediate: true })
onBeforeUnmount(() => { listController?.abort(); detailController?.abort() })
</script>
<template>
  <section class="viewer">
    <div class="viewer-heading"><div><h2>{{ title }}</h2><p>查看店铺已同步至服务器的数据 · 共 {{ total }} 条</p></div><el-tag type="info" effect="plain">只读查看</el-tag></div>
    <el-alert class="retention-note" type="info" :closable="false" show-icon title="手机删除仅影响该手机的显示，服务器和其他手机仍保留记录；此处展示服务器留存数据。" />
    <form class="filters" @submit.prevent="search">
      <el-input v-model="q" clearable placeholder="搜索编码、名称或单号" aria-label="搜索记录" class="search-input" />
      <el-date-picker v-if="hasDate" v-model="dates" type="daterange" value-format="YYYY-MM-DD" start-placeholder="开始日期" end-placeholder="结束日期" range-separator="至" />
      <el-select v-if="collection === 'inbound'" v-model="settled" placeholder="全部结算状态" aria-label="结算状态" style="width: 145px"><el-option label="全部结算状态" value=""/><el-option label="未结算" value="false"/><el-option label="已结算" value="true"/></el-select>
      <el-checkbox v-if="['products','inbound','outbound'].includes(collection)" v-model="archived">含历史归档</el-checkbox>
      <el-button type="primary" native-type="submit" :loading="loading">查询</el-button><el-button @click="reset">重置</el-button><el-button @click="fetchRows" :disabled="loading">刷新</el-button>
    </form>
    <el-alert v-if="failed" title="加载失败，请检查网络与店铺权限后重试。" type="error" :closable="false" class="mb-4" />
    <el-table :data="rows" v-loading="loading" stripe style="width:100%" empty-text="暂无匹配记录；请在手机同步后刷新，或调整筛选条件。">
      <el-table-column v-for="column in columns" :key="column.key" :label="column.label" :width="column.width" min-width="140" show-overflow-tooltip><template #default="{row}"><span :class="{'quantity':column.key === 'quantity' || column.key === 'delta'}">{{ cell(row,column.key) }}</span></template></el-table-column>
      <el-table-column v-if="isDocument" label="查看" fixed="right" width="90"><template #default="{row}"><el-button link type="primary" @click="openDetail(row)">单据详情</el-button></template></el-table-column>
    </el-table>
    <div class="pagination"><el-pagination v-model:current-page="page" v-model:page-size="pageSize" :page-sizes="[20,50,100]" :total="total" layout="total, sizes, prev, pager, next" @current-change="fetchRows" @size-change="search" /></div>
    <el-drawer v-model="detailOpen" :title="collection === 'inbound' ? '入库单据详情' : '出库单据详情'" size="min(760px, 95vw)" destroy-on-close>
      <div v-loading="detailLoading" style="min-height:180px">
        <template v-if="detail">
          <el-descriptions :column="1" border>
            <el-descriptions-item label="创建时间">{{ formatDate(detail.data.created_at) }}</el-descriptions-item>
            <template v-if="collection === 'inbound'">
              <el-descriptions-item label="快递单号">{{ detail.data.tracking_number }}</el-descriptions-item><el-descriptions-item label="商家单号">{{ detail.data.seller_order_number || '—' }}</el-descriptions-item><el-descriptions-item label="返利单号">{{ detail.data.rebate_order_number || '—' }}</el-descriptions-item><el-descriptions-item label="方案编号">{{ detail.data.scheme_number || '—' }}</el-descriptions-item><el-descriptions-item label="结算 / 识别">{{ detail.data.is_settled ? '已结算' : '未结算' }} / {{ ocrStatus(detail.data.ocr_status) }}</el-descriptions-item>
            </template>
            <template v-else><el-descriptions-item label="物流单号">{{ detail.data.logistics_number || '—' }}</el-descriptions-item><el-descriptions-item label="备注">{{ detail.data.note || '—' }}</el-descriptions-item></template>
          </el-descriptions>
          <h3 class="detail-title">商品明细</h3>
          <el-table :data="detail.data.items || []" border empty-text="此单据没有商品明细"><el-table-column prop="product_code" label="编码" min-width="120"/><el-table-column prop="product_name" label="商品名称" min-width="150"/><el-table-column prop="quantity" label="数量" width="80"/><el-table-column v-if="collection === 'inbound'" prop="purchase_price" label="采购价" width="90"/><el-table-column v-if="collection === 'inbound'" prop="sale_price" label="销售价" width="90"/></el-table>
          <h3 class="detail-title">原始凭证 <span class="text-slate-400 font-normal text-xs">点击图片放大</span></h3>
          <div v-if="photos.length" class="photos"><ProtectedImage v-for="digest in photos" :key="digest" :digest="digest"/></div><el-empty v-else description="此单据暂无同步图片" :image-size="70"/>
        </template>
        <el-empty v-else-if="!detailLoading" description="详情加载失败，请关闭后重试"/>
      </div>
    </el-drawer>
  </section>
</template>
<style scoped>
.viewer { background: white; border:1px solid #e2e8f0; border-radius:6px; padding:24px; }
.viewer-heading { display:flex; align-items:center; justify-content:space-between; gap:16px; margin-bottom:20px; }
h2 { font-size:16px; font-weight:650; margin:0; } .viewer-heading p { color:#64748b; font-size:12px; margin:6px 0 0; }
.retention-note { margin-bottom:20px; } .filters { display:flex; flex-wrap:wrap; align-items:center; gap:10px; margin-bottom:22px; } .search-input { width:240px; } .pagination { display:flex; justify-content:flex-end; margin-top:22px; overflow:auto; }
.quantity { font-weight:650; font-variant-numeric: tabular-nums; } .detail-title { font-size:14px; font-weight:650; margin:26px 0 12px; } .photos { display:grid; grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); gap:12px; }
:deep(.el-table th.el-table__cell) { background:#f8fafc; } :deep(.el-descriptions__content) { overflow-wrap:anywhere; }
@media(max-width:640px) { .viewer {padding:14px;} .search-input {width:100%;} }
</style>
