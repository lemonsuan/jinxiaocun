# Canonical Sync v2 / Read-only View Contract

## Identity and Storage

All calls except auth require Bearer token and X-Active-Shop-ID approved membership. Client IDs are opaque strings (max200), preserving existing phone IDs. Backend keeps existing UUID business PKs and adds stable client_key mapping + server revision; products/stocks use product code as client id. No cross-shop parent IDs accepted. Backend uses per-shop monotonic revision (lock shop/state row), whole-document transactions and persistent operation receipts. Existing business rows migrate to client keys based on their UUID; retained historical tables are not dropped.

Writable document kinds: `product`, `inbound`, `outbound`. Read-only pull kind: `stock`. No delete kind/operation. New v2 API must reject deletion flags, client inventory/ledger replacement and attempts to manipulate server revisions.

Data payloads:
- product: `{code,name,default_purchase_price?,default_sale_price?,created_at?,updated_at?}`.
- inbound: `{tracking_number,seller_order_number?,rebate_order_number?,scheme_number?,created_at,ocr_status,is_settled,image_sha256?,items:[{id,product_code,product_name,quantity,purchase_price?,sale_price?}]}`.
- outbound: `{created_at,logistics_number?,note?,image_sha256s:[digest],items:[{id,product_code,product_name,quantity}]}`.
- stock: `{product_code,product_name,quantity}`; server derived/read-only, never uploaded.
`record` = `{kind,id,revision,data}`. All timestamps ISO8601 with timezone (accept legacy client naive timestamps explicitly normalized, never trust them as sync clocks). Prices optional nonnegative, quantity positive integer; bounded lengths/items/request sizes. Digests64lowercasehex. Root documents include all their live items, atomically; line removals on a real edit must retain server audit history rather than hard-delete historical evidence.

## HTTP API

- `POST /api/sync/v2/push`: `{device_id,operations:[{operation_id,kind,id,base_revision,data}]}`.
  Response `{results:[{operation_id,status,revision,record?,code?,message?}],server_revision}`. status is `applied`, `duplicate` or `conflict`; malformed payload may400/422 with message. Results are per-operation atomic, in supplied order (products then inbounds then outbounds). Duplicate operation IDs must return original outcome; same ID with different payload rejected. base_revision0 creates; existing record update requires exact revision. Identical data with fresh op/base0 may acknowledge existing record. Conflicts include current record when available, preserve local outbox snapshot and do not silently overwrite it. Unique shop/tracking conflicts are explicit.
- `GET /api/sync/v2/pull?cursor=0&limit=100`: `{changes:[record],cursor,has_more,server_revision}` ordered by committed shop revision. Use captured upper bound; cursor never advances past unseen committed records. Readonly stock records participate in revision ordering. No client deletion propagation/tombstones.
- `POST /api/sync/v2/media`: multipart `file`, optional claimed sha256; response `{sha256,size,content_type}`. Validate actual image, size (default15MiB) and hash; private shop-scoped immutable content-addressed storage, idempotent deduplication.
- `GET /api/sync/v2/media/{sha256}`: protected binary, correct MIME; membership checked every read. No public static URL/query-token bypass.
- `GET /api/sync/v2/media/{sha256}/exists`: `{exists:true,sha256,size,content_type}` or404.
- `GET /api/view/{collection}` where collection=`products|inbound|outbound|stocks|ledger|logs`: `{items,total,page,page_size}`. Params page>=1,page_size<=100,q?,date_from?,date_to?,is_settled?,include_archived? (legacy archived rows may be separately visible).
  For product/inbound/outbound items return `record` shape. Stocks return `{product_code,product_name,quantity}`; ledger `{id,product_code,product_name,delta,reason,source_id,created_at}`; logs `{id,username,action_type,tracking_number,detail,created_at}`. Detail endpoints `GET /api/view/inbound/{id}` and `/outbound/{id}` return record. No mutation endpoints under view.
Existing auth and shops endpoints stay compatible. Existing unsafe `/api/sync/push` must fail clearly as retired protocol, not execute old arbitrary writes. Inventory Web mutation routes must return a clear read-only/retention error. Django inventory admin must not silently bypass new retained sync writers.

## Mobile DB API (owned by mobile_data)

