#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#ifdef __OBJC__
@protocol MTLDevice;
@protocol MTLCommandQueue;
#endif

namespace MotionEstimator {

struct Result {
    // Estimated optical motion in pixels: current(x,y) -> previous(x+dx,y+dy).
    std::vector<float> xy;
    // One byte per pixel: 1 when the matched patch had usable texture and low residual.
    std::vector<uint8_t> valid;
    double validFraction = 0;
    double meanMagnitude = 0;
    double maxMagnitude = 0;
    double meanAbsoluteColorDifference = 0; // BGRA RGB channels, normalized to [0,1].
    double elapsedMilliseconds = 0;
};

// Metal performs estimated optical block matching synchronously. Rows use the
// supplied top-to-bottom BGRA order; output has width*height interleaved dx,dy floats.
// Integer 400x240 scales are box-filtered to a <=400x240 motion proxy; returned
// vectors and validity are expanded to the original dimensions. Color and depth
// inputs used by other runtime stages remain full resolution.
bool estimateCurrentToPrevious(const uint8_t *previousBGRA, size_t previousBytesPerRow,
                               const uint8_t *currentBGRA, size_t currentBytesPerRow,
                               size_t width, size_t height, id<MTLDevice> device,
                               id<MTLCommandQueue> queue,
                               Result &result, std::string &error);

} // namespace MotionEstimator
