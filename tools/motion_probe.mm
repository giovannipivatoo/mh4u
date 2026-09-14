#include "motion_estimator.h"
#import <Metal/Metal.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <vector>

static std::vector<uint8_t> scene(size_t width, size_t height, int offsetX, int offsetY,
                                  int objectX = 0, int objectY = 0) {
    std::vector<uint8_t> pixels(width * height * 4);
    for (size_t y = 0; y < height; ++y) for (size_t x = 0; x < width; ++x) {
        const int sx = int(x) - offsetX, sy = int(y) - offsetY;
        const size_t i = (y * width + x) * 4;
        pixels[i] = uint8_t((sx * 37 + sy * 17 + ((sx / 7) ^ (sy / 5)) * 29) & 255);
        pixels[i + 1] = uint8_t((sx * 11 - sy * 31 + ((sx / 9) ^ (sy / 6)) * 47) & 255);
        pixels[i + 2] = uint8_t((sx * 23 + sy * 13 + ((sx / 4) ^ (sy / 11)) * 19) & 255);
        pixels[i + 3] = 255;
    }
    const int left = 80 + offsetX + objectX, top = 65 + offsetY + objectY;
    for (int y = std::max(0, top); y < std::min(int(height), top + 45); ++y)
        for (int x = std::max(0, left); x < std::min(int(width), left + 55); ++x) {
            const size_t i = (size_t(y) * width + size_t(x)) * 4;
            const int ox = x - left, oy = y - top;
            uint32_t hash = uint32_t(ox * 73856093) ^ uint32_t(oy * 19349663);
            hash ^= hash >> 13; hash *= 1274126177u;
            pixels[i] = uint8_t(hash);
            pixels[i + 1] = uint8_t(hash >> 8);
            pixels[i + 2] = uint8_t(hash >> 16);
        }
    return pixels;
}

static std::vector<uint8_t> scaledScene(size_t scale, int offsetX, int offsetY) {
    auto logical = scene(400, 240, offsetX, offsetY);
    std::vector<uint8_t> pixels(400 * scale * 240 * scale * 4);
    for (size_t y = 0; y < 240 * scale; ++y)
        for (size_t x = 0; x < 400 * scale; ++x)
            std::copy_n(logical.data() + (y / scale * 400 + x / scale) * 4, 4,
                        pixels.data() + (y * 400 * scale + x) * 4);
    return pixels;
}

static std::pair<double, double> medianRegion(const MotionEstimator::Result &result, size_t width,
                                              size_t left, size_t top, size_t right, size_t bottom) {
    std::vector<float> xs, ys;
    for (size_t y = top; y < bottom; ++y) for (size_t x = left; x < right; ++x) {
        xs.push_back(result.xy[(y * width + x) * 2]);
        ys.push_back(result.xy[(y * width + x) * 2 + 1]);
    }
    auto median=[](std::vector<float>& v){auto m=v.begin()+v.size()/2;std::nth_element(v.begin(),m,v.end());return double(*m);};
    return {median(xs),median(ys)};
}

static std::pair<double, double> medianInterior(const MotionEstimator::Result &result,
                                                size_t width, size_t height) {
    std::vector<float> xs, ys;
    for (size_t y = 24; y + 24 < height; ++y) for (size_t x = 24; x + 24 < width; ++x) {
        xs.push_back(result.xy[(y * width + x) * 2]);
        ys.push_back(result.xy[(y * width + x) * 2 + 1]);
    }
    auto median = [](std::vector<float> &values) {
        auto middle = values.begin() + values.size() / 2;
        std::nth_element(values.begin(), middle, values.end());
        return double(*middle);
    };
    return {median(xs), median(ys)};
}

