import type { AdminOrder } from './types.ts';

/** 由已核对的同一份详情快照构造返款确认，重试不能混入后来的收款资料。 */
export function settlementInput(order: AdminOrder, operationId: string) {
  return {
    expected_version: order.version,
    expected_job_version: order.job.version,
    expected_payout_version: order.payout?.version ?? 0,
    operation_id: operationId,
    evidence: order.parcels
      .filter((parcel) => parcel.receipt)
      .map((parcel) => ({
        tracking_number: parcel.tracking_number,
        receipt_id: parcel.receipt!.receipt_id,
        revision: parcel.receipt!.revision,
      })),
  };
}
