#include "audio_sample_buffer.h"

#include <algorithm>
#include <array>
#include <cstdlib>
#include <cstdio>
#include <stdexcept>
#include <vector>

static void require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}

int main() {
    auto constantStereo = [](size_t frames, int16_t left) {
        std::vector<int16_t> data(frames * 2);
        for (size_t frame = 0; frame < frames; ++frame) {
            data[frame * 2] = left; data[frame * 2 + 1] = -left;
        }
        return data;
    };
    auto requireSmoothStereo = [](const std::vector<int16_t>& data, int16_t previous, int maxStep) {
        for (size_t frame = 0; frame < data.size() / 2; ++frame) {
            require(data[frame * 2 + 1] == -data[frame * 2], "stereo channels diverged");
            require(std::abs(int(data[frame * 2]) - int(previous)) <= maxStep, "waveform transition clicked");
            previous = data[frame * 2];
        }
    };
    auto requireBoundedStereoTransition = [](const std::vector<int16_t>& data,
                                              std::array<int16_t, 2> previous, int maxStep) {
        for (size_t frame = 0; frame < data.size() / 2; ++frame) {
            for (size_t channel = 0; channel < 2; ++channel) {
                require(std::abs(int(data[frame * 2 + channel]) - int(previous[channel])) <= maxStep,
                    "full-amplitude transition clicked");
                previous[channel] = data[frame * 2 + channel];
            }
            require(std::abs(int(data[frame * 2]) + int(data[frame * 2 + 1])) <= 1,
                "full-amplitude stereo channels diverged");
        }
    };

    MH4U::AudioSampleBuffer buffer;
    auto positive = constantStereo(MH4U::audioRebufferFrames, 20000);
    auto enqueued = MH4U::enqueueStereo(buffer, positive.data(), positive.size() / 2);
    require(enqueued.droppedFrames == 0 && enqueued.queuedFrames == MH4U::audioRebufferFrames,
        "initial burst was not retained");

    std::vector<int16_t> output(512 * 2);
    auto dequeued = MH4U::dequeueStereo(buffer, output.data(), 512);
    require(dequeued.sourceFrames == 512 && !dequeued.recoveryStarted, "initial rebuffer did not start cleanly");
    requireSmoothStereo(output, 0, 313);
    dequeued = MH4U::dequeueStereo(buffer, output.data(), 512);
    require(dequeued.sourceFrames == 512 && dequeued.underrunFrames == 0, "steady burst was truncated");

    dequeued = MH4U::dequeueStereo(buffer, output.data(), 512);
    require(dequeued.sourceFrames == 0 && dequeued.underrunFrames == 512 && dequeued.underrunStarted,
        "genuine starvation was not reported once");
    requireSmoothStereo(output, 20000, 313);
    require(output[output.size() - 2] == 0, "starvation did not fade to silence");
    dequeued = MH4U::dequeueStereo(buffer, output.data(), 512);
    require(!dequeued.underrunStarted, "continued starvation emitted duplicate events");

    auto halfRecovery = constantStereo(MH4U::audioRebufferFrames / 2, 20000);
    MH4U::enqueueStereo(buffer, halfRecovery.data(), halfRecovery.size() / 2);
    dequeued = MH4U::dequeueStereo(buffer, output.data(), 512);
    require(dequeued.sourceFrames == 0 && !dequeued.recoveryStarted && buffer.queuedFrames() == 512,
        "partial recovery restarted too early");
    require(std::all_of(output.begin(), output.end(), [](int16_t sample) { return sample == 0; }),
        "partial recovery was not silent");
    MH4U::enqueueStereo(buffer, halfRecovery.data(), halfRecovery.size() / 2);
    dequeued = MH4U::dequeueStereo(buffer, output.data(), 512);
    require(dequeued.sourceFrames == 512 && dequeued.recoveryStarted, "full rebuffer did not recover");
    requireSmoothStereo(output, 0, 313);

    MH4U::AudioSampleBuffer cadence;
    auto priming = constantStereo(MH4U::audioRebufferFrames, 1000);
    MH4U::enqueueStereo(cadence, priming.data(), priming.size() / 2);
    MH4U::dequeueStereo(cadence, output.data(), 512);
    size_t producerRemainder = 0, outputClock = 0;
    for (size_t tick = 0; tick < 600; ++tick) {
        producerRemainder += 32728;
        const size_t producedFrames = producerRemainder / 60;
        producerRemainder %= 60;
        auto produced = constantStereo(producedFrames, 1000);
        enqueued = MH4U::enqueueStereo(cadence, produced.data(), producedFrames);
        require(enqueued.droppedFrames == 0, "regular producer cadence overflowed");
        outputClock += 32728;
        while (outputClock >= 60 * 512) {
            outputClock -= 60 * 512;
            dequeued = MH4U::dequeueStereo(cadence, output.data(), 512);
            require(dequeued.sourceFrames == 512 && dequeued.underrunFrames == 0 &&
                !dequeued.underrunStarted && !dequeued.recoveryStarted,
                "regular producer cadence entered recovery");
        }
    }
    require(!cadence.rebuffering, "regular producer cadence remained stuck rebuffering");

    MH4U::AudioSampleBuffer overflow;
    std::vector<int16_t> negative(MH4U::audioRebufferFrames * 2);
    for (size_t frame = 0; frame < negative.size() / 2; ++frame) {
        negative[frame * 2] = INT16_MIN; negative[frame * 2 + 1] = INT16_MAX;
    }
    MH4U::enqueueStereo(overflow, negative.data(), negative.size() / 2);
    MH4U::dequeueStereo(overflow, output.data(), 512);
    std::vector<int16_t> newest(3000 * 2);
    for (size_t frame = 0; frame < newest.size() / 2; ++frame) {
        newest[frame * 2] = INT16_MAX; newest[frame * 2 + 1] = INT16_MIN;
    }
    enqueued = MH4U::enqueueStereo(overflow, newest.data(), newest.size() / 2);
    require(enqueued.droppedFrames == 1464 && enqueued.queuedFrames == MH4U::maxQueuedAudioFrames,
        "overflow accounting or bound is wrong");
    require(overflow.samples.front() == INT16_MAX && overflow.samples[1] == INT16_MIN,
        "overflow retained old audio instead of the newest burst");
    dequeued = MH4U::dequeueStereo(overflow, output.data(), 512);
    require(dequeued.sourceFrames == 512, "overflow recovery did not produce audio");
    requireBoundedStereoTransition(output, {INT16_MIN, INT16_MAX}, 1024);

    std::printf("{\"mode\":\"audio-buffer-probe\",\"passed\":true,\"max_queued_frames\":%zu,"
        "\"rebuffer_frames\":%zu,\"fade_frames\":%zu}\n", MH4U::maxQueuedAudioFrames,
        MH4U::audioRebufferFrames, MH4U::audioFadeFrames);
}
