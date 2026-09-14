#import "temporal_processor.h"

#import <Foundation/Foundation.h>
#import <MetalFX/MetalFX.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <stdexcept>
#include <tuple>
#include <utility>
#include <vector>

namespace MH4U {
namespace {

id<MTLTexture> makeTexture(id<MTLDevice> device, MTLPixelFormat format, NSUInteger width,
                           NSUInteger height, MTLTextureUsage usage, MTLStorageMode storage) {
    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
    descriptor.usage = usage;
    descriptor.storageMode = storage;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    if (!texture) throw std::runtime_error("MetalFX texture allocation failed");
    return texture;
}

void completed(id<MTLCommandBuffer> command, const char *operation) {
    [command commit];
    [command waitUntilCompleted];
    if (command.status != MTLCommandBufferStatusCompleted) {
        const char *detail = command.error.localizedDescription.UTF8String;
        throw std::runtime_error(std::string(operation) + ": " + (detail ? detail : "GPU command failed"));
    }
}

} // namespace

struct TemporalProcessor::Impl {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLFXTemporalScaler> scaler;
    id<MTLTexture> color;
    id<MTLTexture> depth;
    id<MTLTexture> motion;
    id<MTLTexture> motionValid[2];
    id<MTLTexture> temporalOutput;
    id<MTLTexture> outputs[2];
    id<MTLTexture> interpolated;
    id<MTLComputePipelineState> temporalCompositePipeline;
    id<MTLComputePipelineState> interpolationPipeline;
    size_t inputWidth;
    size_t inputHeight;
    std::vector<uint8_t> allMotionValid;
    unsigned current = 0;
    bool hasCurrent = false;
    bool history = false;

