#import "motion_estimator.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>
#include <mutex>

namespace MotionEstimator {
namespace {
NSString *const source = @R"metal(
#include <metal_stdlib>
using namespace metal;
struct Params { uint width, height, previousStride, currentStride; };
float score(device const uchar4 *previous, device const uchar4 *current,
            constant Params &p, int2 center, int2 motion) {
    float sad = 0.0f; uint count = 0;
    for (int oy = -3; oy <= 3; oy += 3) for (int ox = -3; ox <= 3; ox += 3) {
        int2 c = center + int2(ox, oy), q = c + motion;
        if (all(c >= 0) && c.x < int(p.width) && c.y < int(p.height)) {
            if (any(q < 0) || q.x >= int(p.width) || q.y >= int(p.height)) return INFINITY;
            uchar4 a = current[uint(c.y) * p.currentStride + uint(c.x)];
            uchar4 b = previous[uint(q.y) * p.previousStride + uint(q.x)];
            sad += abs(float(a.x)-float(b.x)) + abs(float(a.y)-float(b.y)) + abs(float(a.z)-float(b.z));
            ++count;
        }
    }
    return count ? sad / float(count) : INFINITY;
}
kernel void blockMotion(device const uchar4 *previous [[buffer(0)]],
                        device const uchar4 *current [[buffer(1)]],
                        device float2 *flow [[buffer(2)]], constant Params &p [[buffer(3)]],
                        device uchar *valid [[buffer(4)]],
                        uint2 tile [[thread_position_in_grid]]) {
    uint2 begin=tile*4;
    int2 center=int2(min(begin.x+2,p.width-1),min(begin.y+2,p.height-1));
    int2 best=0; float bestScore=score(previous,current,p,center,best);
    for (int y=-24; y<=24; y+=4) for (int x=-24; x<=24; x+=4) {
        if(x==0 && y==0) continue;
        float candidate=score(previous,current,p,center,int2(x,y));
        if(candidate<bestScore){bestScore=candidate;best=int2(x,y);}
    }
    for(int step=2;step>=1;--step){int2 origin=best;
        for(int y=-step;y<=step;y+=step) for(int x=-step;x<=step;x+=step){
            int2 motion=origin+int2(x,y); float candidate=score(previous,current,p,center,motion);
            if(candidate<bestScore){bestScore=candidate;best=motion;}
        }
    }
    float darkest=255.0f,brightest=0.0f;
    for(int oy=-3;oy<=3;oy+=3) for(int ox=-3;ox<=3;ox+=3){int2 c=center+int2(ox,oy);
        if(all(c>=0)&&c.x<int(p.width)&&c.y<int(p.height)){uchar4 a=current[uint(c.y)*p.currentStride+uint(c.x)];
            float luma=(float(a.x)+2.0f*float(a.y)+float(a.z))*.25f;darkest=min(darkest,luma);brightest=max(brightest,luma);}}
    uchar isValid=(brightest-darkest>8.0f && bestScore<24.0f) ? 1 : 0;
    for(uint y=begin.y;y<min(begin.y+4,p.height);++y)
        for(uint x=begin.x;x<min(begin.x+4,p.width);++x){flow[y*p.width+x]=float2(best);valid[y*p.width+x]=isValid;}
}
)metal";

id<MTLComputePipelineState> pipeline(id<MTLDevice> device, std::string &error) {
    static std::mutex mutex; static id<MTLDevice> cachedDevice; static id<MTLComputePipelineState> cachedPipeline;
    std::lock_guard lock(mutex);
    if(cachedPipeline && cachedDevice==device) return cachedPipeline;
    NSError *failure=nil; id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&failure];
    if(!library){error=failure.localizedDescription.UTF8String?:"Metal shader compilation failed";return nil;}
    cachedPipeline=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"blockMotion"] error:&failure];
    cachedDevice=device;
    if(!cachedPipeline) error=failure.localizedDescription.UTF8String?:"Metal pipeline creation failed";
    return cachedPipeline;
}
struct Params { uint32_t width,height,previousStride,currentStride; };

bool runMetal(const uint8_t *previousBGRA, size_t previousBytesPerRow,
              const uint8_t *currentBGRA, size_t currentBytesPerRow,
              size_t width, size_t height, id<MTLDevice> device,
              id<MTLCommandQueue> queue, std::vector<float> &xy,
              std::vector<uint8_t> &valid, std::string &error) {
    id<MTLComputePipelineState> state=pipeline(device,error); if(!state)return false;
    id<MTLBuffer> previous=[device newBufferWithBytes:previousBGRA length:previousBytesPerRow*height options:MTLResourceStorageModeShared];
    id<MTLBuffer> current=[device newBufferWithBytes:currentBGRA length:currentBytesPerRow*height options:MTLResourceStorageModeShared];
    id<MTLBuffer> output=[device newBufferWithLength:width*height*2*sizeof(float) options:MTLResourceStorageModeShared];
    id<MTLBuffer> validity=[device newBufferWithLength:width*height options:MTLResourceStorageModeShared];
    if(!previous||!current||!output||!validity){error="Metal motion buffer allocation failed";return false;}
    Params params{uint32_t(width),uint32_t(height),uint32_t(previousBytesPerRow/4),uint32_t(currentBytesPerRow/4)};
    id<MTLCommandBuffer> command=[queue commandBuffer]; id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];
    if(!command||!encoder){error="Metal motion command allocation failed";return false;}
    [encoder setComputePipelineState:state]; [encoder setBuffer:previous offset:0 atIndex:0]; [encoder setBuffer:current offset:0 atIndex:1];
    [encoder setBuffer:output offset:0 atIndex:2]; [encoder setBytes:&params length:sizeof(params) atIndex:3];
    [encoder setBuffer:validity offset:0 atIndex:4];
    MTLSize grid=MTLSizeMake((width+3)/4,(height+3)/4,1); NSUInteger groupWidth=std::min<NSUInteger>(state.maxTotalThreadsPerThreadgroup,64);
    [encoder dispatchThreads:grid threadsPerThreadgroup:MTLSizeMake(groupWidth,1,1)]; [encoder endEncoding];
    [command commit]; [command waitUntilCompleted];
    if(command.status!=MTLCommandBufferStatusCompleted){error=command.error.localizedDescription.UTF8String?:"Metal motion command failed";return false;}
    xy.resize(width*height*2); std::memcpy(xy.data(),output.contents,xy.size()*sizeof(float));
    valid.resize(width*height); std::memcpy(valid.data(),validity.contents,valid.size());
    return true;
}