Preserve LocalInventoryDatabase callers/injected SQLite tests. Add per-server+shop DB separation and global config/migration; immutable opened scope, never derive outgoing shop from newly changed global selection. New sync state tables contain dirty generations, last accepted record revisions/snapshots, persistent frozen operations, cursor, local-only hidden records, media mapping and conflict snapshots. Trigger local business writes into dirty documents; remote application suppresses triggers.

Required async methods (Map<String,Object?> payloads are canonical here):
- `loadSyncContext()` -> `{server_url,token,shop_id,device_id}` ornull for offline/scope mismatch.
- `pendingSyncRecords({int limit=50})` -> candidates `{kind,id,generation,base_revision,data}`. Candidate inbound data temporarily has local `image_path`, outbound `image_paths` (local paths or `sync://<digest>`). Root SyncService replaces them with canonical digest fields before freezing.
- `freezeSyncOperation(Map candidate, Map wireData)` -> immutable operation wire object persisted with captured generation.
- `pendingSyncOperations({int limit=50})` -> existing frozen wire operations to retry first.
- `applySyncPushResults(List<Map> results)` -> acknowledge only matching generation; keep later edits dirty. Store conflicts without dropping local data; don't repeatedly auto-upload a blocked generation.
- `loadSyncCursor()` -> int; `applySyncPull(List<Map> changes,int cursor)` -> transaction. Respect local hidden state; do not overwrite dirty/conflicting local records. Validate all incoming IDs/parents/types. Preserve pending-local stock projection and reconcile canonical stock summaries with an adjustment ledger, rather than upload whole local stock.
- `pendingSyncMediaDownloads({int limit=20})` -> `{kind,id,index,sha256}` excluding locally hidden records.
- `attachSyncMedia(Map reference,String localPath)` -> guarded local image hydration without making record dirty. Preserve existing image when digest matches.
- `syncConflictCount()` -> int; `loadSyncConflicts()` -> retained entries with local/current data and message. `acceptServerSyncConflict(String operationId)` explicitly resolves to the retained server record, preserving local snapshot in conflict archive; on unsafe dependent-stock resolution fail clearly rather than lose data.
- `restoreLocallyHiddenRecords()` -> clear local visibility markers (no server write).
- `syncMediaDigest(String path,int size,int modifiedMicros)` -> cached digest ornull; `rememberSyncMedia(String path,int size,int modifiedMicros,String digest)`.

Online delete/clear APIs keep shared business quantities and only hide local views; make labels explicit in UI. Hidden data must not reappear on pull. Offline default workspace keeps prior delete/stock semantics. Original local database is preserved during first migration; new shop must not inherit arbitrary offline data. Exclude credentials/device IDs/cursors/frozen ops/hidden state from export/import; reconstruct dirty state safely for restored business data. Restore must not send delete operations or override newer server versions.

## Mobile Service/UI (owned by parent)

Application SyncService uses injected http.Client; foreground poll (about15s), sync on resume/manual request; one running cycle, bounded pages/backlog, timeout/retry with visible status. Send persisted frozen ops before new candidates. Upload images before freezing record operations, verify downloads by SHA256, write durable app-private files and attach guarded references. No full table overwrite and no deletion payload. Pause service on route/account/shop change; old scope cannot modify new workspace. Preserve local data on auth/membership error and surface re-login/permission status.

UI: join-shop/refresh approval in LoginPage; AppHome sync status and management page (manualsync, pending/conflict details, explicit use-server resolution, restore local hidden display). Online deletion wording is local-only and does not reverse shared stock. Web is a read-only viewer with member management, protected images as authenticated blob URLs and stale-request guards when switching shops.

## Reviewed Compatibility Rules

OCR status accepts pending/processing/needsReview/confirmed/failed, matching mobile enum. Push validates each operation independently: invalid business fields return a persistent invalid_data conflict and do not block valid operations in the same batch. No price rounding or silent field truncation. API envelope remains bounded.

Explicit conflict handling supports adopting a retained server version and abandoning only a clearly rejected, never-accepted new local attempt. Abandonment archives local evidence, removes its pending stock projection and never sends a delete. Requests of unknown outcome and accepted server documents cannot use this path.
