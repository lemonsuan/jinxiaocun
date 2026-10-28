# Shared Shop Incremental Sync

## 1. Scope / Trigger

Applies to `backend/`, Flutter online workspaces and the Vue read-only viewer. User decision on 2026-10-27: deleting on one phone must not delete on any other phone or on the server. Adds and edits synchronize incrementally. Offline workspaces keep their existing local inventory behavior.

## 2. Signatures

- `POST /api/sync/v2/push`: `{device_id,operations:[{operation_id,kind,id,base_revision,data}]}` → `{results,server_revision}`. Writable kinds: product/inbound/outbound; item arrays belong to atomic whole documents.
- `GET /api/sync/v2/pull?cursor=N&limit=100` → `{changes:[{kind,id,revision,data}],cursor,has_more,server_revision}`. Stock is a read-only change kind.
- `POST /api/sync/v2/media`: multipart file and optional sha256. Protected GET `/api/sync/v2/media/{sha256}` and `/exists`.
- `GET /api/view/{products|inbound|outbound|stocks|ledger|logs}` with page/page_size/q/date_from/date_to/is_settled/include_archived. Inbound/outbound have document detail GET routes.
- Mobile persistence: `freezeSyncOperation`, `applySyncPushResults`, `applySyncPull`, `acceptServerSyncConflict`, `abandonUnacceptedSyncConflict`, `restoreLocallyHiddenRecords` in `local_inventory_sync.dart`.
- Retained Django tables keep UUID primary keys and add opaque client keys; `ShopSyncState`, `SyncChange`, `SyncOperation`, `PrivateMedia` persist revisions, immutable snapshots, outcomes and image ownership.

## 3. Contracts

Every sync/view/media request requires Bearer authentication and approved `X-Active-Shop-ID` membership. Shop row locking serializes committed revisions and stock changes. Operation IDs are durable: same payload retries do not repeat movement; reuse with different payload is rejected. Updates require exact base revisions. Apply each operation atomically and validate each business payload separately; a bad historical price/name must not block a valid neighboring operation.

Never accept client stock/ledger replacement, deletion markers or arbitrary server revision changes. Never hard-delete historical server evidence when editing item lists. Migrations retain old UUIDs, archive flags, paths and stock quantities; add an explicit opening adjustment if existing stock differs from ledger totals. Never recompute historical balances from old receipts during migration.

Each phone stores a DB per normalized server URL + shop and a separate global config DB. URL normalization trims whitespace and trailing slashes only. Opened scope is immutable; check the active scope/token after asynchronous requests before applying results. Original `inventory_app.db` remains intact; migration copies through a staged current-schema SQLite snapshot and atomic rename, compatible with older Android SQLite. Online backup restore fails clearly; restore into an independent offline workspace instead. Backups must not transfer auth/device identity, cursors, operations, hidden markers or conflict state.

Dirty generation acknowledgement clears only that exact generation. Frozen operations survive crashes. Pull commits records and cursor in one transaction, suppressing local-write triggers, retaining dirty versions and local visibility masks. Local hidden documents/images still upload; hide never changes shared quantities. Stock combines server summaries plus pending document deltas with explicit local adjustment ledger entries.

Pictures use shop-scoped private SHA256 storage, actual image validation and 15MiB bounds. Upload images before freezing metadata. Downloads are streamed, hash-verified, atomically renamed and attached without dirtying documents. Do not expose raw sandbox paths as web URLs or public media links. Legacy server images require explicit allowed-root import; mobile sandbox files must upload from the phone.

Foreground service runs one bounded cycle, approximately every15seconds and on resume/manual request. Pause and drain transport before explicit local conflict resolution. Dispose timers/listeners on leaving a workspace; verify mounted before registering them after initialization awaits. Web requests/blob URLs reject stale session generations, including A→B→A switches.

## 4. Validation & Error Matrix

- 401/403 → retain local data/outbox, explain login or membership failure.
- CAS/tracking/stock/invalid_data conflict → retain local snapshot, block only its generation, expose resolution. Do not round invalid prices.
- Lost response → replay the same frozen operation ID; never generate a fresh ID for unknown outcome.
- Malformed pull/cursor → roll back data and cursor together.
- Adopt server → explicit confirmation, retain local conflict evidence; reject unsafe dependent stock changes.
- Abandon new attempt → only explicit server rejection, base0, no accepted revision/remote document; archive evidence, remove pending projection, refuse dependent negative stock. Never use ordinary hide as compensation.
- Legacy sync push →410. Inventory write/delete routes →405. Business Django admin is read-only.

## 5. Good / Base / Bad Cases

Good: A uploads an inbound/photo, B receives it; A hides it and B/server remain unchanged. B outbound updates shared stock seen by A.

Base: no network leaves local work and images durable; the next foreground cycle retries.

Bad: propagating a tombstone, replacing a whole shop from one phone, trusting a foreign parent UUID, advancing an unseen cursor, applying another shop's late HTTP response, or opening a public photo URL.

## 6. Tests Required

`shop_sync_database_test.dart` covers two databases, scope isolation, migration, hide/no resurrection, generation ack, conflict archives, stock projection, backups and transactional malformed pull. `shop_sync_service_test.dart` covers restart retries, 401, scope changes and image verification. `shop_sync_live_test.dart` is opt-in with `--dart-define=SHOP_SYNC_TEST_URL=http://127.0.0.1:18000`; it must use disposable accounts/shops.

Django tests use isolated SQLite or `postgres_test_settings`, never the live DB. PostgreSQL concurrency tests assert exactly-once first writes, no oversell and one winning stale-CAS update. Test mixed invalid/valid operations, migration retention and cross-shop image denial. Frontend `npm test` checks auth reset and stale session rejection; `npm run build` includes TS checking. Browser QA verifies paginated filtered lists, detail pictures, read-only roles and shop switching.

## 7. Wrong vs Correct

Wrong: deleting a receipt sends a server delete and subtracts shared stock.

Correct: online delete adds a local visibility mask; shared retained records and quantities stay unchanged.

Wrong: recreate an operation after timeout or overwrite a dirty local receipt on pull.

Correct: retry the immutable persisted operation and preserve later local generations until explicitly reconciled.

## Reviewed Media Failure Isolation

A missing/corrupt legacy local image must not stall every following record. Service scans a bounded100 candidates and freezes at most30 valid documents per cycle; file/format failures keep the affected document dirty and show an incomplete-media status while other candidates continue. Auth/network failures still stop the cycle. Never omit the evidence field to force success. Pending/conflicting counts must prevent a false all-complete status.

## 作业管理写入与撤权的并发边界

作业、结算、撤销结算和拍手管理写入统一先锁店铺，再锁定当前管理员的成员记录并复验 `APPROVED` 与 `CREATOR/ADMIN`。不能只沿用进入请求时的权限结果：请求等待店铺锁期间，创建人可能已经撤销该管理员资格。成员锁持续到写入事务提交，确保撤权与业务写入按实际锁顺序生效。回归用例须覆盖初次鉴权通过、取得店铺锁前资格被撤销的情况；库存并发测试应显式使用管理员角色，不依赖成员默认角色。
