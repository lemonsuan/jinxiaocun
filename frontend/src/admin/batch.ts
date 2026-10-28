import type { ProductSummary } from './types';

/**
 * 批量分页数据包裹结构。
 */
export interface BatchPage<T> {
  /** 当前页的数据条目列表 */
  items: T[];
  /** 满足条件的总记录条数 */
  total: number;
  /** 当前所在页码（从1开始） */
  page: number;
  /** 每页展示记录上限条数 */
  page_size: number;
}

/**
 * 批量查询到的入库单据详情。
 */
export interface BatchDocument {
  /** 入库单全局唯一 UUID */
  id: string;
  /** 数据修改版本号 */
  revision: number;
  /** 单据核心快照数据 */
  data: {
    /** 快递单号 */
    tracking_number: string;
    /** 关联商家/平台订单号 */
    seller_order_number: string;
    /** 凭证图片私有媒体库 SHA256 哈希值 */
    image_sha256: string | null;
    /** 入库单创建时间 ISO 字符串 */
    created_at: string;
    /** 包含的商品明细列表 */
    items: {
      /** 商品编码 */
      product_code: string;
      /** 商品名称 */
      product_name: string;
      /** 入库数量 */
      quantity: number;
      /** 采购进价（若有） */
      purchase_price: number | null;
      /** 预设销售价（若有） */
      sale_price: number | null;
    }[];
  };
}

/**
 * 批量快递查单与查图的完整响应结果。
 */
export interface InboundBatch {
  /** 成功识别提取出的全部输入快递单号列表（去重后） */
  tracking_numbers: string[];
  /** 输入文本中被剔除的重复单号计数 */
  duplicate_count: number;
  /** 在本店历史入库单中未检索到的快递单号列表 */
  unmatched_numbers: string[];
  /** 成功在库检索到的快递单总数 */
  matched_count: number;
  /** 匹配到的入库单据分页对象 */
  documents: BatchPage<BatchDocument>;
  /** 匹配到的所有商品汇总去重分页对象 */
  products: BatchPage<ProductSummary>;
  /** 本次批量查询结果的汇总统计指标 */
  totals: {
    /** 入库单总量 */
    document_count: number;
    /** 涉及的商品种类总量 */
    product_count: number;
    /** 全部商品数量累加总和 */
    total_quantity: number;
  };
}

/**
 * 解析用户在批量查询输入框中粘贴的文本内容。
 *
 * 支持以空格、换行、中文/英文逗号、分号等任意常见标点混合分隔；
 * 自动执行去重、空字符剔除、长度截断保护与上限校验（最多200个不同单号）。
 *
 * @param value 用户输入的原始多行/多分隔符文本
 * @returns 包含解析去重后的单号数组 [numbers]、重复计数 [duplicates] 及校验错误提示 [error]
 */
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
