#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Serial worker only. Fixed foreground ORB; no camera, network or persistence.
@interface GLOpenCVFeatures : NSObject
@property(nonatomic,readonly) NSDictionary<NSString *,id> *metadata;
@end
@interface GLOpenCVBridge : NSObject
+ (NSDictionary<NSString *,id> *)buildMetadata;
+ (nullable NSDictionary<NSString *,id> *)focusMetricsForGray:(NSData *)gray width:(NSInteger)width height:(NSInteger)height error:(NSError **)error NS_SWIFT_NAME(focusMetrics(gray:width:height:));
+ (nullable GLOpenCVFeatures *)featuresForPNG:(NSData *)png foregroundMask:(NSData *)mask error:(NSError **)error NS_SWIFT_NAME(features(png:mask:));
+ (NSDictionary<NSString *,id> *)compareReference:(GLOpenCVFeatures *)reference query:(GLOpenCVFeatures *)query NS_SWIFT_NAME(compare(_:_:));
@end
NS_ASSUME_NONNULL_END
