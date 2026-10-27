# Final Verification — 2026-10-27

## Implemented outcome

The user's revised rule is implemented across Flutter, Django and Vue: additions/updates are incremental; an online phone's ordinary deletion/clear only hides its local display. Other phones/server retain documents, evidence images and shared inventory. Offline workspaces remain independent. Server inventory viewing is read-only; membership administration remains available.

## Automated evidence

- Flutter full suite: **67 passed**, one opt-in live test skipped by default. Existing41 regressions remain passing; new13 SQLite and13 transport tests cover scope/migration, generation ack, retries, conflicts, retained hiding, explicit safe abandonment, media hashes and invalid-photo isolation.
- Live integration against disposable Django on127.0.0.1:18000: **1 passed** after final transport/backend fixes. Random new accounts/shop, join pending403, approval, two independent SQLite phones, upload/download actualPNG, local hide retention, outbound stock10→7, old write405.
- Django PostgreSQL15 isolated test instance: **26 passed**, including actual concurrent same-operation first writes, outbound oversell and stale CAS races. Mixed invalid/valid batch validation, migration retention, authorization and images included.
- Django checks and `makemigrations --check --dry-run`: passed; diff whitespace checks: passed.
- Vue tests3/3, production build including `vue-tsc -b`: passed. Existing dependency PURE annotation and large-bundle warnings remain.
- Browser QA via named isolated agent-browser session: owner login→A stocks7→inbound details/item prices/protected640pxJPEG→products61 pagination/next page/filterSKU-001→switchB shows empty independent stock→logout/loginmember sees A only and no member-management navigation. Browser errors empty; authenticated photo blob verified loaded. Screenshot inspected at `/tmp/shop-sync-detail.png`.
- Targeted Dart analysis of new transport/persistence/login/sync UI/tests: no issues. Full analyzer has zero errors and28 pre-existing issues (one unused helper warning,27 infos); it remains nonzero because of that existing warning. No new analysis finding remains.

## Artifacts

- `releases/app-v1.0.7+9.apk`,60,819,240bytes; SHA256 `4fd2b67acce0cd7fe341f16216fd2ddc6ee3a13fa67543e3f9acf0c5473e815d`.
- Android package `com.xcy.yuntuitui.inventory`, versionName1.0.7/versionCode9, ARM64, minSdk28. Signature verified; existing Android debug certificate retained (SHA2569294e3e62f3816dfa7ccc008a2c080eac3698f84d4271aeaf83b443914e6bab6).
- `releases/web-v0.1.0.zip`,449,860bytes; SHA256 `246713ac9b8fa9507fda6a1eb2a35875ea414df97b510b441e0641ccd0f80ece`.
- Release artifacts are local/ignored, not added to Git. New mobile version requires the updated backend migrations/API; upgrade instructions in `backend/README.md`.

## Explicit limitations / next acceptance

No physical Android device is attached (`adb devices` empty). Two actual phones on the target network, foreground/background/resume behavior and production migration are still to be accepted. No production deployment or live DB access was performed. Test infrastructure/databases are isolated. Prior camera/OCR tasks remain pending physical acceptance; this sync implementation does not claim to validate their camera quality or OCR accuracy.

All planned coding and reproducible integration criteria are satisfied; the acceptance criteria explicitly allow unavailable device/deployment checks to remain marked. Local-only hidden data and server rejection of concurrent offline overselling are intentional. A rejected new local attempt can be explicitly abandoned with retained evidence; ordinary hiding never compensates shared stock.
