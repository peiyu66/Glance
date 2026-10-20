#if !__has_feature(objc_arc)
#error "GLOpenCVBridge requires ARC for metadata lifetime safety."
#endif
#import "GLOpenCVBridge.h"
#include <opencv2/core.hpp>
#include <opencv2/core/ocl.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/features2d.hpp>
#include <opencv2/geometry.hpp>
#include <chrono>
#include <set>
#include <algorithm>
#include <cmath>
using Clock=std::chrono::steady_clock;
static double milliseconds(Clock::time_point t) { return std::chrono::duration<double,std::milli>(Clock::now()-t).count(); }
@interface GLOpenCVFeatures () { @public cv::Mat descriptors; std::vector<cv::KeyPoint> keypoints; NSString *kind; NSDictionary *_metadata; }
@end
@implementation GLOpenCVFeatures
- (NSDictionary *)metadata {return _metadata;}
@end
@implementation GLOpenCVBridge
+ (NSDictionary *)buildMetadata {return @{@"opencvVersion":@(CV_VERSION),@"threads":@1,@"openCL":@NO,@"settingsVersion":@"foreground-fixed-20261011-v1"};}
+ (NSDictionary *)focusMetricsForGray:(NSData *)bytes width:(NSInteger)width height:(NSInteger)height error:(NSError **)error {
    try {
        if(width<16 || height<16 || width>256 || height>256 || bytes.length!=(NSUInteger)(width*height))throw std::runtime_error("invalid focus ROI");
        auto started=Clock::now();cv::setNumThreads(1);cv::ocl::setUseOpenCL(false);
        cv::Mat raw((int)height,(int)width,CV_8U,const_cast<void *>(bytes.bytes)),gray,smooth,gx,gy,lap;
        raw.convertTo(gray,CV_64F,1.0/255.0);
        cv::GaussianBlur(gray,smooth,cv::Size(3,3),0.8,0.8,cv::BORDER_REFLECT_101);
        cv::Sobel(smooth,gx,CV_64F,1,0,3,1,0,cv::BORDER_REFLECT_101);
        cv::Sobel(smooth,gy,CV_64F,0,1,3,1,0,cv::BORDER_REFLECT_101);
        cv::Laplacian(smooth,lap,CV_64F,1,1,0,cv::BORDER_REFLECT_101);
        cv::Scalar mean,stddev,lapMean,lapDeviation;cv::meanStdDev(smooth,mean,stddev);cv::meanStdDev(lap,lapMean,lapDeviation);
        double energy=cv::mean(gx.mul(gx)+gy.mul(gy))[0];
        return @{@"mean":@(mean[0]),@"variance":@(stddev[0]*stddev[0]),@"tenengrad":@(energy),@"laplacianVariance":@(lapDeviation[0]*lapDeviation[0]),@"milliseconds":@(milliseconds(started))};
    } catch(const std::exception &e) {if(error)*error=[NSError errorWithDomain:@"Glance.OpenCV.Focus" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Focus metric unavailable"}];return nil;}
}
+ (GLOpenCVFeatures *)featuresForPNG:(NSData *)png foregroundMask:(NSData *)foregroundMask error:(NSError **)error {
    try {
        const unsigned char sig[]={137,80,78,71,13,10,26,10};
        if(png.length<8 || png.length>6*1024*1024 || memcmp(png.bytes,sig,8)!=0)throw std::runtime_error("invalid PNG");
        cv::setNumThreads(1);cv::ocl::setUseOpenCL(false);
        auto decodeStart=Clock::now();cv::Mat encoded(1,(int)png.length,CV_8U,const_cast<void *>(png.bytes));cv::Mat bgr=cv::imdecode(encoded,cv::IMREAD_COLOR);
        if(bgr.empty() || bgr.cols>768 || bgr.rows>768 || bgr.cols<32 || bgr.rows<32)throw std::runtime_error("invalid dimensions");
        double decodeMS=milliseconds(decodeStart);auto featureStart=Clock::now();cv::Mat gray;cv::cvtColor(bgr,gray,cv::COLOR_BGR2GRAY);
        if(foregroundMask.length != gray.total())throw std::runtime_error("invalid foreground mask dimensions");
        auto maskBytes=static_cast<const unsigned char *>(foregroundMask.bytes);
        if(std::none_of(maskBytes,maskBytes+foregroundMask.length,[](unsigned char x){return x>=128;}))throw std::runtime_error("empty foreground mask");
        GLOpenCVFeatures *f=[GLOpenCVFeatures new];f->kind=@"ORB";
        std::vector<cv::KeyPoint> allKeypoints;cv::Mat allDescriptors;
        // Frozen research order: detect on original grayscale, THEN filter points.
        cv::ORB::create(2000)->detectAndCompute(gray,cv::noArray(),allKeypoints,allDescriptors);
        for(size_t i=0;i<allKeypoints.size();++i){
            auto pt=allKeypoints[i].pt;
            int x=std::clamp((int)std::floor(pt.x+.5),0,gray.cols-1);
            int y=std::clamp((int)std::floor(pt.y+.5),0,gray.rows-1);
            if(maskBytes[y*gray.cols+x]>=128){f->keypoints.push_back(allKeypoints[i]);f->descriptors.push_back(allDescriptors.row((int)i));}
        }
        double featureMS=milliseconds(featureStart);
        f->_metadata=@{@"algorithm":@"ORB",@"width":@(bgr.cols),@"height":@(bgr.rows),@"keypoints":@(f->keypoints.size()),@"decodeMS":@(decodeMS),@"featureMS":@(featureMS)};return f;
    } catch(const std::exception &e) {if(error)*error=[NSError errorWithDomain:@"Glance.OpenCV" code:1 userInfo:@{NSLocalizedDescriptionKey:@(e.what())}];return nil;}
}
+ (NSDictionary *)compareReference:(GLOpenCVFeatures *)a query:(GLOpenCVFeatures *)b {
    auto start=Clock::now();NSMutableDictionary *r=[@{@"mutual":@0,@"ratio_forward":@0,@"inliers":@0,@"inlier_ratio":@0,@"reference_coverage":@0,@"query_coverage":@0,@"median_reprojection_px":[NSNull null],@"vote":@"reject",@"reason":@"insufficient_correspondence"} mutableCopy];
    try {
        if(![a->kind isEqual:b->kind])throw std::runtime_error("algorithm mismatch");
        if(a->descriptors.empty() || b->descriptors.empty()) {r[@"vote"]=@"uncertain";r[@"reason"]=@"no_descriptor";}
        else if(a->descriptors.rows>=2 && b->descriptors.rows>=2) {
            cv::BFMatcher matcher(cv::NORM_HAMMING);
            std::vector<std::vector<cv::DMatch>> fw,bk;matcher.knnMatch(a->descriptors,b->descriptors,fw,2);matcher.knnMatch(b->descriptors,a->descriptors,bk,2);
            std::set<std::pair<int,int>> reverse;for(auto &v:bk)if(v.size()==2 && v[0].distance<0.7*v[1].distance)reverse.insert({v[0].trainIdx,v[0].queryIdx});
            int forward=0;std::vector<cv::Point2f> x,y;
            for(auto &v:fw)if(v.size()==2 && v[0].distance<0.7*v[1].distance){forward++;auto &m=v[0];if(reverse.count({m.queryIdx,m.trainIdx})){x.push_back(a->keypoints[m.queryIdx].pt);y.push_back(b->keypoints[m.trainIdx].pt);}}
            r[@"ratio_forward"]=@(forward);r[@"mutual"]=@(x.size());
            if(x.size()>=4) {
                cv::setRNGSeed(20261011);cv::Mat mask;cv::Mat H=cv::findHomography(x,y,cv::RANSAC,5.0,mask,2000,.995);
                if(H.empty() || !cv::checkRange(H)){r[@"vote"]=@"uncertain";r[@"reason"]=@"homography_failed";}
                else {
                    std::vector<cv::Point2f> xi,yi,projected;cv::perspectiveTransform(x,projected,H);std::vector<double> errors;
                    for(size_t i=0;i<x.size();++i)if(mask.at<unsigned char>((int)i)){xi.push_back(x[i]);yi.push_back(y[i]);errors.push_back(cv::norm(projected[i]-y[i]));}
                    double ratio=(double)xi.size()/x.size(),cx=0,cy=0;r[@"inliers"]=@(xi.size());r[@"inlier_ratio"]=@(ratio);
                    if(xi.size()>=3){std::vector<cv::Point2f> hx,hy;cv::convexHull(xi,hx);cv::convexHull(yi,hy);cx=cv::contourArea(hx)/([a.metadata[@"width"] doubleValue]*[a.metadata[@"height"] doubleValue]);cy=cv::contourArea(hy)/([b.metadata[@"width"] doubleValue]*[b.metadata[@"height"] doubleValue]);std::sort(errors.begin(),errors.end());size_t n=errors.size();double median=n%2?errors[n/2]:(errors[n/2-1]+errors[n/2])/2;r[@"median_reprojection_px"]=@(median);}
                    r[@"reference_coverage"]=@(cx);r[@"query_coverage"]=@(cy);
                    if(x.size()>=10 && xi.size()>=8 && ratio>=.6 && std::min(cx,cy)>=.03){r[@"vote"]=@"match";r[@"reason"]=@"fixed_foreground_correspondence_gate";}
                }
            }
        }
    } catch(const std::exception &e){r[@"vote"]=@"uncertain";r[@"reason"]=@"opencv_error";r[@"error"]=@(e.what());}
    r[@"pair_ms"]=@(milliseconds(start));return r;
}
@end
