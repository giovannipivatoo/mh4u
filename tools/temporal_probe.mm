#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <vector>

static id<MTLTexture> texture(id<MTLDevice> device, MTLPixelFormat format, NSUInteger w,
                              NSUInteger h, MTLTextureUsage usage, MTLStorageMode storage) {
    auto *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
    d.usage = usage; d.storageMode = storage;
    id<MTLTexture> result = [device newTextureWithDescriptor:d];
    if (!result) throw std::runtime_error("texture allocation failed");
    return result;
}

static void fillColor(id<MTLTexture> target, unsigned squareX) {
    const unsigned w = unsigned(target.width), h = unsigned(target.height);
    const unsigned pan = squareX - 20;
    std::vector<uint8_t> pixels(size_t(w) * h * 4, 0);
    for (unsigned y = 0; y < h; ++y) for (unsigned x = 0; x < w; ++x) {
        auto i = (size_t(y) * w + x) * 4;
        pixels[i + (((((x + w - pan % w) % w) / 8 + y / 8) & 1) ? 0 : 1)] = 24; pixels[i + 3] = 255;
    }
    for (unsigned y = 24; y < 72; ++y) for (unsigned x = squareX; x < squareX + 32; ++x) {
        auto i = (size_t(y) * w + x) * 4; pixels[i + 2] = 255; pixels[i + 3] = 255;
    }
    [target replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:pixels.data() bytesPerRow:w * 4];
}

static void fillDepth(id<MTLTexture> target, unsigned) {
    // Standard perspective depth for z=2, near=.1, far=100 (normal, not reversed).
    std::vector<float> depths(target.width * target.height, 0.95095095f);
    [target replaceRegion:MTLRegionMake2D(0,0,target.width,target.height) mipmapLevel:0
        withBytes:depths.data() bytesPerRow:target.width*sizeof(float)];
}

static void fillUniformMotion(id<MTLTexture> target, float dx) {
    std::vector<_Float16> values(target.width * target.height * 2, 0);
    for (size_t i = 0; i < target.width * target.height; ++i) values[i * 2] = (_Float16)dx;
    [target replaceRegion:MTLRegionMake2D(0,0,target.width,target.height) mipmapLevel:0
        withBytes:values.data() bytesPerRow:target.width * 2 * sizeof(_Float16)];
}

