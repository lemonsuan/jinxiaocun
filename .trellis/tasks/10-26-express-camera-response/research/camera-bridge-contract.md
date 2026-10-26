# Continuous Express Camera Bridge Contract

PlatformView type: `inventory_app/express_camera`. Each view owns MethodChannel `inventory_app/express_camera/<viewId>`. Creation params: `outputDirectory` (absolute app documents inbound_images path), `torchEnabled` (bool).

Flutter -> native:
- `capture`: {captureId: String, trackingNumber: String, crop: {left: double, top: double, right: double, bottom: double}} normalized preview coordinates. Only allowed for current locked tracking; result acknowledges request, completion is event.
- `reset`: unlock current tracking after cancel or successful pending receipt commit. Cannot discard an in-flight capture.
- `setTorch`: {enabled: bool}.
- `focus`: {x: double,y: double} normalized preview coordinates.
- `pause`, `resume`, `dispose`: resource lifecycle; dispose completes after unbind.

Native -> Flutter MethodChannel invocations:
- `onReady`: {}.
- `onTracking`: {trackingNumber: String}. Native locks analysis until reset.
- `onCaptured`: {captureId: String, trackingNumber: String, imagePath: String, shutterToSavedMs: int, crop: {left,top,right,bottom}}. File is a durable JPEG, closed before event. Crop is mapped to saved image normalized coordinates using actual PreviewView output transform/ViewPort; if mapping unavailable return full frame coordinates, never guessed destructive crop. JPEG orientation is handled during crop decode. Event is the first allowed success feedback. Native stays locked until reset.
- `onError`: {code: String,message: String,captureId: String?}. No success on failure. Capture remains retryable with same tracking; fatal init/permission error surfaced to Flutter.

No full tracking numbers/image contents in performance logs. Resolution target: >= existing high preset (roughly 1280x720), prefer 1920x1080 when feasible; validate actual output and never substitute preview frame. Use CAPTURE_MODE_MINIMIZE_LATENCY without claiming zero shutter lag or zero blur. Capture files named with unique captureId. No native inventory logic. Explicit app-local dependencies align CameraX 1.6.0 and bundled ML Kit barcode 17.3.0. Flutter UI keeps full tracking header, focus, torch, shutter; native owns preview and analyzer.
