# Technical Design

## Cross-layer Boundary

This is one integrated feature spanning mobile, backend and Web, with independently owned implementation areas and one shared wire contract (research/wire-contract.md). Existing OCR/camera code is outside scope. User explicitly authorized autonomous progress after planning; this reviewed-in-chat scope is persisted before activation.

## Backend

Extend existing UUID business models with stable opaque client keys and committed server revisions; do not replace or drop retained business tables. Serialize each whole-document operation under a per-shop revision lock. Track operation ID and payload digest/result for retry idempotence; exact base revision protects against stale writers. Products/inbound/outbound are writable; stock and ledger are server derived. Compute delta from prior/current document items, update stock/ledger transactionally, reject negative accepted stock or duplicate tracking. Keep historical operation snapshots and never accept client delete/full-stock overwrite. Migrate existing records/revisions without deleting old data. Existing inventory Web mutations/unsafe v1 sync are retired clearly; online viewing is read-only.

Private media uses shop+content hash and protected uploads/downloads. Archive bytes are immutable and not garbage-collected by phone clearing. Lists/details are paginated and filterable, including images and legacy retained information. Auth/approved membership applies to every data/media path; constrain parent ownership, role/status enums and creator protection.

## Mobile Persistence and Compatibility

Separate business SQLite files by normalized server+shop, with a global configuration store for active credentials/preferences and a per-install device identity. First migrate the existing SQLite database only into its recorded active scope; keep original file as backup. New shops do not silently inherit local-default inventory. Preserve injected DB tests and all public local business methods.

SQLite triggers mark only affected product/inbound/outbound documents dirty, with generations. Persist frozen operations after media upload, then acknowledge exact generations. Remote changes apply transactionally with triggers suppressed; never lose later local edits. Per-scope cursor is independent of wall clocks. Conflict snapshots stay available and status is visible; explicit server resolution must preserve local evidence and remain transactionally safe. Stock summary application accounts for pending local changes and uses ledger reconciliation; canonical summaries are not pushed back.

Local online deletion is a per-device hidden registry: preserve shared business records/quantities and prevent subsequent pulls from redisplaying them. Offline workspace keeps prior delete semantics. Online bulk clears must follow the same local-only contract and not erase unuploaded media/data. Local hidden markers and sync/device credentials are not transferable backup payloads; restore creates fresh safely versioned pending records and resumes from a reset cursor without deletes.

## Service and UI

Immutable DB scope and generation protect route/server/account/shop switches. Foreground poll/resume/manual sync use one bounded runner, upload private photos before metadata, replay persisted operations first, fetch only changed revisions, hydrate missing media with hash verification, and expose pending/conflict/auth/network status. Background OCR results continue to write their original captured shop DB; they must never be relabeled into a newly selected shop. Replace global processing-queue singleton with scope/connection-aware instances.

Web retains login/shop/member approval management and becomes an authenticated viewer for records, stock, ledger and photos. No inventory mutation controls or public media URLs. API filters/pagination avoid fetching all records; authenticated blob URLs are revoked on changes, and stale responses cannot populate another selected shop.

## Risks and Rollback

Most risky areas are legacy DB ownership, snapshots written while OCR updates, media-before-record ordering, per-device hide state and concurrent offline stock. Back up original data, add explicit schema migrations and test two isolated device DBs. Offline operation may conflict with another device; preserve the rejected local change with visible status, never pretend it was accepted or overwrite remote data blindly. Retained server rows/media are never purged by this feature. No remote production deployment is authorized; code/packaging and local tests are the deliverable.
