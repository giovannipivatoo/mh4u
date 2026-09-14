#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>

#include "motion_estimator.h"
#include "temporal_processor.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void motionSelfTest(id<MTLDevice> device, id<MTLCommandQueue> queue) {
    constexpr size_t width = 64, height = 48, shift = 4;
    std::vector<uint8_t> previous(width * height * 4), current(width * height * 4);
    for (size_t y = 0; y < height; ++y) for (size_t x = 0; x < width; ++x) {
        size_t i = (y * width + x) * 4;
        previous[i] = uint8_t((x * 37 + y * 11) & 255);
        previous[i + 1] = uint8_t((x * 13 + y * 41) & 255);
        previous[i + 2] = uint8_t((x * 29 + y * 17) & 255);
        previous[i + 3] = 255;
    }
    for (size_t y = 0; y < height; ++y) for (size_t x = shift; x < width; ++x)
        std::copy_n(previous.data() + (y * width + x - shift) * 4, 4,
                    current.data() + (y * width + x) * 4);
    MotionEstimator::Result result;
    std::string error;
    if (!MotionEstimator::estimateCurrentToPrevious(previous.data(), width * 4, current.data(), width * 4,
                                                     width, height, device, queue, result, error))
        throw std::runtime_error("Motion self-test failed: " + error);
    size_t checked = 0, correct = 0;
    for (size_t y = 8; y + 8 < height; ++y) for (size_t x = 12; x + 8 < width; ++x) {
        size_t i = y * width + x;
        if (!result.valid[i]) continue;
        ++checked;
        correct += std::abs(result.xy[i * 2] + float(shift)) < .25f &&
                   std::abs(result.xy[i * 2 + 1]) < .25f;
    }
    if (checked < 256 || correct * 10 < checked * 9)
        throw std::runtime_error("Motion self-test did not recover the known current-to-previous translation");
}

} // namespace

int main() {
    @autoreleasepool {
        try {
            if (@available(macOS 13.0, *)) {
                id<MTLDevice> device = MTLCreateSystemDefaultDevice();
                if (!device || ![MTLFXTemporalScalerDescriptor supportsDevice:device] ||
                    !MH4U::TemporalProcessor::supports(device, 800, 480, 400, 240)) {
                    puts("{\"supported\":false,\"reason\":\"MetalFX temporal scaling unavailable\"}");
                    return 77;
                }
                id<MTLCommandQueue> queue = [device newCommandQueue];
                if (!queue) throw std::runtime_error("Metal command queue creation failed");
                motionSelfTest(device, queue);
                MH4U::temporalProcessorSelfTest(device, queue);
                printf("{\"supported\":true,\"passed\":true,\"motion_estimator\":true,"
                       "\"temporal_processor\":true,\"internal_scales\":[1,2,3,4],"
                       "\"frame_generation\":\"experimental_optical_motion_fail_closed\","
                       "\"device\":\"%s\"}\n", device.name.UTF8String);
                return 0;
            }
            puts("{\"supported\":false,\"reason\":\"requires macOS 13\"}");
            return 77;
        } catch (const std::exception& error) {
            fprintf(stderr, "temporal-runtime-probe: %s\n", error.what());
            return 1;
        }
    }
}
