import type { ProductSummary } from './types';
export interface BatchPage<T> {
  items: T[];
  total: number;
  page: number;
  page_size: number;
}
export interface BatchDocument {
  id: string;
  revision: number;
  data: {
    tracking_number: string;
    seller_order_number: string;
    image_sha256: string | null;
    created_at: string;
    items: {
      product_code: string;
      product_name: string;
      quantity: number;
      purchase_price: number | null;
      sale_price: number | null;
    }[];
  };
}
export interface InboundBatch {
  tracking_numbers: string[];
  duplicate_count: number;
  unmatched_numbers: string[];
  matched_count: number;
  documents: BatchPage<BatchDocument>;
  products: BatchPage<ProductSummary>;
  totals: {
    document_count: number;
    product_count: number;
    total_quantity: number;
  };
}
export function parseBatchInput(value: string): {
  numbers: string[];
  duplicates: number;
  error: string;
} {
  if (value.length > 60000)
    return {
      numbers: [],
      duplicates: 0,
      error: '输入内容过长，每次最多查询200个快递单号。',
    };
  const tokens = value
    .trim()
    .split(/[\s,，;；]+/u)
    .filter(Boolean);
  const numbers = [...new Set(tokens)];
  const error = !numbers.length
    ? '请至少输入一个快递单号。'
    : numbers.length > 200
      ? '每次最多查询200个不同的快递单号。'
      : numbers.some((number) => number.length > 100)
        ? '单个快递单号不能超过100个字符。'
        : '';
  return { numbers, duplicates: tokens.length - numbers.length, error };
}
