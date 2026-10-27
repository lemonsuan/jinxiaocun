# Implementation Plan

## Authorization and Scope

User confirmed task creation/planning and explicitly said 自行推进. New deletion rule supersedes original request. Plan is persisted and may proceed without another permission prompt. Existing OCR/camera tasks remain separate and pending device acceptance.

## Ordered Work

1. Freeze shared wire contract and change boundary; load applicable frontend/backend specs, explicitly migrate backup-only/single-device assumptions for online shared shops.
2. Parallel ownership: backend agent owns backend models/migrations/auth/sync/media/read endpoints/tests; mobile-data agent owns database/schema/sync domain/persistence tests; Web agent owns frontend viewer/types/browser-ready UI. Parent owns mobile SyncService/Login/Home/management UI, integration tests, docs/specs, release and commits. No overlapping edits without coordination.
3. Backend: retention-safe operation protocol/revisions/media, existing data migration, scoped query/role validation, no arbitrary stock replacement or hard-delete route. Add backend isolated test settings and repeatable unit/integration tests; avoid touching live data.
4. Mobile DB: scoped files/global config and legacy migration; dirty triggers/frozen outbox/generation ack/cursor/conflicts/local hidden state/media refs; online local-delete semantics and backup safety. Preserve all baseline41tests and add real SQLite two-device tests.
5. Parent service/UI: authenticated sync/media transport, bounded foreground runner, visible status/manual sync/conflicts, approval/join and safe selection changes, local-only delete labels, network permission for configured server. Test transport failures and stale scope.
6. Web: authenticated read-only paginated/filterable lists/details/stock/ledger/photos plus existing shop/member workflow; build/type checks, browser test against isolated backend.
7. Integrate backend/API and two independent mobile caches; test A create/edit ->B, A hide does not delete B/server and does not reappear on A, retry after restart, media, negative-stock/duplicate/conflict handling, cross-shop denial and offline mode.
8. Dispatch Trellis check review, fix in-scope findings, update actual contracts/specs. Run backend tests, Flutter formatting/analyzer/tests, frontend type/build and browser flow. Build versioned AndroidAPK and frontend artifact to root releases/ according to project version rules.
9. Automatic local commits of task-owned changes only; preserve unrelated Trellis infrastructure edits. Journal results and remaining physical device/production deployment limitations. Do not mark complete if required integration validation is missing.
