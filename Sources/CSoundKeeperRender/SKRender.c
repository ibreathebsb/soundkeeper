#include "SKRender.h"

#include <math.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

// ---------------------------------------------------------------------------------------------------------------------
// Signal generator.
// ---------------------------------------------------------------------------------------------------------------------

#define SK_TWO_PI 6.283185307179586476925286766559

// The smallest deviations from zero that survive conversion of 32-bit float samples to integer PCM.
// The values are slightly bigger than exactly one step, so they survive converters that scale by 2^N-1 as well.
// 0x38000100 = 3.051851E-5 = 1.0/32767.
// 0x34000001 = 1.192093E-7 = 1.0/8388607.
#define SK_STEP_16BIT 0x38000100u
#define SK_STEP_24BIT 0x34000001u

#define SK_MAX_FRAMES 4000000000000000000ull

static inline float SKFloatFromBits(uint32_t bits)
{
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static uint64_t SKFramesFromSeconds(double seconds, double sampleRate)
{
    double frames = seconds * sampleRate;
    if (!(frames >= 1.0)) { return 0; } // Also rejects NaN and negative values.
    if (frames >= (double)SK_MAX_FRAMES) { return SK_MAX_FRAMES; }
    return (uint64_t)frames;
}

void SKSignalInit(SKSignal* signal, const SKSignalConfig* config)
{
    memset(signal, 0, sizeof(*signal));
    signal->config = *config;

    SKSignalConfig* c = &signal->config;
    if (!(c->sampleRate > 0.0)) { c->sampleRate = 48000.0; }
    if (!(c->frequency > 0.0)) { c->frequency = 0.0; }
    if (!(c->amplitude > 0.0)) { c->amplitude = 0.0; }
    if (c->amplitude > 1.0) { c->amplitude = 1.0; }

    uint64_t playFrames = SKFramesFromSeconds(c->playSeconds, c->sampleRate);
    uint64_t waitFrames = SKFramesFromSeconds(c->waitSeconds, c->sampleRate);
    uint64_t fadeFrames = SKFramesFromSeconds(c->fadeSeconds, c->sampleRate);

    if (!waitFrames && !fadeFrames)
    {
        // Nothing separates one sound from another, so it's just a continuous sound.
        playFrames = 0;
    }
    else if (!playFrames)
    {
        waitFrames = 0;
    }

    if (playFrames && fadeFrames > playFrames / 2)
    {
        fadeFrames = playFrames / 2;
    }

    signal->playFrames = playFrames;
    signal->waitFrames = waitFrames;
    signal->fadeFrames = fadeFrames;
    signal->periodFrames = playFrames + waitFrames;

    if (c->frequency > 0.0)
    {
        double interval = c->sampleRate / c->frequency;
        if (interval < 2.0) { signal->fluctuateInterval = 2; }
        else if (interval >= (double)SK_MAX_FRAMES) { signal->fluctuateInterval = SK_MAX_FRAMES; }
        else { signal->fluctuateInterval = (uint64_t)interval; }

        // The frequency is limited by half of the sample rate to avoid generation of unexpected noise.
        signal->thetaIncrement = (fmin(c->frequency, c->sampleRate / 2.0) * SK_TWO_PI) / c->sampleRate;
    }

    signal->lcg = c->seed;
}

// Volume of the sound at the specified frame of the period: fade in, full volume, fade out, silence.
static inline double SKSignalEnvelope(const SKSignal* signal, uint64_t frame)
{
    if (signal->periodFrames || frame < signal->fadeFrames)
    {
        if (frame < signal->fadeFrames)
        {
            double volume = (double)frame / (double)signal->fadeFrames;
            return volume * volume;
        }
        else if (!signal->playFrames || frame < (signal->playFrames - signal->fadeFrames))
        {
            return 1.0;
        }
        else if (frame < signal->playFrames)
        {
            double volume = (double)(signal->playFrames - frame) / (double)signal->fadeFrames;
            return volume * volume;
        }
        else
        {
            return 0.0;
        }
    }

    return 1.0;
}

static inline void SKSignalAdvance(SKSignal* signal)
{
    signal->frame++;
    if (signal->periodFrames && signal->frame >= signal->periodFrames) { signal->frame = 0; }
}

// Zeroes with the smallest non-zero sample once in `fluctuateInterval` frames, the sign is flipped each time.
// The buffer is cleared and then just a few samples are set, so it's nearly free even for big buffers.
static void SKSignalRenderFluctuate(SKSignal* signal, float* out, uint32_t frames, uint32_t channels)
{
    const uint64_t interval = signal->fluctuateInterval;
    const uint64_t period = signal->periodFrames;
    const float step = SKFloatFromBits(signal->config.use16BitStep ? SK_STEP_16BIT : SK_STEP_24BIT);

    memset(out, 0, (size_t)frames * channels * sizeof(float));

    uint64_t current = signal->frame;
    uint32_t done = 0;

    while (done < frames)
    {
        // A segment that doesn't cross the end of the period.
        uint32_t segment = frames - done;
        if (period && (period - current) < segment) { segment = (uint32_t)(period - current); }

        uint64_t end = current + segment;
        uint64_t limit = (period && signal->playFrames < end) ? signal->playFrames : end;

        uint64_t remainder = current % interval;
        for (uint64_t k = remainder ? current + (interval - remainder) : current; k < limit; k += interval)
        {
            float sample = ((k / interval) & 1) ? -step : step;
            float* frame = out + (size_t)(done + (k - current)) * channels;
            for (uint32_t ch = 0; ch < channels; ch++) { frame[ch] = sample; }
        }

        current = (period && end >= period) ? 0 : end;
        done += segment;
    }

    signal->frame = current;
}

static inline double SKSignalNextWhite(SKSignal* signal)
{
    signal->lcg = signal->lcg * 6364136223846793005ull + 1; // LCG from Musl.
    return ((double)((signal->lcg >> 32) & 0x7FFFFFFFu) / (double)0x7FFFFFFFu) * 2.0 - 1.0; // -1 .. 1
}

static inline double SKSignalNextBrown(SKSignal* signal)
{
    // Brown Noise from SoX + a leaky integrator to reduce low frequency humming.
    signal->brown += SKSignalNextWhite(signal) * (1.0 / 16);
    signal->brown /= 1.02; // The leaky integrator.
    signal->brown = fmod(signal->brown, 4);
    double value = signal->brown;

    // Normalize values out of the -1..1 range using "mirroring".
    // Example: 0.8, 0.9, 1.0, 0.9, 0.8, ..., -0.8, -0.9, -1.0, -0.9, -0.8, ...
    // Precondition: value must be between -4.0 and 4.0.
    if (value < -1.0 || 1.0 < value)
    {
        double sign = (value < 0.0) ? -1.0 : 1.0;
        value = fabs(value);
        value = ((value <= 3.0) ? (2.0 - value) : (value - 4.0)) * sign;
    }

    return value;
}

static inline double SKSignalNextPink(SKSignal* signal)
{
    // Paul Kellet's method.
    double white = SKSignalNextWhite(signal);
    double* b = signal->pink;
    b[0] = 0.99886 * b[0] + white * 0.0555179;
    b[1] = 0.99332 * b[1] + white * 0.0750759;
    b[2] = 0.96900 * b[2] + white * 0.1538520;
    b[3] = 0.86650 * b[3] + white * 0.3104856;
    b[4] = 0.55000 * b[4] + white * 0.5329522;
    b[5] = -0.7616 * b[5] - white * 0.0168980;
    double value = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + white * 0.5362;
    value *= 0.11; // (roughly) compensate for gain.
    b[6] = white * 0.115926;
    return value;
}

void SKSignalRender(SKSignal* signal, float* out, uint32_t frames, uint32_t channels)
{
    if (frames == 0 || channels == 0) { return; }

    const SKSignalConfig* c = &signal->config;
    const size_t bytes = (size_t)frames * channels * sizeof(float);

    bool hasSound;
    switch (c->type)
    {
        case SKStreamTypeFluctuate:
            hasSound = signal->fluctuateInterval != 0;
            break;
        case SKStreamTypeSine:
            hasSound = c->frequency > 0.0 && c->amplitude > 0.0;
            break;
        case SKStreamTypeWhiteNoise:
        case SKStreamTypeBrownNoise:
        case SKStreamTypePinkNoise:
            hasSound = c->amplitude > 0.0;
            break;
        default:
            hasSound = false;
            break;
    }

    if (!hasSound)
    {
        memset(out, 0, bytes);
        return;
    }

    const uint64_t period = signal->periodFrames;

    if (period && signal->playFrames <= signal->frame && (signal->frame + frames) <= period)
    {
        // Just silence whole time.
        memset(out, 0, bytes);
        signal->frame = (signal->frame + frames) % period;
        return;
    }

    if (c->type == SKStreamTypeFluctuate)
    {
        SKSignalRenderFluctuate(signal, out, frames, channels);
        return;
    }

    for (uint32_t i = 0; i < frames; i++)
    {
        double amplitude = c->amplitude * SKSignalEnvelope(signal, signal->frame);
        float sample = 0;

        if (amplitude != 0.0)
        {
            double value;

            switch (c->type)
            {
                case SKStreamTypeSine:
                    value = sin(signal->theta);
                    signal->theta += signal->thetaIncrement;
                    if (signal->theta >= SK_TWO_PI) { signal->theta -= SK_TWO_PI; }
                    break;
                case SKStreamTypeBrownNoise:
                    value = SKSignalNextBrown(signal);
                    break;
                case SKStreamTypePinkNoise:
                    value = SKSignalNextPink(signal);
                    break;
                default:
                    value = SKSignalNextWhite(signal);
                    break;
            }

            value *= amplitude;
            if (!(value >= -1.0)) { value = -1.0; } // Also catches NaN.
            if (value > 1.0) { value = 1.0; }
            sample = (float)value;
        }

        float* frame = out + (size_t)i * channels;
        for (uint32_t ch = 0; ch < channels; ch++) { frame[ch] = sample; }

        SKSignalAdvance(signal);
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// Render context.
// ---------------------------------------------------------------------------------------------------------------------

struct SKRenderContext {
    _Atomic bool armed;
    _Atomic uint64_t callbackCount;
    _Atomic uint64_t frameCount;
    _Atomic uint64_t mismatchCount;
    SKSignal signal;
    uint32_t streamCount;
    SKStreamLayout streams[];
};

SKRenderContext* SKRenderContextCreate(const SKSignalConfig* config, const SKStreamLayout* streams, uint32_t streamCount)
{
    if (streams == NULL) { streamCount = 0; }

    SKRenderContext* context = calloc(1, sizeof(SKRenderContext) + (size_t)streamCount * sizeof(SKStreamLayout));
    if (context == NULL) { return NULL; }

    SKSignalInit(&context->signal, config);
    context->streamCount = streamCount;
    if (streamCount) { memcpy(context->streams, streams, (size_t)streamCount * sizeof(SKStreamLayout)); }
    atomic_init(&context->armed, true);

    return context;
}

void SKRenderContextDestroy(SKRenderContext* context)
{
    free(context);
}

void SKRenderContextSetArmed(SKRenderContext* context, bool armed)
{
    atomic_store_explicit(&context->armed, armed, memory_order_relaxed);
}

uint64_t SKRenderContextGetCallbackCount(const SKRenderContext* context)
{
    return atomic_load_explicit(&context->callbackCount, memory_order_relaxed);
}

uint64_t SKRenderContextGetFrameCount(const SKRenderContext* context)
{
    return atomic_load_explicit(&context->frameCount, memory_order_relaxed);
}

uint64_t SKRenderContextGetMismatchCount(const SKRenderContext* context)
{
    return atomic_load_explicit(&context->mismatchCount, memory_order_relaxed);
}

// Runs on the real-time IO thread: no allocations, no locks, no system calls.
//
// The device has one AudioBuffer per output stream. Samples are written only into buffers that look exactly like
// the float streams found when the session was opened. Anything unexpected gets zeroes, which are harmless in any
// PCM format, while float bit patterns written into an integer or encoded stream would be a loud noise.
void SKRenderContextRender(SKRenderContext* context, AudioBufferList* output)
{
    const UInt32 bufferCount = output->mNumberBuffers;

    bool mismatch = false;
    bool usable = context->signal.config.type > SKStreamTypeZero && atomic_load_explicit(&context->armed, memory_order_relaxed);
    if (usable && bufferCount != context->streamCount)
    {
        usable = false;
        mismatch = true;
    }

    const float* source = NULL;
    uint32_t sourceChannels = 0;
    uint32_t frames = 0;

    for (UInt32 i = 0; i < bufferCount; i++)
    {
        AudioBuffer* buffer = &output->mBuffers[i];
        if (buffer->mData == NULL || buffer->mDataByteSize == 0) { continue; }

        const uint32_t channels = buffer->mNumberChannels;
        const uint32_t frameSize = channels * (uint32_t)sizeof(float);
        bool writable = false;

        if (usable && context->streams[i].writable)
        {
            if (channels != 0 && channels == context->streams[i].channels && (buffer->mDataByteSize % frameSize) == 0)
            {
                writable = true;
            }
            else
            {
                mismatch = true;
            }
        }

        if (!writable)
        {
            memset(buffer->mData, 0, buffer->mDataByteSize);
            if (frames == 0 && frameSize != 0) { frames = buffer->mDataByteSize / frameSize; }
            continue;
        }

        float* samples = (float*)buffer->mData;
        const uint32_t bufferFrames = buffer->mDataByteSize / frameSize;

        if (source == NULL)
        {
            SKSignalRender(&context->signal, samples, bufferFrames, channels);
            source = samples;
            sourceChannels = channels;
            frames = bufferFrames;
        }
        else if (bufferFrames == frames)
        {
            // Other streams of the device get a copy of the same signal.
            for (uint32_t f = 0; f < frames; f++)
            {
                const float sample = source[(size_t)f * sourceChannels];
                float* frame = samples + (size_t)f * channels;
                for (uint32_t ch = 0; ch < channels; ch++) { frame[ch] = sample; }
            }
        }
        else
        {
            memset(buffer->mData, 0, buffer->mDataByteSize);
            mismatch = true;
        }
    }

    if (mismatch) { atomic_fetch_add_explicit(&context->mismatchCount, 1, memory_order_relaxed); }
    atomic_fetch_add_explicit(&context->frameCount, frames, memory_order_relaxed);
    atomic_fetch_add_explicit(&context->callbackCount, 1, memory_order_relaxed);
}

static OSStatus SKRenderIOProc(
    AudioObjectID inDevice,
    const AudioTimeStamp* inNow,
    const AudioBufferList* inInputData,
    const AudioTimeStamp* inInputTime,
    AudioBufferList* outOutputData,
    const AudioTimeStamp* inOutputTime,
    void* inClientData)
{
    (void)inDevice; (void)inNow; (void)inInputData; (void)inInputTime; (void)inOutputTime;

    if (inClientData != NULL && outOutputData != NULL)
    {
        SKRenderContextRender((SKRenderContext*)inClientData, outOutputData);
    }

    return noErr;
}

OSStatus SKRenderContextCreateIOProc(SKRenderContext* context, AudioObjectID device, AudioDeviceIOProcID* outProcID)
{
    return AudioDeviceCreateIOProcID(device, SKRenderIOProc, context, outProcID);
}

OSStatus SKDisableInputStreams(AudioObjectID device, AudioDeviceIOProcID procID)
{
    AudioObjectPropertyAddress streamsAddress = { kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, NULL, &size);
    if (status != noErr) { return status; }

    const UInt32 streamCount = size / (UInt32)sizeof(AudioStreamID);
    if (streamCount == 0) { return noErr; }

    size_t usageSize = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + (size_t)streamCount * sizeof(UInt32);
    if (usageSize < sizeof(AudioHardwareIOProcStreamUsage)) { usageSize = sizeof(AudioHardwareIOProcStreamUsage); }

    // All mStreamIsOn flags are left zeroed: the IOProc uses none of the input streams.
    AudioHardwareIOProcStreamUsage* usage = calloc(1, usageSize);
    if (usage == NULL) { return kAudio_MemFullError; }
    usage->mIOProc = (void*)procID;
    usage->mNumberStreams = streamCount;

    AudioObjectPropertyAddress usageAddress = { kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain };
    status = AudioObjectSetPropertyData(device, &usageAddress, 0, NULL, (UInt32)usageSize, usage);
    free(usage);

    return status;
}
