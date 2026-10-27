import request from '../utils/request'

export type Collection = 'products' | 'inbound' | 'outbound' | 'stocks' | 'ledger' | 'logs'
export interface LineItem { id: string; product_code: string; product_name: string; quantity: number; purchase_price?: number | null; sale_price?: number | null }
export interface DocumentData {
  code?: string; name?: string; default_purchase_price?: number | null; default_sale_price?: number | null
  tracking_number?: string; seller_order_number?: string; rebate_order_number?: string; scheme_number?: string
  created_at?: string; updated_at?: string; ocr_status?: string; is_settled?: boolean
  logistics_number?: string; note?: string; image_sha256?: string; image_sha256s?: string[]; items?: LineItem[]
}
export interface DocumentRecord { kind: 'product' | 'inbound' | 'outbound'; id: string; revision: number; data: DocumentData }
export interface SummaryRow { id?: string; product_code?: string; product_name?: string; quantity?: number; delta?: number; reason?: string; source_id?: string; created_at?: string; username?: string; action_type?: string; tracking_number?: string; detail?: string }
export type ViewRow = SummaryRow & DocumentData & { id?: string; revision?: number }
export interface Page<T> { items: T[]; total: number; page: number; page_size: number }
export interface ViewQuery { page: number; page_size: number; q?: string; date_from?: string; date_to?: string; is_settled?: boolean; include_archived?: boolean }
export async function loadPage(collection: Collection, params: ViewQuery, signal: AbortSignal): Promise<Page<ViewRow>> {
  const page = await request.get<never, Page<DocumentRecord | SummaryRow>>(`/api/view/${collection}`, { params, signal })
  return { ...page, items: page.items.map(row => 'data' in row ? { ...row.data, id: row.id, revision: row.revision } : row) }
}
export function loadDocument(collection: 'inbound' | 'outbound', id: string, signal: AbortSignal) {
  return request.get<never, DocumentRecord>(`/api/view/${collection}/${encodeURIComponent(id)}`, { signal })
}
export function formatDate(value?: string) {
  if (!value) return '—'
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? value : date.toLocaleString('zh-CN', { hour12: false })
}
