export interface WorkerInfo {
  id: string;
  username: string;
  display_name: string;
  shop_number: string;
  shop_name: string;
}

export interface WorkerSession {
  token: string;
  worker: WorkerInfo;
}
export interface WorkerScope {
  token: string;
  workerId: string;
  shopNumber: string;
  epoch: number;
}
export interface WorkerShop {
  shop_number: string;
  name: string;
}
export interface Page<T> {
  items: T[];
  total: number;
  page: number;
  page_size: number;
}
export type OrderStatus = 'in_transit' | 'arrived' | 'settled';
export interface WorkerJob {
  id: string;
  shop_number: string;
  title: string;
  description: string;
  status: 'open' | 'closed';
  cost_amount: string;
  refund_amount: string;
  photos: { sha256: string }[];
  version: number;
  created_at: string;
  updated_at: string;
  own_order_count?: number;
  can_report?: boolean;
}
export interface WorkerParcel {
  id: string;
  tracking_number: string;
  arrived: boolean;
  arrived_at: string | null;
}
export interface WorkerOrder {
  id: string;
  job: Pick<
    WorkerJob,
    'id' | 'title' | 'status' | 'version' | 'cost_amount' | 'refund_amount'
  >;
  order_number: string;
  version: number;
  status: OrderStatus;
  parcel_count: number;
  arrived_count: number;
  parcels: WorkerParcel[];
  settled_at: string | null;
  settlement?: {
    cost_amount: string;
    refund_amount: string;
    settled_at: string;
  } | null;
  created_at: string;
  updated_at: string;
}
export interface CreateOrderInput {
  job_id: string;
  order_number: string;
  tracking_numbers: string[];
  operation_id: string;
}
export interface UpdateOrderInput {
  order_number: string;
  tracking_numbers: string[];
  expected_version: number;
  operation_id: string;
}
