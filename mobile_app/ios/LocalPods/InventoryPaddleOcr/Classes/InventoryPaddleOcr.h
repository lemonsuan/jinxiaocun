#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface InventoryPaddleOcr : NSObject

+ (NSArray<NSArray<NSString *> *> *)recognizeRowsAtImagePath:(NSString *)imagePath;

@end

NS_ASSUME_NONNULL_END
