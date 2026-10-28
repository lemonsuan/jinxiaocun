<script setup lang="ts">
import { onBeforeUnmount, ref, watch } from 'vue';
import request from '../../utils/request';
import { useAuthStore } from '../../store/auth';
import ProtectedImage from '../../components/ProtectedImage.vue';
import { dateText } from '../../worker/logic';
import { parseBatchInput, type InboundBatch } from '../batch';
import { errorText, copyVisibleText } from '../logic';
import '../admin.css';
const auth = useAuthStore();
const input = ref('');
const archived = ref(false);
const result = ref<InboundBatch | null>(null);
const error = ref('');
const loading = ref(false);
const duplicates = ref(0);
const copied = ref(false);
let query: { numbers: string[]; archived: boolean } | null = null;
let controller: AbortController | undefined;
async function fetchPage(page = 1, productPage = 1) {
  if (!query) return;
  controller?.abort();
  const current = new AbortController();
  controller = current;
  loading.value = true;
  error.value = '';
  copied.value = false;
  try {
    const value = await request.post<never, InboundBatch>(
      '/api/view/inbound/batch',
      {
        tracking_numbers: query.numbers,
        page,
        page_size: 12,
        product_page: productPage,
        product_page_size: 50,
        include_archived: query.archived,
      },
      { signal: current.signal },
    );
    if (!current.signal.aborted) result.value = value;
  } catch (failure) {
    if (!current.signal.aborted) error.value = errorText(failure);
  } finally {
    if (!current.signal.aborted) loading.value = false;
  }
}
function search() {
  const parsed = parseBatchInput(input.value);
  error.value = parsed.error;
  if (parsed.error) return;
  duplicates.value = parsed.duplicates;
  query = { numbers: parsed.numbers, archived: archived.value };
  result.value = null;
  void fetchPage();
}
async function copyMissing() {
  if (result.value)
    copied.value = await copyVisibleText(
      result.value.unmatched_numbers.join('\n'),
    );
}
function clear() {
  controller?.abort();
  query = null;
  input.value = '';
  result.value = null;
  error.value = '';
  loading.value = false;
  duplicates.value = 0;
  copied.value = false;
}
watch(() => [auth.token, auth.activeShopId, auth.scopeVersion], clear);
onBeforeUnmount(() => controller?.abort());
</script>
<template>
  <section class="admin-section">
    <div class="admin-heading">
      <div>
        <h1>批量查快递 · 看图与商品汇总</h1>
        <p>
          粘贴多个快递单号，精确查询本店已同步入库记录，保留单号前导零。手机本机删除的记录仍可默认查询。
        </p>
      </div>
    </div>
    <form @submit.prevent="search">
      <label class="admin-form-field"
        ><span>快递单号（最多200个）</span
        ><textarea
          v-model="input"
          class="admin-input batch-input"
          rows="5"
          maxlength="60000"
          placeholder="每行一个，或用空格、逗号、分号分隔"
          aria-label="批量快递单号"
        />
      </label>
      <div class="admin-toolbar">
        <label class="batch-check"
          ><input v-model="archived" type="checkbox" /> 包含历史归档记录</label
        ><button class="admin-btn primary" :disabled="loading">
          {{ loading ? '查询中…' : '查询图片与商品总清单' }}</button
        ><button
          type="button"
          class="admin-btn"
          :disabled="loading"
          @click="clear"
        >
          清空
        </button>
      </div>
    </form>
    <div v-if="error" class="admin-error" role="alert">
      {{ error }}
      <button
        v-if="query"
        class="admin-btn"
        :disabled="loading"
        @click="
          fetchPage(result?.documents.page || 1, result?.products.page || 1)
        "
      >
        重试
      </button>
    </div>
    <div v-if="loading && !result" class="admin-empty" role="status">
      正在匹配快递并汇总整批商品…
    </div>
    <template v-if="result"
      ><div class="batch-totals">
        <div>
          <span>匹配快递</span
          ><strong
            >{{ result.matched_count }} /
            {{ result.tracking_numbers.length }}</strong
          >
        </div>
        <div>
          <span>整批商品种类</span
          ><strong>{{ result.totals.product_count }}</strong>
        </div>
        <div>
          <span>整批商品总数量</span
          ><strong>{{ result.totals.total_quantity }}</strong>
        </div>
      </div>
      <p class="admin-subtle">
        汇总覆盖本次全部匹配快递，不随图片或商品翻页变化。无编码明细独立展示。
      </p>
      <div v-if="duplicates || result.duplicate_count" class="admin-notice">
        已自动去除
        {{ duplicates + result.duplicate_count }} 个重复输入，不重复累计商品。
      </div>
      <div v-if="result.unmatched_numbers.length" class="batch-unmatched">
        <div>
          <strong>{{ result.unmatched_numbers.length }} 个单号尚未匹配</strong
          ><button class="admin-btn" @click="copyMissing">
            {{ copied ? '已复制' : '复制未匹配单号' }}
          </button>
        </div>
        <p>请核对单号，或等待手机将入库记录同步至服务器。</p>
        <textarea
          readonly
          :value="result.unmatched_numbers.join('\n')"
          rows="3"
          aria-label="未匹配的快递单号"
          class="admin-input"
        />
      </div>
      <div class="batch-section-heading">
        <h2>对应图片与入库商品</h2>
        <span>共 {{ result.documents.total }} 单 · 每页最多12张图片</span>
      </div>
      <div v-if="!result.documents.items.length" class="admin-empty">
        没有匹配的入库记录。
      </div>
      <div v-else class="batch-documents" :class="{ refreshing: loading }">
        <article
          v-for="document in result.documents.items"
          :key="document.id"
          class="batch-document"
        >
          <div class="batch-document-heading">
            <strong>{{ document.data.tracking_number }}</strong
            ><small>{{ dateText(document.data.created_at) }}</small>
          </div>
          <ProtectedImage
            v-if="document.data.image_sha256"
            :digest="document.data.image_sha256"
          />
          <div v-else class="batch-no-image">此入库记录暂无同步图片</div>
          <p v-if="document.data.seller_order_number" class="admin-subtle">
            商家单号：{{ document.data.seller_order_number }}
          </p>
          <div class="admin-table-wrap">
            <table class="admin-table">
              <thead>
                <tr>
                  <th>商品编码</th>
                  <th>商品名称</th>
                  <th>数量</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="(item, index) in document.data.items" :key="index">
                  <td>{{ item.product_code || '未编码' }}</td>
                  <td>{{ item.product_name }}</td>
                  <td>{{ item.quantity }}</td>
                </tr>
              </tbody>
            </table>
            <p v-if="!document.data.items.length" class="admin-subtle">
              暂无商品明细
            </p>
          </div>
        </article>
      </div>
      <div class="admin-pagination">
        <span>图片第 {{ result.documents.page }} 页</span
        ><button
          class="admin-btn"
          :disabled="loading || result.documents.page <= 1"
          @click="fetchPage(result.documents.page - 1, result.products.page)"
        >
          上一页图片</button
        ><button
          class="admin-btn"
          :disabled="
            loading ||
            result.documents.page * result.documents.page_size >=
              result.documents.total
          "
          @click="fetchPage(result.documents.page + 1, result.products.page)"
        >
          下一页图片
        </button>
      </div>
      <div class="batch-section-heading">
        <h2>整批商品总清单</h2>
        <span>数量按全部匹配快递累计</span>
      </div>
      <div class="admin-table-wrap">
        <table class="admin-table">
          <thead>
            <tr>
              <th>商品编码</th>
              <th>商品名称</th>
              <th>总数量</th>
              <th>快递单数</th>
              <th>来源快递</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="product in result.products.items" :key="product.key">
              <td>{{ product.product_code || '未编码（独立明细）' }}</td>
              <td>
                {{ product.product_name
                }}<small
                  v-if="(product.name_variants?.length || 0) > 1"
                  class="batch-name-variants"
                  >同编码名称：{{ product.name_variants?.join('、') }}</small
                >
              </td>
              <td class="admin-amount">{{ product.quantity }}</td>
              <td>{{ product.receipt_count }}</td>
              <td class="admin-word-break">
                {{ product.tracking_numbers.join('、') }}
              </td>
            </tr>
          </tbody>
        </table>
        <div v-if="!result.products.items.length" class="admin-empty">
          暂无已同步商品明细。
        </div>
      </div>
      <div class="admin-pagination">
        <span
          >共 {{ result.products.total }} 项 · 第
          {{ result.products.page }} 页</span
        ><button
          class="admin-btn"
          :disabled="loading || result.products.page <= 1"
          @click="fetchPage(result.documents.page, result.products.page - 1)"
        >
          上一页商品</button
        ><button
          class="admin-btn"
          :disabled="
            loading ||
            result.products.page * result.products.page_size >=
              result.products.total
          "
          @click="fetchPage(result.documents.page, result.products.page + 1)"
        >
          下一页商品
        </button>
      </div></template
    >
    <div v-else-if="!loading && !error" class="admin-empty">
      输入需要核对的快递单号，一次查看对应图片和全部商品。
    </div>
  </section>