static std::vector<uint8_t> readback(id<MTLDevice> device, id<MTLCommandQueue> queue, id<MTLTexture> source) {
    NSUInteger row = ((source.width * 4 + 255) / 256) * 256;
    id<MTLBuffer> buffer = [device newBufferWithLength:row * source.height options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    [blit copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
        sourceSize:MTLSizeMake(source.width, source.height, 1) toBuffer:buffer destinationOffset:0
        destinationBytesPerRow:row destinationBytesPerImage:row * source.height];
    [blit endEncoding]; [command commit]; [command waitUntilCompleted];
    if (command.status != MTLCommandBufferStatusCompleted)
        throw std::runtime_error(command.error.localizedDescription.UTF8String ?: "GPU readback failed");
    std::vector<uint8_t> result(size_t(source.width) * source.height * 4);
    for (NSUInteger y = 0; y < source.height; ++y)
        memcpy(result.data() + y * source.width * 4, static_cast<uint8_t *>(buffer.contents) + y * row, source.width * 4);
    return result;
}

static size_t redEnergy(const std::vector<uint8_t>& pixels) {
    size_t sum = 0; for (size_t i = 2; i < pixels.size(); i += 4) sum += pixels[i]; return sum;
}

static size_t redEnergyRegion(const std::vector<uint8_t>& pixels, unsigned width,
                              unsigned x0, unsigned x1, unsigned y0, unsigned y1) {
    size_t sum = 0;
    for (unsigned y = y0; y < y1; ++y) for (unsigned x = x0; x < x1; ++x)
        sum += pixels[(size_t(y) * width + x) * 4 + 2];
    return sum;
}

static void fillMotion(id<MTLTexture> target, unsigned squareX, float dx) {
    std::vector<_Float16> values(target.width * target.height * 2, 0);
    for (unsigned y = 24; y < 72; ++y) for (unsigned x = squareX; x < squareX + 32; ++x)
        values[(size_t(y) * target.width + x) * 2] = (_Float16)dx;
    [target replaceRegion:MTLRegionMake2D(0,0,target.width,target.height) mipmapLevel:0
        withBytes:values.data() bytesPerRow:target.width * 2 * sizeof(_Float16)];
}

static double redCentroidX(const std::vector<uint8_t>& pixels, unsigned width) {
    double weighted = 0, energy = 0;
    for (size_t i = 2; i < pixels.size(); i += 4) { double red = pixels[i]; weighted += ((i / 4) % width) * red; energy += red; }
    return energy ? weighted / energy : -1;
}

int main() {
    @autoreleasepool {
        try {
            if (@available(macOS 26.0, *)) {
                id<MTLDevice> device = MTLCreateSystemDefaultDevice();
                if (!device) throw std::runtime_error("no Metal device");
                if (![MTLFXTemporalScalerDescriptor supportsDevice:device]) {
                    puts("{\"supported\":false,\"reason\":\"temporal scaling unsupported\"}"); return 77;
                }
                constexpr NSUInteger w = 400, h = 240, ow = 800, oh = 480;
                MTLFXTemporalScalerDescriptor *td = [MTLFXTemporalScalerDescriptor new];
                td.colorTextureFormat = td.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
                td.depthTextureFormat = MTLPixelFormatR32Float;
                td.motionTextureFormat = MTLPixelFormatRG16Float;
                td.inputWidth = w; td.inputHeight = h; td.outputWidth = ow; td.outputHeight = oh;
                td.autoExposureEnabled = YES; td.requiresSynchronousInitialization = YES;
                id<MTLFXTemporalScaler> temporal = [td newTemporalScalerWithDevice:device];
                if (!temporal) throw std::runtime_error("temporal scaler creation failed");
                auto color = texture(device, td.colorTextureFormat, w, h, temporal.colorTextureUsage, MTLStorageModeShared);
                auto depth = texture(device, td.depthTextureFormat, w, h, temporal.depthTextureUsage, MTLStorageModeShared);
                auto motion = texture(device, td.motionTextureFormat, w, h, temporal.motionTextureUsage, MTLStorageModeShared);
                auto temporalOut = texture(device, td.outputTextureFormat, ow, oh, temporal.outputTextureUsage | MTLTextureUsageShaderRead, MTLStorageModePrivate);
                id<MTLCommandQueue> queue = [device newCommandQueue];
                auto runTemporalTo = [&](unsigned x, float dx, bool reset, id<MTLTexture> destination, bool uniformMotion=false) {
                    fillDepth(depth, x);
                    if (uniformMotion) fillUniformMotion(motion, dx); else fillMotion(motion, x, dx);
                    fillColor(color, x); temporal.colorTexture=color; temporal.depthTexture=depth; temporal.motionTexture=motion;
                    temporal.outputTexture=destination; temporal.inputContentWidth=w; temporal.inputContentHeight=h;
                    temporal.motionVectorScaleX=temporal.motionVectorScaleY=1; temporal.jitterOffsetX=temporal.jitterOffsetY=0;
                    temporal.depthReversed=NO; temporal.reset=reset;
                    id<MTLCommandBuffer> command=[queue commandBuffer]; [temporal encodeToCommandBuffer:command]; [command commit]; [command waitUntilCompleted];
                    if (command.status != MTLCommandBufferStatusCompleted) throw std::runtime_error(command.error.localizedDescription.UTF8String ?: "temporal encode failed");
                    return readback(device, queue, destination);
                };
                auto temporalA=runTemporalTo(20, 0, true, temporalOut), temporalB=runTemporalTo(36, -16, false, temporalOut), temporalReset=runTemporalTo(36, 0, true, temporalOut);
                if (!redEnergy(temporalA) || !redEnergy(temporalB) || !redEnergy(temporalReset)) throw std::runtime_error("temporal output was empty");
                double temporalMovingCenter=redCentroidX(temporalB,ow), temporalResetCenter=redCentroidX(temporalReset,ow);
                constexpr double expectedScaledCenter=103.0;
                if (std::abs(temporalMovingCenter-expectedScaledCenter)>8 || std::abs(temporalResetCenter-expectedScaledCenter)>8)
                    throw std::runtime_error("temporal output centroid did not follow the scaled moving object");
                size_t resetGhostEnergy=redEnergyRegion(temporalReset,ow,35,65,48,144);
                if (resetGhostEnergy*20 > redEnergy(temporalReset))
                    throw std::runtime_error("temporal reset retained excessive energy in the stale-only region");

                bool interpolationSupported = [MTLFXFrameInterpolatorDescriptor supportsDevice:device];
                size_t interpolationEnergy = 0;
                double interpolationCenter = -1;
                std::vector<double> interpolationCenters;
                std::vector<size_t> interpolationEnergies;
                std::vector<double> interpolationMidpoints, interpolationPrevious, interpolationCurrent;
                if (interpolationSupported) {
                    MTLFXFrameInterpolatorDescriptor *fd=[MTLFXFrameInterpolatorDescriptor new];
                    fd.colorTextureFormat=fd.outputTextureFormat=MTLPixelFormatBGRA8Unorm;
                    fd.depthTextureFormat=MTLPixelFormatR32Float; fd.motionTextureFormat=MTLPixelFormatRG16Float;
                    fd.scaler=temporal;
                    fd.inputWidth=w; fd.inputHeight=h; fd.outputWidth=ow; fd.outputHeight=oh;
                    id<MTLFXFrameInterpolator> interp=[fd newFrameInterpolatorWithDevice:device];
                    if (!interp) throw std::runtime_error("frame interpolator creation failed");
                    auto previous=texture(device, fd.colorTextureFormat,ow,oh,temporal.outputTextureUsage|interp.colorTextureUsage,MTLStorageModePrivate);
                    auto current=texture(device, fd.colorTextureFormat,ow,oh,temporal.outputTextureUsage|interp.colorTextureUsage,MTLStorageModePrivate);
                    auto out=texture(device,fd.outputTextureFormat,ow,oh,interp.outputTextureUsage|MTLTextureUsageShaderRead,MTLStorageModePrivate);
                    interp.depthTexture=depth; interp.motionTexture=motion; interp.outputTexture=out;
                    interp.motionVectorScaleX=interp.motionVectorScaleY=1; interp.deltaTime=1.f/30.f; interp.nearPlane=.1f; interp.farPlane=100.f;
                    interp.fieldOfView=60; interp.aspectRatio=float(w)/h; interp.jitterOffsetX=interp.jitterOffsetY=0; interp.depthReversed=NO;
                    // Follow Apple's combined path: interpolate two consecutive temporal-upscaler outputs.
                    auto previousPixels=runTemporalTo(80,0,true,previous,true);
                    fillDepth(depth,80); fillUniformMotion(motion,0); interp.prevColorTexture=previous; interp.colorTexture=previous; interp.shouldResetHistory=YES;
                    id<MTLCommandBuffer> warmup=[queue commandBuffer]; [interp encodeToCommandBuffer:warmup]; [warmup commit]; [warmup waitUntilCompleted];
                    if(warmup.status!=MTLCommandBufferStatusCompleted) throw std::runtime_error(warmup.error.localizedDescription.UTF8String ?: "interpolation warmup failed");
                    for (unsigned frame=1; frame<30; ++frame) {
                        unsigned x=80+frame*8;
                        auto currentPixels=runTemporalTo(x,-8,false,current,true);
                        fillDepth(depth,x); fillUniformMotion(motion,-8); interp.prevColorTexture=previous; interp.colorTexture=current; interp.shouldResetHistory=NO;
                        id<MTLCommandBuffer> command=[queue commandBuffer]; [interp encodeToCommandBuffer:command]; [command commit]; [command waitUntilCompleted];
                        if(command.status!=MTLCommandBufferStatusCompleted) throw std::runtime_error(command.error.localizedDescription.UTF8String ?: "interpolation encode failed");
                        auto interpolated=readback(device,queue,out); interpolationEnergy=redEnergy(interpolated);
                        interpolationCenter=redCentroidX(interpolated,ow); interpolationCenters.push_back(interpolationCenter); interpolationEnergies.push_back(interpolationEnergy);
                        double prevCenter=redCentroidX(previousPixels,ow), currentCenter=redCentroidX(currentPixels,ow);
                        double midpoint=(prevCenter+currentCenter)/2;
                        interpolationMidpoints.push_back(midpoint); interpolationPrevious.push_back(prevCenter); interpolationCurrent.push_back(currentCenter);
                        std::swap(previous,current); previousPixels=std::move(currentPixels);
                    }
                    bool steady=true;
                    for(size_t i=interpolationCenters.size()-3;i<interpolationCenters.size();++i)
                        steady &= interpolationEnergies[i] && std::abs(interpolationCenters[i]-interpolationMidpoints[i])<=4.0 &&
                                  std::abs(interpolationCenters[i]-interpolationPrevious[i])>=4.0 &&
                                  std::abs(interpolationCenters[i]-interpolationCurrent[i])>=4.0;
                    if(!steady) throw std::runtime_error("frame interpolation remained endpoint passthrough after 29 continuous pairs; final previous/current/midpoint/output="+
                        std::to_string(interpolationPrevious.back())+"/"+std::to_string(interpolationCurrent.back())+"/"+
                        std::to_string(interpolationMidpoints.back())+"/"+std::to_string(interpolationCenters.back()));
                }
                std::string centerSeries="[";
                for (size_t i=0;i<interpolationCenters.size();++i) { if(i) centerSeries+=","; char value[32]; snprintf(value,sizeof(value),"%.3f",interpolationCenters[i]); centerSeries+=value; }
                centerSeries+="]";
                std::string energySeries="[";
                for (size_t i=0;i<interpolationEnergies.size();++i) { if(i) energySeries+=","; energySeries+=std::to_string(interpolationEnergies[i]); }
                energySeries+="]";
                printf("{\"supported\":true,\"synthetic_scene\":true,\"device\":\"%s\",\"temporal_gpu_output\":true,\"temporal_moving_centroid_x\":%.3f,\"temporal_reset_centroid_x\":%.3f,\"temporal_reset_stale_energy\":%zu,\"temporal_reset_energy\":%zu,\"interpolation_supported\":%s,\"interpolation_gpu_output\":%s,\"interpolation_warmup_pairs\":26,\"interpolation_steady_pairs_checked\":3,\"interpolation_midpoint_tolerance_pixels\":4,\"interpolation_centroids_x\":%s,\"interpolation_energies\":%s}\n", device.name.UTF8String, temporalMovingCenter, temporalResetCenter, resetGhostEnergy, redEnergy(temporalReset), interpolationSupported?"true":"false", interpolationEnergy?"true":"false", centerSeries.c_str(), energySeries.c_str());
                return 0;
            }
            puts("{\"supported\":false,\"reason\":\"requires macOS 26\"}"); return 77;
        } catch (const std::exception& e) { fprintf(stderr,"temporal-probe: %s\n",e.what()); return 1; }
    }
}