int main() {
    constexpr size_t width = 400, height = 240;
    try {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (!device || !queue) throw std::runtime_error("Metal unavailable");
        auto previous = scene(width, height, 0, 0);
        auto current = scene(width, height, 4, -3, 4, 3);
        auto identical = current;
        for (int iteration = 0; iteration < 4; ++iteration) {
            MotionEstimator::Result moved, still;
            std::string error;
            if (!MotionEstimator::estimateCurrentToPrevious(previous.data(), width * 4,
                    current.data(), width * 4, width, height, device, queue, moved, error))
                throw std::runtime_error(error);
            if (!MotionEstimator::estimateCurrentToPrevious(identical.data(), width * 4,
                    current.data(), width * 4, width, height, device, queue, still, error))
                throw std::runtime_error(error);
            const auto [dx, dy] = medianInterior(moved, width, height);
            const auto [objectDX, objectDY] = medianRegion(moved, width, 94, 71, 122, 96);
            const auto [borderDX, borderDY] = medianRegion(moved, width, 8, 8, 16, 16);
            const auto [stillX, stillY] = medianInterior(still, width, height);
            // Current content is shifted (+4,-3), so current -> previous is (-4,+3).
            if (std::abs(dx + 4) > 1.5 || std::abs(dy - 3) > 1.5)
                throw std::runtime_error("translation sign or magnitude mismatch: " +
                                         std::to_string(dx) + "," + std::to_string(dy));
            if (std::abs(objectDX + 8) > .75 || std::abs(objectDY) > .75)
                throw std::runtime_error("foreground motion mismatch: " +
                                         std::to_string(objectDX) + "," + std::to_string(objectDY));
            if (std::abs(borderDX + 4) > .75 || std::abs(borderDY - 3) > .75)
                throw std::runtime_error("border motion mismatch: " +
                                         std::to_string(borderDX) + "," + std::to_string(borderDY));
            if (std::hypot(stillX, stillY) > .25)
                throw std::runtime_error("identity flow was not near zero");
            std::vector<uint8_t> uniform(width * height * 4, 127);
            MotionEstimator::Result ambiguous;
            if (!MotionEstimator::estimateCurrentToPrevious(uniform.data(), width * 4,
                    uniform.data(), width * 4, width, height, device, queue, ambiguous, error))
                throw std::runtime_error(error);
            const auto [uniformX, uniformY] = medianInterior(ambiguous, width, height);
            if (std::hypot(uniformX, uniformY) > .1 || ambiguous.validFraction != 0)
                throw std::runtime_error("uniform ambiguity was reported as measured motion");
            MotionEstimator::Result invalid;
            if (MotionEstimator::estimateCurrentToPrevious(previous.data(), width * 4,
                    current.data(), width * 4, 0, height, device, queue, invalid, error))
                throw std::runtime_error("invalid size was accepted");
            if (MotionEstimator::estimateCurrentToPrevious(previous.data(), 4,
                    current.data(), 4, size_t(UINT32_MAX) + 1, 1,
                    device, queue, invalid, error))
                throw std::runtime_error("out-of-range size was accepted");
            auto small = scene(160, 96, 0, 0);
            MotionEstimator::Result resized;
            if (!MotionEstimator::estimateCurrentToPrevious(small.data(), 160 * 4,
                    small.data(), 160 * 4, 160, 96, device, queue, resized, error) ||
                resized.xy.size() != 160 * 96 * 2)
                throw std::runtime_error("independent resized request failed: " + error);
            uint8_t pixel[4] = {0, 0, 0, 255};
            MotionEstimator::Result tiny;
            if (!MotionEstimator::estimateCurrentToPrevious(pixel, 4, pixel, 4, 1, 1,
                    device, queue, tiny, error) || tiny.xy.size() != 2 || tiny.xy[0] != 0 ||
                tiny.xy[1] != 0 || tiny.valid.size() != 1 || tiny.valid[0] != 0)
                throw std::runtime_error("tiny ambiguous request was not initialized safely");
            printf("{\"iteration\":%d,\"dx\":%.3f,\"dy\":%.3f,\"object_dx\":%.3f,\"object_dy\":%.3f,"
                   "\"border_dx\":%.3f,\"border_dy\":%.3f,\"valid_fraction\":%.3f,\"uniform_valid_fraction\":%.3f,"
                   "\"identity_dx\":%.3f,\"identity_dy\":%.3f,"
                   "\"mean_magnitude\":%.3f,\"max_magnitude\":%.3f,"
                   "\"color_difference\":%.6f,\"milliseconds\":%.3f}\n",
                   iteration, dx, dy, objectDX, objectDY, borderDX, borderDY,
                   moved.validFraction, ambiguous.validFraction, stillX, stillY,
                   moved.meanMagnitude, moved.maxMagnitude,
                   moved.meanAbsoluteColorDifference, moved.elapsedMilliseconds);
        }
        for (size_t scale = 2; scale <= 4; ++scale) {
            const size_t scaledWidth = width * scale, scaledHeight = height * scale;
            auto previousScaled = scaledScene(scale, 0, 0);
            auto currentScaled = scaledScene(scale, 4, -3);
            MotionEstimator::Result moved, identity;
            std::string error;
            if (!MotionEstimator::estimateCurrentToPrevious(previousScaled.data(), scaledWidth * 4,
                    currentScaled.data(), scaledWidth * 4, scaledWidth, scaledHeight,
                    device, queue, moved, error) ||
                !MotionEstimator::estimateCurrentToPrevious(currentScaled.data(), scaledWidth * 4,
                    currentScaled.data(), scaledWidth * 4, scaledWidth, scaledHeight,
                    device, queue, identity, error))
                throw std::runtime_error("scaled estimate failed: " + error);
            const auto [dx, dy] = medianInterior(moved, scaledWidth, scaledHeight);
            const auto [borderDX, borderDY] = medianRegion(moved, scaledWidth,
                    8 * scale, 8 * scale, 16 * scale, 16 * scale);
            const auto [identityX, identityY] = medianInterior(identity, scaledWidth, scaledHeight);
            if (moved.xy.size() != scaledWidth * scaledHeight * 2 ||
                moved.valid.size() != scaledWidth * scaledHeight ||
                std::abs(dx + 4 * double(scale)) > 1.0 ||
                std::abs(dy - 3 * double(scale)) > 1.0 ||
                std::abs(borderDX + 4 * double(scale)) > 1.0 ||
                std::abs(borderDY - 3 * double(scale)) > 1.0)
                throw std::runtime_error("scaled translation or border mismatch at " +
                                         std::to_string(scale) + "x: " +
                                         std::to_string(dx) + "," + std::to_string(dy));
            if (std::hypot(identityX, identityY) > .1 || identity.validFraction <= 0 ||
                moved.elapsedMilliseconds <= 0 || identity.elapsedMilliseconds <= 0)
                throw std::runtime_error("scaled identity mask or timing failed at " +
                                         std::to_string(scale) + "x");
            printf("{\"scale\":%zu,\"width\":%zu,\"height\":%zu,\"dx\":%.3f,\"dy\":%.3f,"
                   "\"border_dx\":%.3f,\"border_dy\":%.3f,\"valid_fraction\":%.3f,"
                   "\"identity_valid_fraction\":%.3f,\"milliseconds\":%.3f}\n",
                   scale, scaledWidth, scaledHeight, dx, dy, borderDX, borderDY,
                   moved.validFraction, identity.validFraction, moved.elapsedMilliseconds);
        }
        return 0;
    } catch (const std::exception &exception) {
        fprintf(stderr, "motion-probe: %s\n", exception.what());
        return 1;
    }
}