</template>
<style scoped>
.batch-input {
  font-variant-numeric: tabular-nums;
  line-height: 1.8;
  resize: vertical;
}
.batch-check {
  display: flex;
  align-items: center;
  gap: 7px;
  color: #758b7b;
  font-size: 12px;
  flex: 1;
  min-width: 200px;
}
.batch-check input {
  accent-color: #487d58;
}
.batch-totals {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 12px;
  margin: 20px 0 12px;
}
.batch-totals > div {
  padding: 19px;
  background: #f1f7f3;
  border-radius: 9px;
  min-width: 0;
}
.batch-totals span {
  display: block;
  color: #8b9f91;
  font-size: 11px;
}
.batch-totals strong {
  display: block;
  color: #376849;
  font-size: 25px;
  margin-top: 9px;
  overflow-wrap: anywhere;
}
.batch-unmatched {
  background: #fff8e9;
  border: 1px solid #eddfc0;
  padding: 16px;
  border-radius: 9px;
  margin: 19px 0;
}
.batch-unmatched > div {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  color: #947236;
  font-size: 13px;
}
.batch-unmatched p {
  font-size: 11px;
  color: #a58c5f;
  margin: 10px 0;
}
.batch-unmatched textarea {
  font-size: 12px;
  line-height: 1.8;
  resize: vertical;
}
.batch-section-heading {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  margin: 28px 0 16px;
  flex-wrap: wrap;
}
.batch-section-heading h2 {
  font-size: 16px;
  color: #3c6348;
  font-weight: 700;
  margin: 0;
}
.batch-section-heading > span {
  font-size: 11px;
  color: #94a597;
}
.batch-documents {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(min(330px, 100%), 1fr));
  gap: 18px;
}
.batch-documents.refreshing {
  opacity: 0.55;
  pointer-events: none;
}
.batch-document {
  border: 1px solid #dfe8e1;
  border-radius: 10px;
  padding: 16px;
  min-width: 0;
}
.batch-document-heading {
  display: flex;
  flex-direction: column;
  gap: 8px;
  margin-bottom: 14px;
}
.batch-document-heading strong {
  color: #3b6a4a;
  font-size: 15px;
  overflow-wrap: anywhere;
}
.batch-document-heading small {
  font-size: 10px;
  color: #a0afa5;
}
.batch-no-image {
  height: 180px;
  background: #f5f7f4;
  border-radius: 7px;
  display: grid;
  place-items: center;
  color: #a3afa5;
  font-size: 12px;
}
.batch-document .admin-table-wrap {
  margin-top: 14px;
}
.batch-document .admin-table td {
  overflow-wrap: anywhere;
}
.batch-name-variants {
  display: block;
  color: #aa8b54;
  font-size: 10px;
  margin-top: 6px;
}
@media (max-width: 600px) {
  .batch-totals {
    gap: 7px;
  }
  .batch-totals > div {
    padding: 13px 9px;
  }
  .batch-totals strong {
    font-size: 21px;
  }
  .batch-totals span {
    font-size: 10px;
  }
  .batch-document {
    padding: 12px;
  }
}
</style>
