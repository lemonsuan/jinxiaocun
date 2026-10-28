import type { WorkerJob, WorkerOrder, WorkerParcel } from '../worker/types';
export interface ProductSummary {
  key: string;
  product_code: string;
  product_name: string;
  quantity: number;
  receipt_count?: number;
  tracking_numbers: string[];
  name_variants?: string[];
}
export interface ReceiptEvidence {
  receipt_id: string;
  document_key: string;
  revision: number;
  image_sha256: string | null;
  created_at: string;
  items: {
    product_code: string;
    product_name: string;
    quantity: number;
    purchase_price?: string | null;
    sale_price?: string | null;
  }[];
}
export interface SettlementSnapshot {
  order_number: string;
  tracking_numbers: string[];
  job_title: string;
  job_version: number;
  worker_id: string;
  worker_name: string;
  evidence: { tracking_number: string; receipt_id: string; revision: number }[];
  receipt_snapshots: (ReceiptEvidence & { tracking_number: string })[];
  job: {
    title: string;
    version: number;
    cost_amount: string;
    refund_amount: string;
    photo_sha256s: string[];
  };
}
export interface AdminSettlement {
  id: string;
  cost_amount: string;
  refund_amount: string;
  is_active: boolean;
  created_at: string;
  operator: string | null;
  reopened_at: string | null;
  reopen_reason: string;
  snapshot: SettlementSnapshot | null;
}
export interface AdminParcel extends WorkerParcel {
  duplicate_claim: boolean;
  receipt?: ReceiptEvidence | null;
}
export type AdminOrder = Omit<WorkerOrder, 'parcels' | 'settlement'> & {
  worker: { id: string; username: string; display_name: string };
  parcels: AdminParcel[];
  products?: ProductSummary[];
  settlement?: AdminSettlement | null;
  settlement_history?: AdminSettlement[];
  evidence_changed?: boolean;
};
export interface AdminJob extends WorkerJob {
  order_count: number;
}
export interface AdminWorker {
  id: string;
  username: string;
  display_name: string;
  phone: string;
  shop_number: string;
  shop_name: string;
  enabled: boolean;
  version: number;
  created_at: string;
  updated_at: string;
}
export interface JobInput {
  title: string;
  description: string;
  cost_amount: string;
  refund_amount: string;
  photo_sha256s: string[];
  status: 'open' | 'closed';
}
export interface Member {
  id: string;
  user: { id: string; username: string };
  role: 'CREATOR' | 'ADMIN';
  status: 'PENDING' | 'APPROVED' | 'REJECTED';
  joined_at: string;
}
