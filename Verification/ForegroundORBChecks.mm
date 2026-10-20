#import <Foundation/Foundation.h>
#import "GLOpenCVBridge.h"
#include <opencv2/core.hpp>
#include <opencv2/imgcodecs.hpp>

static NSData *image(int foreground, int background) {
    cv::Mat bgr(512,512,CV_8UC3); cv::RNG bg(background),fg(foreground);
    bg.fill(bgr,cv::RNG::UNIFORM,0,256);
    cv::Mat middle=bgr(cv::Rect(128,128,256,256));fg.fill(middle,cv::RNG::UNIFORM,0,256);
    std::vector<unsigned char> png;cv::imencode(".png",bgr,png);
    return [NSData dataWithBytes:png.data() length:png.size()];
}
int main() { @autoreleasepool {
    NSMutableData *mask=[NSMutableData dataWithLength:512*512];
    auto bytes=(unsigned char *)mask.mutableBytes;
    for(int y=128;y<384;y++)for(int x=128;x<384;x++)bytes[y*512+x]=255;
    NSError *error=nil;
    auto a=[GLOpenCVBridge featuresForPNG:image(13,25) foregroundMask:mask error:&error];
    auto same=[GLOpenCVBridge featuresForPNG:image(13,25) foregroundMask:mask error:&error];
    auto otherBackground=[GLOpenCVBridge featuresForPNG:image(13,77) foregroundMask:mask error:&error];
    auto otherForeground=[GLOpenCVBridge featuresForPNG:image(89,25) foregroundMask:mask error:&error];
    NSMutableDictionary *checks=[NSMutableDictionary new];
    checks[@"same_foreground_positive"]=@([[GLOpenCVBridge compareReference:a query:same][@"vote"] isEqual:@"match"]);
    checks[@"changed_background_same_foreground_positive"]=@([[GLOpenCVBridge compareReference:a query:otherBackground][@"vote"] isEqual:@"match"]);
    checks[@"same_background_different_foreground_negative"]=@(![[GLOpenCVBridge compareReference:a query:otherForeground][@"vote"] isEqual:@"match"]);
    auto zero=[NSMutableData dataWithLength:512*512];
    checks[@"empty_mask_rejected"]=@([GLOpenCVBridge featuresForPNG:image(13,25) foregroundMask:zero error:&error]==nil);
    checks[@"wrong_mask_size_rejected"]=@([GLOpenCVBridge featuresForPNG:image(13,25) foregroundMask:[NSData data] error:&error]==nil);
    checks[@"invalid_png_rejected"]=@([GLOpenCVBridge featuresForPNG:[NSData data] foregroundMask:mask error:&error]==nil);
    checks[@"foreground_features_bounded"]=@([a.metadata[@"keypoints"] intValue]>10 && [a.metadata[@"keypoints"] intValue]<=2000);
    BOOL passed=YES;for(NSNumber *v in checks.allValues)passed=passed&&v.boolValue;
    NSDictionary *report=@{@"checks":checks,@"passed":@(passed),@"cameraStarted":@NO,@"networkRequests":@0,@"syntheticOnly":@YES,@"opencv":GLOpenCVBridge.buildMetadata,@"sameBackgroundNegative":[GLOpenCVBridge compareReference:a query:otherForeground]};
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
    fwrite(json.bytes,1,json.length,stdout);puts("");return passed?0:1;
}}
