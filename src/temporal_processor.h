#pragma once

#import <Metal/Metal.h>

#include <cstddef>
#include <cstdint>
#include <memory>

namespace MH4U {

class TemporalProcessor {
public:
    static constexpr size_t inputWidth = 400;
    static constexpr size_t inputHeight = 240;

    static bool supports(id<MTLDevice> device, size_t outputWidth, size_t outputHeight,
                         size_t inputWidth = 400, size_t inputHeight = 240);

    TemporalProcessor(id<MTLDevice> device, id<MTLCommandQueue> queue,
                      size_t outputWidth, size_t outputHeight,
                      size_t inputWidth = 400, size_t inputHeight = 240);
    ~TemporalProcessor();
    TemporalProcessor(TemporalProcessor&&) noexcept;
    TemporalProcessor& operator=(TemporalProcessor&&) noexcept;
    TemporalProcessor(const TemporalProcessor&) = delete;
    TemporalProcessor& operator=(const TemporalProcessor&) = delete;

    // Color is display-referred BGRA8. Auto exposure is used; no pre-exposure is assumed.
    // Motion is RG32 float in input pixels and points from current to previous.
    id<MTLTexture> process(const uint8_t *bgra, size_t colorBytesPerRow,
                           const float *depth, size_t depthBytesPerRow,
                           const float *motion, size_t motionBytesPerRow,
                           bool depthReversed, bool reset,
                           const uint8_t *motionValid = nullptr);

    id<MTLTexture> previousTexture() const;
    id<MTLTexture> currentTexture() const;
    id<MTLTexture> motionTexture() const;
    bool hasHistory() const;

    // Experimental midpoint frame based only on caller-supplied current-to-previous motion.
    // Returns nil until two consecutive temporal outputs exist or after a reset.
    id<MTLTexture> interpolateEstimatedMotion();

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

// Runs real MetalFX work and throws on failure or a failed output/reset check.
void temporalProcessorSelfTest(id<MTLDevice> device, id<MTLCommandQueue> queue);

} // namespace MH4U