    Impl(id<MTLDevice> inDevice, id<MTLCommandQueue> inQueue, size_t outputWidth, size_t outputHeight,
         size_t inInputWidth, size_t inInputHeight)
        : device(inDevice), queue(inQueue), inputWidth(inInputWidth), inputHeight(inInputHeight),
          allMotionValid(inputWidth * inputHeight, 255) {
        if (!device || !queue) throw std::invalid_argument("TemporalProcessor requires a Metal device and queue");
        if (!TemporalProcessor::supports(device, outputWidth, outputHeight, inputWidth, inputHeight))
            throw std::invalid_argument("Unsupported temporal output dimensions or Metal device");

        MTLFXTemporalScalerDescriptor *descriptor = [MTLFXTemporalScalerDescriptor new];
        descriptor.colorTextureFormat = descriptor.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
        descriptor.depthTextureFormat = MTLPixelFormatR32Float;
        descriptor.motionTextureFormat = MTLPixelFormatRG32Float;
        descriptor.inputWidth = inputWidth;
        descriptor.inputHeight = inputHeight;
        descriptor.outputWidth = outputWidth;
        descriptor.outputHeight = outputHeight;
        // BGRA8 is display-referred and has no engine exposure texture. Let MetalFX measure it.
        descriptor.autoExposureEnabled = YES;
        descriptor.requiresSynchronousInitialization = YES;
        scaler = [descriptor newTemporalScalerWithDevice:device];
        if (!scaler) throw std::runtime_error("MetalFX temporal scaler creation failed");

        color = makeTexture(device, MTLPixelFormatBGRA8Unorm, inputWidth, inputHeight,
                            scaler.colorTextureUsage, MTLStorageModeShared);
        depth = makeTexture(device, MTLPixelFormatR32Float, inputWidth, inputHeight,
                            scaler.depthTextureUsage, MTLStorageModeShared);
        motion = makeTexture(device, MTLPixelFormatRG32Float, inputWidth, inputHeight,
                             scaler.motionTextureUsage | MTLTextureUsageShaderRead, MTLStorageModeShared);
        temporalOutput = makeTexture(device, MTLPixelFormatBGRA8Unorm, outputWidth, outputHeight,
                                     scaler.outputTextureUsage | MTLTextureUsageShaderRead, MTLStorageModePrivate);
        for (unsigned i = 0; i < 2; ++i) {
            outputs[i] = makeTexture(device, MTLPixelFormatBGRA8Unorm, outputWidth, outputHeight,
                                     MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite, MTLStorageModePrivate);
            motionValid[i] = makeTexture(device, MTLPixelFormatR8Uint, inputWidth, inputHeight,
                                         MTLTextureUsageShaderRead, MTLStorageModeShared);
        }
        static NSString *source =
            @"#include <metal_stdlib>\nusing namespace metal;\n"
             "kernel void composite(texture2d<float,access::sample> color [[texture(0)]],"
             " texture2d<float,access::sample> temporal [[texture(1)]],texture2d<uint,access::read> valid [[texture(2)]],"
             " texture2d<float,access::write> output [[texture(3)]],uint2 q [[thread_position_in_grid]]) {"
             " if(any(q>=uint2(output.get_width(),output.get_height()))) return;"
             " constexpr sampler s(coord::pixel,filter::linear,address::clamp_to_edge);"
             " float2 scale=float2(output.get_width(),output.get_height())/float2(color.get_width(),color.get_height());"
             " uint2 p=min(uint2((float2(q)+.5)/scale),uint2(valid.get_width()-1,valid.get_height()-1));"
             " output.write(valid.read(p).r!=0?temporal.sample(s,float2(q)+.5):color.sample(s,(float2(q)+.5)/scale),q); }";
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        id<MTLFunction> function = [library newFunctionWithName:@"composite"];
        temporalCompositePipeline = function ? [device newComputePipelineStateWithFunction:function error:&error] : nil;
        if (!temporalCompositePipeline)
            throw std::runtime_error(error.localizedDescription.UTF8String ?: "Temporal validity composite setup failed");
    }
};

bool TemporalProcessor::supports(id<MTLDevice> device, size_t outputWidth, size_t outputHeight,
                                 size_t inputWidth, size_t inputHeight) {
    const size_t inputScale = inputWidth / TemporalProcessor::inputWidth;
    if (!device || inputScale < 1 || inputScale > 4 ||
        inputWidth != TemporalProcessor::inputWidth * inputScale ||
        inputHeight != TemporalProcessor::inputHeight * inputScale ||
        outputWidth != std::max<size_t>(800, inputWidth) ||
        outputHeight != std::max<size_t>(480, inputHeight) ||
        outputWidth > 16384 || outputHeight > 16384 ||
        outputWidth * inputHeight != outputHeight * inputWidth ||
        ![MTLFXTemporalScalerDescriptor supportsDevice:device])
        return false;
    if (@available(macOS 14.0, *)) {
        float contentScale = float(outputWidth) / float(inputWidth);
        float minimum = [MTLFXTemporalScalerDescriptor supportedInputContentMinScaleForDevice:device];
        float maximum = [MTLFXTemporalScalerDescriptor supportedInputContentMaxScaleForDevice:device];
        if (!std::isfinite(minimum) || !std::isfinite(maximum) || contentScale < minimum || contentScale > maximum)
            return false;
    }
    return true;
}

TemporalProcessor::TemporalProcessor(id<MTLDevice> device, id<MTLCommandQueue> queue,
                                     size_t outputWidth, size_t outputHeight,
                                     size_t inputWidth, size_t inputHeight)
    : impl_(std::make_unique<Impl>(device, queue, outputWidth, outputHeight, inputWidth, inputHeight)) {}
TemporalProcessor::~TemporalProcessor() = default;
TemporalProcessor::TemporalProcessor(TemporalProcessor&&) noexcept = default;
TemporalProcessor& TemporalProcessor::operator=(TemporalProcessor&&) noexcept = default;

id<MTLTexture> TemporalProcessor::process(const uint8_t *bgra, size_t colorBytesPerRow,
                                          const float *depth, size_t depthBytesPerRow,
                                          const float *motion, size_t motionBytesPerRow,
                                          bool depthReversed, bool reset, const uint8_t *motionValid) {
    const size_t colorRow = impl_->inputWidth * 4;
    const size_t depthRow = impl_->inputWidth * sizeof(float);
    const size_t motionRow = impl_->inputWidth * 2 * sizeof(float);
    if (!bgra || !depth || !motion || colorBytesPerRow < colorRow || depthBytesPerRow < depthRow ||
        motionBytesPerRow < motionRow)
        throw std::invalid_argument("Invalid temporal CPU frame or row stride");
    for (size_t y = 0; y < impl_->inputHeight; ++y) {
        const float *depthRowData = reinterpret_cast<const float *>(reinterpret_cast<const uint8_t *>(depth) + y * depthBytesPerRow);
        const float *motionRowData = reinterpret_cast<const float *>(reinterpret_cast<const uint8_t *>(motion) + y * motionBytesPerRow);
        for (size_t x = 0; x < impl_->inputWidth; ++x) {
            if (!std::isfinite(depthRowData[x]) || depthRowData[x] < 0.f || depthRowData[x] > 1.f)
                throw std::invalid_argument("Temporal depth must be finite and normalized");
            if (!std::isfinite(motionRowData[x * 2]) || !std::isfinite(motionRowData[x * 2 + 1]))
                throw std::invalid_argument("Temporal motion must be finite");
        }
    }

    [impl_->color replaceRegion:MTLRegionMake2D(0, 0, impl_->inputWidth, impl_->inputHeight) mipmapLevel:0
                       withBytes:bgra bytesPerRow:colorBytesPerRow];
    [impl_->depth replaceRegion:MTLRegionMake2D(0, 0, impl_->inputWidth, impl_->inputHeight) mipmapLevel:0
                       withBytes:depth bytesPerRow:depthBytesPerRow];
    [impl_->motion replaceRegion:MTLRegionMake2D(0, 0, impl_->inputWidth, impl_->inputHeight) mipmapLevel:0
                        withBytes:motion bytesPerRow:motionBytesPerRow];

    if (impl_->hasCurrent) impl_->current ^= 1;
    const uint8_t *validity = motionValid ? motionValid : impl_->allMotionValid.data();
    [impl_->motionValid[impl_->current] replaceRegion:MTLRegionMake2D(0, 0, impl_->inputWidth, impl_->inputHeight)
        mipmapLevel:0 withBytes:validity bytesPerRow:impl_->inputWidth];
    impl_->scaler.colorTexture = impl_->color;
    impl_->scaler.depthTexture = impl_->depth;
    impl_->scaler.motionTexture = impl_->motion;
    impl_->scaler.outputTexture = impl_->temporalOutput;
    impl_->scaler.inputContentWidth = impl_->inputWidth;
    impl_->scaler.inputContentHeight = impl_->inputHeight;
    impl_->scaler.motionVectorScaleX = 1.f;
    impl_->scaler.motionVectorScaleY = 1.f;
    impl_->scaler.jitterOffsetX = 0.f;
    impl_->scaler.jitterOffsetY = 0.f;
    impl_->scaler.preExposure = 1.f;
    impl_->scaler.depthReversed = depthReversed;
    impl_->scaler.reset = reset;
    id<MTLCommandBuffer> command = [impl_->queue commandBuffer];
    if (!command) throw std::runtime_error("MetalFX command buffer creation failed");
    [impl_->scaler encodeToCommandBuffer:command];
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    [encoder setComputePipelineState:impl_->temporalCompositePipeline];
    [encoder setTexture:impl_->color atIndex:0];
    [encoder setTexture:impl_->temporalOutput atIndex:1];
    [encoder setTexture:impl_->motionValid[impl_->current] atIndex:2];
    [encoder setTexture:impl_->outputs[impl_->current] atIndex:3];
    MTLSize threads = MTLSizeMake(8, 8, 1);
    MTLSize groups = MTLSizeMake((impl_->outputs[impl_->current].width + 7) / 8,
                                 (impl_->outputs[impl_->current].height + 7) / 8, 1);
    [encoder dispatchThreadgroups:groups threadsPerThreadgroup:threads];
    [encoder endEncoding];
    completed(command, "MetalFX temporal encode failed");
    impl_->history = impl_->hasCurrent && !reset;
    impl_->hasCurrent = true;
    return impl_->outputs[impl_->current];
}

id<MTLTexture> TemporalProcessor::previousTexture() const {
    return impl_->history ? impl_->outputs[impl_->current ^ 1] : nil;
}
id<MTLTexture> TemporalProcessor::currentTexture() const {
    return impl_->hasCurrent ? impl_->outputs[impl_->current] : nil;
}
id<MTLTexture> TemporalProcessor::motionTexture() const { return impl_->motion; }
bool TemporalProcessor::hasHistory() const { return impl_->history; }

id<MTLTexture> TemporalProcessor::interpolateEstimatedMotion() {
    if (!impl_->history) return nil;
    if (!impl_->interpolationPipeline) {
        static NSString *source =
            @"#include <metal_stdlib>\nusing namespace metal;\n"
             "kernel void midpoint(texture2d<float,access::sample> previous [[texture(0)]],"
             " texture2d<float,access::sample> current [[texture(1)]],"
             " texture2d<float,access::sample> motion [[texture(2)]],"
             " texture2d<float,access::write> output [[texture(3)]],"
             " texture2d<uint,access::read> currentValid [[texture(4)]],"
             " texture2d<uint,access::read> previousValid [[texture(5)]],uint2 q [[thread_position_in_grid]]) {"
             " if(any(q>=uint2(output.get_width(),output.get_height()))) return;"
             " constexpr sampler linear(coord::pixel,filter::linear,address::clamp_to_edge);"
             " float2 outSize=float2(output.get_width(),output.get_height());"
             " float2 inSize=float2(motion.get_width(),motion.get_height());"
             " float2 scale=outSize/inSize, qp=(float2(q)+.5)/scale-.5, c=qp;"
             " for(uint i=0;i<3;i++) c=qp-.5*motion.sample(linear,c+.5).xy;"
             " float2 m=motion.sample(linear,c+.5).xy, p=c+m;"
             " bool valid=all(c>=0)&&all(p>=0)&&all(c<inSize-1)&&all(p<inSize-1);"
             " float solveError=length(c+.5*m-qp),coherence=0;"
             " const float2 offsets[4]={float2(-4,0),float2(4,0),float2(0,-4),float2(0,4)};"
             " for(uint i=0;i<4;i++) coherence=max(coherence,length(motion.sample(linear,c+offsets[i]+.5).xy-m));"
             " valid=valid&&solveError<.5&&coherence<2.;"
             " uint2 ci=uint2(clamp(c,float2(0),inSize-1)),pi=uint2(clamp(p,float2(0),inSize-1));"
             " valid=valid&&currentValid.read(ci).r!=0&&previousValid.read(pi).r!=0;"
             " float4 cc=current.sample(linear,(c+.5)*scale);"
             " float4 pc=previous.sample(linear,(p+.5)*scale);"
             " float residual=max(max(abs(cc.r-pc.r),abs(cc.g-pc.g)),abs(cc.b-pc.b));"
             " float4 fallback=current.sample(linear,float2(q)+.5);"
             " output.write(valid&&residual<=.15 ? mix(pc,cc,.5) : fallback,q); }";
        NSError *error = nil;
        id<MTLLibrary> library = [impl_->device newLibraryWithSource:source options:nil error:&error];
        id<MTLFunction> function = [library newFunctionWithName:@"midpoint"];
        impl_->interpolationPipeline = function ? [impl_->device newComputePipelineStateWithFunction:function error:&error] : nil;
        if (!impl_->interpolationPipeline)
            throw std::runtime_error(error.localizedDescription.UTF8String ?: "Estimated-motion interpolation setup failed");
        impl_->interpolated = makeTexture(impl_->device, MTLPixelFormatBGRA8Unorm,
            impl_->outputs[0].width, impl_->outputs[0].height,
            MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite, MTLStorageModePrivate);
    }
    id<MTLCommandBuffer> command = [impl_->queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    [encoder setComputePipelineState:impl_->interpolationPipeline];
    [encoder setTexture:impl_->outputs[impl_->current ^ 1] atIndex:0];
    [encoder setTexture:impl_->outputs[impl_->current] atIndex:1];
    [encoder setTexture:impl_->motion atIndex:2];
    [encoder setTexture:impl_->interpolated atIndex:3];
    [encoder setTexture:impl_->motionValid[impl_->current] atIndex:4];
    [encoder setTexture:impl_->motionValid[impl_->current ^ 1] atIndex:5];
    MTLSize threads = MTLSizeMake(8, 8, 1);
    MTLSize groups = MTLSizeMake((impl_->interpolated.width + 7) / 8,
                                 (impl_->interpolated.height + 7) / 8, 1);
    [encoder dispatchThreadgroups:groups threadsPerThreadgroup:threads];
    [encoder endEncoding];
    completed(command, "Estimated-motion interpolation failed");
    return impl_->interpolated;
}

void temporalProcessorSelfTest(id<MTLDevice> device, id<MTLCommandQueue> queue) {
    if (TemporalProcessor::supports(device, 2000, 1200, 2000, 1200) ||
        TemporalProcessor::supports(device, 1200, 720, 800, 480))
        throw std::runtime_error("Temporal self-test accepted invalid scale bounds or output dimensions");
    for (size_t inputScale = 1; inputScale <= 4; ++inputScale) {
        const size_t width = TemporalProcessor::inputWidth * inputScale;
        const size_t height = TemporalProcessor::inputHeight * inputScale;
        const size_t outputWidth = std::max<size_t>(800, width), outputHeight = std::max<size_t>(480, height);
        const double outputScale = double(outputWidth) / width;
        if (!TemporalProcessor::supports(device, outputWidth, outputHeight, width, height))
            throw std::runtime_error("Temporal self-test rejected a supported internal resolution");
        std::vector<uint8_t> color(width * height * 4, 0), invalid(width * height, 0);
        std::vector<float> depth(width * height, 0.75f), motion(width * height * 2, 0.f);
        auto fillSquare = [&](size_t x, size_t top) {
            std::fill(color.begin(), color.end(), 0);
            for (size_t y = top * inputScale; y < (top + 40) * inputScale; ++y)
                for (size_t px = x * inputScale; px < (x + 32) * inputScale; ++px) {
                    color[(y * width + px) * 4 + 2] = 255;
                    color[(y * width + px) * 4 + 3] = 255;
                }
        };
        TemporalProcessor processor(device, queue, outputWidth, outputHeight, width, height);
        if (processor.currentTexture())
            throw std::runtime_error("Temporal self-test exposed an uninitialized current texture");
        fillSquare(40, 64);
        processor.process(color.data(), width * 4, depth.data(), width * sizeof(float), motion.data(),
                          width * 2 * sizeof(float), false, true);
        if (processor.hasHistory() || processor.previousTexture() || processor.interpolateEstimatedMotion())
            throw std::runtime_error("Temporal self-test reset retained history");
        fillSquare(56, 80);
        for (size_t i = 0; i < width * height; ++i)
            motion[i * 2] = motion[i * 2 + 1] = -16.f * inputScale;
        id<MTLTexture> output = processor.process(color.data(), width * 4, depth.data(), width * sizeof(float),
                                                  motion.data(), width * 2 * sizeof(float), false, false);
        if (!processor.hasHistory() || !processor.previousTexture() || processor.previousTexture() == output)
            throw std::runtime_error("Temporal self-test did not preserve distinct consecutive outputs");

        const size_t bytesPerRow = outputWidth * 4;
        id<MTLBuffer> readback = [device newBufferWithLength:bytesPerRow * outputHeight
                                                     options:MTLResourceStorageModeShared];
        auto readPixels = [&](id<MTLTexture> texture) {
            id<MTLCommandBuffer> command = [queue commandBuffer];
            id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
            [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                         sourceSize:MTLSizeMake(outputWidth, outputHeight, 1) toBuffer:readback destinationOffset:0
                destinationBytesPerRow:bytesPerRow destinationBytesPerImage:bytesPerRow * outputHeight];
            [blit endEncoding];
            completed(command, "Temporal self-test readback failed");
            const uint8_t *begin = static_cast<const uint8_t *>(readback.contents);
            return std::vector<uint8_t>(begin, begin + bytesPerRow * outputHeight);
        };
        auto centroid = [&](id<MTLTexture> texture) {
            std::vector<uint8_t> data = readPixels(texture);
            double energy = 0, weightedX = 0, weightedY = 0;
            for (size_t y = 0; y < outputHeight; ++y) for (size_t x = 0; x < outputWidth; ++x) {
                double red = data[y * bytesPerRow + x * 4 + 2];
                energy += red;
                weightedX += red * x;
                weightedY += red * y;
            }
            return std::pair{energy ? weightedX / energy : -1., energy ? weightedY / energy : -1.};
        };
        id<MTLTexture> midpoint = processor.interpolateEstimatedMotion();
        if (!midpoint) throw std::runtime_error("Temporal self-test interpolation produced no frame");
        auto [centerX, centerY] = centroid(midpoint);
        if (std::abs(centerX - 63.5 * inputScale * outputScale) > 8 ||
            std::abs(centerY - 91.5 * inputScale * outputScale) > 8)
            throw std::runtime_error("Temporal self-test diagonal midpoint has the wrong position or motion sign");

        std::fill(motion.begin(), motion.end(), 0.f);
        fillSquare(140, 100);
        processor.process(color.data(), width * 4, depth.data(), width * sizeof(float), motion.data(),
                          width * 2 * sizeof(float), false, true);
        if (processor.hasHistory() || processor.previousTexture() || processor.interpolateEstimatedMotion())
            throw std::runtime_error("Temporal self-test history survived a reset after active use");
        fillSquare(148, 108);
        for (size_t i = 0; i < width * height; ++i)
            motion[i * 2] = motion[i * 2 + 1] = -8.f * inputScale;
        processor.process(color.data(), width * 4, depth.data(), width * sizeof(float), motion.data(),
                          width * 2 * sizeof(float), false, false);
        midpoint = processor.interpolateEstimatedMotion();
        if (!midpoint) throw std::runtime_error("Temporal self-test did not rebuild history after reset");
        std::tie(centerX, centerY) = centroid(midpoint);
        if (std::abs(centerX - 159.5 * inputScale * outputScale) > 6 ||
            std::abs(centerY - 123.5 * inputScale * outputScale) > 6)
            throw std::runtime_error("Temporal self-test selected stale output after reset");

        fillSquare(160, 120);
        processor.process(color.data(), width * 4, depth.data(), width * sizeof(float), motion.data(),
                          width * 2 * sizeof(float), false, false, invalid.data());
        midpoint = processor.interpolateEstimatedMotion();
        if (!midpoint || readPixels(midpoint) != readPixels(processor.currentTexture()))
            throw std::runtime_error("Temporal self-test generated pixels from invalid motion");
    }
}

} // namespace MH4U
