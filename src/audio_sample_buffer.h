#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <deque>

namespace MH4U {

inline constexpr size_t maxQueuedAudioFrames = 2048;
inline constexpr size_t audioRebufferFrames = 1024;
inline constexpr size_t audioFadeFrames = 64;

struct AudioSampleBuffer {
    void clear() {
        samples.clear();
        lastOutput = fadeStart = {};
        fadeStep = audioFadeFrames;
        rebuffering = true;
        transitionPending = false;
        hasPlayed = false;
    }

    size_t size() const { return samples.size(); }
    size_t queuedFrames() const { return samples.size() / 2; }

    std::deque<int16_t> samples;
    std::array<int16_t, 2> lastOutput{};
    std::array<int16_t, 2> fadeStart{};
    size_t fadeStep = audioFadeFrames;
    bool rebuffering = true;
    bool transitionPending = false;
    bool hasPlayed = false;
};

struct AudioEnqueueResult {
    size_t droppedFrames = 0;
    size_t queuedFrames = 0;
};

struct AudioDequeueResult {
    size_t sourceFrames = 0;
    size_t underrunFrames = 0;
    bool underrunStarted = false;
    bool recoveryStarted = false;
};

inline int16_t blendAudioSample(int16_t from, int16_t to, size_t step) {
    const int32_t value = int32_t(from) * int32_t(audioFadeFrames - step) + int32_t(to) * int32_t(step);
    return static_cast<int16_t>(value / int32_t(audioFadeFrames));
}

inline AudioEnqueueResult enqueueStereo(AudioSampleBuffer& buffer, const int16_t *data, size_t frames) {
    AudioEnqueueResult result{0, buffer.queuedFrames()};
    if (!data || !frames) return result;
    const size_t keptFrames = std::min(frames, maxQueuedAudioFrames);
    const size_t queuedFrames = buffer.queuedFrames();
    const size_t retainedQueuedFrames = std::min(queuedFrames, maxQueuedAudioFrames - keptFrames);
    const size_t droppedQueuedFrames = queuedFrames - retainedQueuedFrames;
    buffer.samples.erase(buffer.samples.begin(), buffer.samples.begin() + droppedQueuedFrames * 2);
    data += (frames - keptFrames) * 2;
    buffer.samples.insert(buffer.samples.end(), data, data + keptFrames * 2);
    result.droppedFrames = droppedQueuedFrames + (frames - keptFrames);
    result.queuedFrames = buffer.queuedFrames();
    if (result.droppedFrames && !buffer.rebuffering) buffer.transitionPending = true;
    return result;
}

inline AudioDequeueResult dequeueStereo(AudioSampleBuffer& buffer, int16_t *output, size_t frames) {
    AudioDequeueResult result;
    if (!output || !frames) return result;
    auto writeFadeToSilence = [&](size_t frame) {
        const size_t step = std::min(buffer.fadeStep + 1, audioFadeFrames);
        for (size_t channel = 0; channel < 2; ++channel) {
            const int16_t value = blendAudioSample(buffer.fadeStart[channel], 0, step);
            output[frame * 2 + channel] = value;
            buffer.lastOutput[channel] = value;
        }
        buffer.fadeStep = step;
    };

    if (buffer.rebuffering) {
        if (buffer.queuedFrames() < audioRebufferFrames) {
            for (size_t frame = 0; frame < frames; ++frame) writeFadeToSilence(frame);
            result.underrunFrames = frames;
            return result;
        }
        result.recoveryStarted = buffer.hasPlayed;
        buffer.rebuffering = false;
        buffer.fadeStart = buffer.lastOutput;
        buffer.fadeStep = 0;
        buffer.transitionPending = false;
    } else if (buffer.transitionPending) {
        buffer.fadeStart = buffer.lastOutput;
        buffer.fadeStep = 0;
        buffer.transitionPending = false;
    }

    for (size_t frame = 0; frame < frames; ++frame) {
        if (buffer.samples.size() >= 2) {
            const std::array<int16_t, 2> source{buffer.samples.front(), buffer.samples[1]};
            buffer.samples.pop_front(); buffer.samples.pop_front();
            const size_t step = std::min(buffer.fadeStep + 1, audioFadeFrames);
            for (size_t channel = 0; channel < 2; ++channel) {
                const int16_t value = buffer.fadeStep < audioFadeFrames
                    ? blendAudioSample(buffer.fadeStart[channel], source[channel], step) : source[channel];
                output[frame * 2 + channel] = value;
                buffer.lastOutput[channel] = value;
            }
            buffer.fadeStep = step;
            buffer.hasPlayed = true;
            ++result.sourceFrames;
            continue;
        }

        if (!buffer.rebuffering) {
            buffer.rebuffering = true;
            buffer.fadeStart = buffer.lastOutput;
            buffer.fadeStep = 0;
            result.underrunStarted = buffer.hasPlayed;
        }
        writeFadeToSilence(frame);
        ++result.underrunFrames;
    }
    return result;
}

} // namespace MH4U
