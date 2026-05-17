import Flutter
import InventoryPaddleOcr
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller = window?.rootViewController as? FlutterViewController
    let scannerChannel = FlutterMethodChannel(
      name: "inventory_app/scanner",
      binaryMessenger: controller!.binaryMessenger
    )
    scannerChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "scanTrackingNumber":
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let ocrChannel = FlutterMethodChannel(
      name: "inventory_app/paddle_ocr",
      binaryMessenger: controller!.binaryMessenger
    )
    ocrChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "recognizeTable":
        guard let arguments = call.arguments as? [String: Any],
          let imagePath = arguments["imagePath"] as? String
        else {
          result(
            FlutterError(
              code: "INVALID_ARGUMENT",
              message: "imagePath is required",
              details: nil
            )
          )
          return
        }

        DispatchQueue.global(qos: .userInitiated).async {
          let rows = InventoryPaddleOcr.recognizeRows(atImagePath: imagePath)
          DispatchQueue.main.async {
            result(["rows": rows])
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
