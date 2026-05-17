# Database Guidelines

> Database patterns and conventions for this project.

---

## Overview

<!--
Document your project's database conventions here.

Questions to answer:
- What ORM/query library do you use?
- How are migrations managed?
- What are the naming conventions for tables/columns?
- How do you handle transactions?
-->

The MVP uses local SQLite through Flutter `sqflite`. SQLite is the single-device source of truth; cloud sync, if added later, is a backup/copy layer and must not decide local stock availability.

## Scenario: Local Inventory Ledger

### 1. Scope / Trigger

Use this contract when changing inbound, outbound, stock query, or local persistence code.

### 2. Signatures

Core tables: `inbound_receipts`, `inbound_items`, `outbound_orders`, `outbound_items`, `outbound_attachments`, `stock_ledger`, `warehouse_stock`, and `ocr_results`.

### 3. Contracts

`stock_ledger` is the authoritative inventory record. `warehouse_stock` is a query cache derived from ledger writes. Price fields are optional and must not block inbound or outbound confirmation.

Outbound photos are order evidence only. Store them as local sandbox image paths in `outbound_attachments` and expose them through `OutboundOrder.imagePaths`; they must not run OCR, create outbound items, or decide stock deltas. Outbound stock movement comes only from the user-confirmed `OutboundItem` list in the same SQLite transaction that writes `outbound_orders`, `outbound_items`, ledger rows, and stock cache updates.

### 4. Validation & Error Matrix

* Duplicate inbound tracking number -> reject confirmation.
* Outbound quantity greater than current stock -> reject confirmation.
* OCR failure or empty OCR rows -> keep receipt editable; do not write stock.
* Missing outbound attachment file -> show a broken image state if displayed; do not reverse stock or mutate the order.

### 5. Good/Base/Bad Cases

* Good: inbound/outbound confirmation writes ledger and updates stock in one SQLite transaction.
* Good: outbound cart items generate an outbound order with optional `outbound_attachments` rows; photos are visible in history but never parsed into items.
* Base: settlement marker changes only `inbound_receipts`, not stock.
* Base: outbound order has no photos; stock still deducts from confirmed items.
* Bad: directly editing `warehouse_stock` without a matching `stock_ledger` row.
* Bad: running OCR on outbound photos or using photo content to create/deduct outbound items.

### 6. Tests Required

Tests must assert stock increases on inbound, stock cannot go negative on outbound, duplicate tracking numbers are rejected, settlement changes do not alter stock, and outbound orders preserve multi-photo attachment paths without changing item quantities.

### 7. Wrong vs Correct

Wrong: compute stock from the latest UI list or OCR result.

Correct: compute stock from confirmed ledger writes, using `warehouse_stock` only as a persisted summary.

Wrong: generate outbound items from outbound proof photos.

Correct: generate outbound orders from cart items; save photos only as `outbound_attachments` evidence for history.

---

## Query Patterns

<!-- How should queries be written? Batch operations? -->

Use SQLite transactions for every operation that confirms inbound or outbound stock movement. Query history from receipt/order tables and current totals from `warehouse_stock`.

---

## Migrations

<!-- How to create and run migrations -->

Schema is currently created in `mobile_app/lib/src/data/local_database_schema.dart`. Add explicit versioned migrations before changing existing table shapes after data is in use.

---

## Naming Conventions

<!-- Table names, column names, index names -->

Use lowercase snake_case table and column names. Keep domain names aligned with the app vocabulary: inbound receipt, outbound order, stock ledger, warehouse stock.

---

## Common Mistakes

<!-- Database-related mistakes your team has made -->

Do not treat OCR output as confirmed stock. Do not allow negative stock as a temporary state. Do not let a future cloud backup overwrite newer local ledger rows without conflict handling.
