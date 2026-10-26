# Camera Evidence

Read-only inspection on 2026-10-26, no device measurements yet.

- CustomCameraPage lines 223–238: visual/haptic trigger precedes takePicture completion. Lines 248–253 and 327–330: two full reads/decodes. Lines 341–346: raster crop, PNG encoding, flush before navigation.
- ExpressInboundPage lines 272–282: stop mobile_scanner, push a new CustomCameraPage. Lines 308–327: copy image, commit pending receipt, launch unawaited OCR, refresh parent. Lines 348–351: fixed 500ms delay then restart scanner.
- AppHome._refreshData reads full inventory/inbound/outbound; database loadInboundHistory performs one detail query per receipt.
- Locked camera_android_camerax 0.7.2 source, android/src/main/java/io/flutter/plugins/camerax/ImageCaptureProxyApi.java: success comes from ImageCapture.OnImageSavedCallback.onImageSaved; no exposure-complete callback is exposed by the existing Dart takePicture API. Its builder does not configure captureMode explicitly.
- Locked mobile_scanner 7.2.0 android/build.gradle: CameraX lifecycle/camera2 1.5.3 and bundled ML Kit barcode 17.3.0; lib/src/mobile_scanner_controller.dart has returnImage for analysis frames but no formal still-photo API.
- These are observations of locally installed locked dependency sources, not claims about latest upstream releases. Native stream compatibility, actual blur causes and latency distribution remain device verification items.

- Implementation-time dependency resolution: installed camera_android_camerax 0.7.2 uses CameraX 1.6.0, while mobile_scanner declares 1.5.3. Gradle resolves 1.6.0; app-local dependencies align with that resolved version, not only the scanner declaration. Guava API is explicit where required for ListenableFuture visibility.
