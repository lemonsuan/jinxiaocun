# Android Device Acceptance Protocol

Status: pending. `adb devices -l` returned no connected device when implementation started. Unit tests and release compilation cannot establish shutter response or motion blur.

## Reproducible Comparison

Use the same phone, lens, lighting, document distance and release build mode. Compare previous releases/app-v1.0.4+6.apk against releases/app-v1.0.5+7.apk using a disposable test dataset and backup before changing app versions. Do not uninstall a live app or overwrite live inventory for testing. Never silently downgrade/migrate a real database.

For each build collect at least 20 samples, recording camera-ready, shutter-to-JPEG-saved, saved-to-receipt-committed, and total ready-for-next latency. Compare median, P95, capture failures and text readability. Do not compare a debug build against release. Keep device model, Android version, thermal state and light level with results. Timing logs must not print full tracking numbers or OCR/image contents.

## User-visible Checks

1. Lock tracking A, verify full A at top including a long value that wraps. Capture; no success flash/vibration before saved callback. Move phone immediately after the real completion signal; compare against a hold-still reference. Repeat in daylight and dim warehouse light.
2. Capture 20 distinct tracking numbers; verify full top number, saved receipt and photo match for every sample. Confirm camera stays active between samples, no half-second restart delay.
3. Test torch toggle, persistent torch preference, touch focus, preview-to-crop alignment and portrait orientation with text near all four crop edges. Inspect actual JPEG dimensions and letters at full size. Do not treat a sharper preview as evidence of a sharper saved JPEG.
4. Test cancel/rescan, duplicate tracking, double shutter, permission denied then granted, save failure, native capture failure and slow OCR. Must recover without a stuck spinner or duplicate inventory.
5. During capture switch to background, resume; leave screen while background work runs; force-stop after pending receipt commit and restart. Confirm saved original remains accessible, pending work can recover, and late jobs cannot overwrite deleted/edited receipts.
6. Regress ordinary inbound capture/edit/confirm, history image view, outbound proof photos, backup export/import, receipt edit/delete and stock totals.

## Result Record

Record build SHA/version, device, sample count, per-stage median/P95, failure counts, crop/readability findings and unresolved limitations. True instantaneous exposure is not promised: saved-photo completion is a conservative trusted signal; dim light and motion before completion can still blur an image.