void boxDownsample(const uint8_t *source, size_t stride, size_t width, size_t height,
                   size_t scale, std::vector<uint8_t> &destination) {
    const size_t proxyWidth=width/scale, proxyHeight=height/scale;
    destination.resize(proxyWidth*proxyHeight*4);
    for(size_t y=0;y<proxyHeight;++y) for(size_t x=0;x<proxyWidth;++x) {
        uint32_t sum[4]={};
        for(size_t oy=0;oy<scale;++oy) for(size_t ox=0;ox<scale;++ox) {
            const uint8_t *pixel=source+(y*scale+oy)*stride+(x*scale+ox)*4;
            for(size_t channel=0;channel<4;++channel) sum[channel]+=pixel[channel];
        }
        uint8_t *pixel=destination.data()+(y*proxyWidth+x)*4;
        const uint32_t count=uint32_t(scale*scale);
        for(size_t channel=0;channel<4;++channel) pixel[channel]=uint8_t((sum[channel]+count/2)/count);
    }
}
} // namespace

bool estimateCurrentToPrevious(const uint8_t *previousBGRA,size_t previousBytesPerRow,
                               const uint8_t *currentBGRA,size_t currentBytesPerRow,
                               size_t width,size_t height,id<MTLDevice> device,id<MTLCommandQueue> queue,
                               Result &result,std::string &error) {
    result={}; error.clear();
    if(!previousBGRA||!currentBGRA||!device||!queue||!width||!height||width>UINT32_MAX||height>UINT32_MAX||
       previousBytesPerRow/4>UINT32_MAX||currentBytesPerRow/4>UINT32_MAX||width>std::numeric_limits<size_t>::max()/4||
       height>std::numeric_limits<size_t>::max()/width||width*height>std::numeric_limits<size_t>::max()/(2*sizeof(float))||
       previousBytesPerRow>std::numeric_limits<size_t>::max()/height||currentBytesPerRow>std::numeric_limits<size_t>::max()/height||
       previousBytesPerRow<width*4||currentBytesPerRow<width*4||previousBytesPerRow%4||currentBytesPerRow%4){
        error="invalid BGRA frame, Metal context, or dimensions"; return false;
    }
    auto start=std::chrono::steady_clock::now();
    @autoreleasepool {
        size_t scale=1;
        for(size_t candidate=2;candidate<=4;++candidate)
            if(width==400*candidate&&height==240*candidate) scale=candidate;
        const size_t proxyWidth=width/scale, proxyHeight=height/scale;
        std::vector<uint8_t> previousProxy,currentProxy;
        const uint8_t *previousInput=previousBGRA,*currentInput=currentBGRA;
        size_t previousStride=previousBytesPerRow,currentStride=currentBytesPerRow;
        if(scale>1) {
            boxDownsample(previousBGRA,previousBytesPerRow,width,height,scale,previousProxy);
            boxDownsample(currentBGRA,currentBytesPerRow,width,height,scale,currentProxy);
            previousInput=previousProxy.data(); currentInput=currentProxy.data();
            previousStride=currentStride=proxyWidth*4;
        }
        std::vector<float> proxyXY; std::vector<uint8_t> proxyValid;
        if(!runMetal(previousInput,previousStride,currentInput,currentStride,proxyWidth,proxyHeight,
                     device,queue,proxyXY,proxyValid,error)) return false;
        result.xy.resize(width*height*2); result.valid.resize(width*height);
        for(size_t y=0;y<height;++y) for(size_t x=0;x<width;++x) {
            const size_t proxyIndex=(y/scale*proxyWidth+x/scale);
            const size_t outputIndex=(y*width+x);
            result.xy[outputIndex*2]=proxyXY[proxyIndex*2]*float(scale);
            result.xy[outputIndex*2+1]=proxyXY[proxyIndex*2+1]*float(scale);
            result.valid[outputIndex]=proxyValid[proxyIndex];
        }
        double magnitudeSum=0,difference=0; size_t validCount=0;
        for(size_t y=0;y<height;++y) for(size_t x=0;x<width;++x){size_t i=(y*width+x)*2;
            double magnitude=std::hypot(result.xy[i],result.xy[i+1]); magnitudeSum+=magnitude; result.maxMagnitude=std::max(result.maxMagnitude,magnitude);
            validCount+=result.valid[y*width+x];
            for(size_t channel=0;channel<3;++channel) difference+=std::abs(int(currentBGRA[y*currentBytesPerRow+x*4+channel])-int(previousBGRA[y*previousBytesPerRow+x*4+channel]));
        }
        result.meanMagnitude=magnitudeSum/(width*height); result.validFraction=double(validCount)/(width*height);
        result.meanAbsoluteColorDifference=difference/(width*height*3*255.0);
        result.elapsedMilliseconds=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count(); return true;
    }
}
} // namespace MotionEstimator
