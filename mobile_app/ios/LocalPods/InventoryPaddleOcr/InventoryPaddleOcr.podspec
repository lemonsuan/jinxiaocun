Pod::Spec.new do |s|
  s.name = 'InventoryPaddleOcr'
  s.version = '0.1.0'
  s.summary = 'Offline PaddleOCR bridge for inventory table recognition.'
  s.description = 'Local Objective-C++ bridge that runs Paddle Lite OCR and returns editable table draft rows to Flutter.'
  s.homepage = 'https://example.invalid/inventory-paddle-ocr'
  s.license = { :type => 'Apache-2.0' }
  s.author = { 'xcy' => 'local@example.invalid' }
  s.source = { :path => '.' }

  s.ios.deployment_target = '13.0'
  s.static_framework = true
  s.requires_arc = true

  s.source_files = 'Classes/**/*.{h,mm,cc,cpp,hpp}'
  s.public_header_files = 'Classes/InventoryPaddleOcr.h'
  s.resource_bundles = {
    'InventoryPaddleOcrResources' => ['Assets/paddle_ocr/**/*']
  }

  s.vendored_libraries = 'PaddleLite/lib/libpaddle_api_light_bundled.a'
  s.vendored_frameworks = 'OpenCV/opencv2.framework'
  s.libraries = ['c++', 'z']
  s.frameworks = [
    'Accelerate',
    'AssetsLibrary',
    'AVFoundation',
    'CoreGraphics',
    'CoreMedia',
    'CoreVideo',
    'Foundation',
    'QuartzCore',
    'UIKit'
  ]

  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++11',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'HEADER_SEARCH_PATHS' => '"${PODS_TARGET_SRCROOT}/PaddleLite/include" "${PODS_TARGET_SRCROOT}/OpenCV/opencv2.framework/Headers"',
    'OTHER_LDFLAGS' => '$(inherited) -lc++'
  }
end
