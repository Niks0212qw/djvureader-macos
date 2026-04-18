#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DJVULibreRenderer : NSObject

@property (nonatomic, readonly) NSInteger pageCount;
@property (nonatomic, readonly) NSDictionary<NSNumber *, NSNumber *> *pageAspectRatios;

- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error;
- (CGSize)pageSizeAtIndex:(NSInteger)pageIndex;
- (nullable NSImage *)renderPageAtIndex:(NSInteger)pageIndex
                              pixelSize:(CGSize)pixelSize
                              isPreview:(BOOL)isPreview
                                  error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
