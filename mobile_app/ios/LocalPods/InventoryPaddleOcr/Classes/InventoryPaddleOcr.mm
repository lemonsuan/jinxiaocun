#import "InventoryPaddleOcr.h"

#include "paddle_use_kernels.h"
#include "paddle_use_ops.h"
#include "pipeline.h"

#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace {
std::mutex gPipelineMutex;
std::unique_ptr<Pipeline> gPipeline;

NSString *ResourcePath(NSString *name, NSString *type,
                       NSArray<NSString *> *directories) {
  NSBundle *classBundle = [NSBundle bundleForClass:[InventoryPaddleOcr class]];
  NSURL *resourceBundleURL =
      [classBundle URLForResource:@"InventoryPaddleOcrResources"
                     withExtension:@"bundle"];
  if (resourceBundleURL == nil) {
    resourceBundleURL =
        [[NSBundle mainBundle] URLForResource:@"InventoryPaddleOcrResources"
                                withExtension:@"bundle"];
  }
  NSBundle *resourceBundle =
      resourceBundleURL == nil ? [NSBundle mainBundle]
                               : [NSBundle bundleWithURL:resourceBundleURL];
  for (NSString *directory in directories) {
    NSString *path =
        [resourceBundle pathForResource:name ofType:type inDirectory:directory];
    if (path != nil) {
      return path;
    }
  }
  return [resourceBundle pathForResource:name ofType:type];
}

Pipeline *PipelineInstance() {
  std::lock_guard<std::mutex> lock(gPipelineMutex);
  if (gPipeline != nullptr) {
    return gPipeline.get();
  }

  NSString *detPath =
      ResourcePath(@"PP-OCRv5_mobile_det", @"nb",
                   @[ @"models", @"paddle_ocr/models" ]);
  NSString *clsPath = ResourcePath(@"PP-LCNet_x0_25_textline_ori", @"nb",
                                   @[ @"models", @"paddle_ocr/models" ]);
  NSString *recPath =
      ResourcePath(@"PP-OCRv5_mobile_rec", @"nb",
                   @[ @"models", @"paddle_ocr/models" ]);
  NSString *tablePath =
      ResourcePath(@"ch_ppstructure_mobile_v2.0_SLANet", @"nb",
                   @[ @"models", @"paddle_ocr/models" ]);
  NSString *configPath = ResourcePath(@"config", @"txt", @[ @"", @"paddle_ocr" ]);
  NSString *labelPath =
      ResourcePath(@"ppocr_keys_ocrv5", @"txt",
                   @[ @"labels", @"paddle_ocr/labels" ]);
  NSString *tableLabelPath =
      ResourcePath(@"table_structure_dict_ch", @"txt",
                   @[ @"labels", @"paddle_ocr/labels" ]);
  if (detPath == nil || clsPath == nil || recPath == nil ||
      tablePath == nil || configPath == nil || labelPath == nil ||
      tableLabelPath == nil) {
    return nullptr;
  }

  gPipeline.reset(new Pipeline([detPath UTF8String], [clsPath UTF8String],
                               [recPath UTF8String], "LITE_POWER_HIGH", 2,
                               [configPath UTF8String], [labelPath UTF8String],
                               [tablePath UTF8String],
                               [tableLabelPath UTF8String]));
  return gPipeline.get();
}
} // namespace

@implementation InventoryPaddleOcr

+ (NSArray<NSArray<NSString *> *> *)recognizeRowsAtImagePath:
    (NSString *)imagePath {
  if (imagePath.length == 0) {
    return @[];
  }

  Pipeline *pipeline = PipelineInstance();
  if (pipeline == nullptr) {
    return @[];
  }

  std::vector<std::string> nativeRows =
      pipeline->RecognizeRows([imagePath UTF8String]);
  NSMutableArray<NSArray<NSString *> *> *rows =
      [NSMutableArray arrayWithCapacity:nativeRows.size()];
  for (const auto &nativeRow : nativeRows) {
    NSString *row =
        [[NSString alloc] initWithBytes:nativeRow.data()
                                 length:nativeRow.size()
                               encoding:NSUTF8StringEncoding];
    if (row == nil || row.length == 0) {
      continue;
    }
    [rows addObject:[row componentsSeparatedByString:@"\t"]];
  }
  return rows;
}

@end
