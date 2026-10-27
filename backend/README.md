# Retained shop sync server

Business inventory writes use `POST /api/sync/v2/push` with stable opaque client IDs, operation IDs and exact base revisions. `GET /api/sync/v2/pull` pages immutable shop revisions. Product/inbound/outbound documents are writable; stock and ledger are derived. Each operation commits atomically under a shop row lock on PostgreSQL. No deletion operations exist. Push validates the bounded request envelope first, then validates each operation independently: invalid legacy names/codes/prices return durable `conflict` / `invalid_data` results while valid operations in the same batch continue. Prices exceeding two decimal places are rejected explicitly, never silently rounded. Reusing any operation ID with a changed payload still returns `operation_id_reused`. Legacy sync returns410; old inventory writes return405. Inventory admin and shop business inlines are read-only.

Authenticated `/api/view/{products|inbound|outbound|stocks|ledger|logs}` lists return `{items,total,page,page_size}`. Inbound/outbound details use their opaque client IDs. Every data/image request requires Bearer auth and `X-Active-Shop-ID` with approved membership. Optional OCR states are `pending`, `processing`, `needsReview`, `confirmed`, `failed`.

Private media uploads accept multipart `file` plus optional `sha256`, validate image contents and limits (15 MiB,40MP), and return `{sha256,size,content_type}`. Protected download/exists routes are `/api/sync/v2/media/{sha256}` and `/{sha256}/exists`. Bytes are never exposed by public static routes or deleted by phone cache clearing. Include the private media directory in server backups together with the database.

Existing UUID rows and archived evidence remain intact. Migration seeds client mappings and immutable snapshots without replaying historical documents. Existing warehouse balances remain the opening stock; explicit `sync-v2-opening-balance` adjustment ledger rows reconcile differences from old ledger totals. Legacy image-path strings are retained. Import accessible legacy files only from an explicit trusted root:

```sh
python manage.py import_legacy_media --shop <shop-uuid> --source-root /trusted/legacy/photos
# Review candidate count, then import:
python manage.py import_legacy_media --shop <shop-uuid> --source-root /trusted/legacy/photos --apply
```

Paths outside that root (including resolved symlinks) and missing/invalid images are skipped. Smartphone sandbox paths unavailable on the server require the phone to upload the evidence; they cannot be reconstructed from a path string.

## Isolated verification

From `backend/`, using an environment with `requirements.txt` installed:

```sh
python manage.py test inventory shops --settings=shop_sync_backend.test_settings
python manage.py makemigrations --check --dry-run --settings=shop_sync_backend.test_settings
```

The SQLite test settings never connect to the configured server database. Actual lock/concurrency tests require a disposable PostgreSQL instance:

```sh
docker run --name shop-sync-disposable-pg -e POSTGRES_DB=shop_sync_isolated -e POSTGRES_USER=sync_test -e POSTGRES_PASSWORD=isolated-tests-only -p 127.0.0.1:25439:5432 -d postgres:15-alpine
python manage.py test inventory shops --settings=shop_sync_backend.postgres_test_settings
# Stop/remove only this disposable container after verification.
```

For local browser QA only (SQLite does not verify PostgreSQL row-lock behavior):

```sh
export SHOP_SYNC_TEST_DB=/tmp/shop-sync-browser.sqlite3
export SHOP_SYNC_TEST_MEDIA=/tmp/shop-sync-browser-media
python manage.py migrate --settings=shop_sync_backend.test_settings
python manage.py runserver 127.0.0.1:18000 --settings=shop_sync_backend.test_settings --noreload
```

Production uses PostgreSQL and the existing deployment settings; no production migration/deployment is performed by these test commands. Read conflicts explicitly and retain rejected local snapshots instead of overwriting server stock or replaying deletes.

## Coordinated upgrade

Deploy the new backend code/dependencies and run `python manage.py migrate` against the intended PostgreSQL database before using mobile `1.0.7+9` and viewer `0.1.0`. Back up the database and private media together. Configure `PRIVATE_MEDIA_ROOT` on persistent storage; do not serve it as public static media. Publish `frontend/dist` with same-origin `/api` proxying to Django. The mobile server field is the server origin (or configured base path) without a trailing `/api`; physical phones require a reachable LAN/HTTPS address rather than emulator `10.0.2.2`.

The mobile service polls in the foreground about every15seconds and on resume/manual request. Online delete/clear only hides this device's display, preserving server documents, images and shared stock. Offline phones may accumulate pending work; server stock validation and conflict resolution determine which concurrent changes are accepted. Do not interpret an offline local confirmation as a guarantee that competing devices cannot consume the same stock.

`ShopSyncService` keeps malformed/missing local photos pending while continuing other valid records; it never strips missing photo evidence to make a record appear successfully uploaded. The sync page displays pending/conflicting records. Explicitly abandoning a rejected, never-accepted new local document is separate from ordinary local hide, retains evidence and changes no server data. Online backup restoration is blocked; restore to the independent offline workspace instead.
