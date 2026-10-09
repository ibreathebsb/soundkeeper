// Real-time part of Sound Keeper for macOS: the keep-alive signal generator and the CoreAudio IOProc.
//
// Everything that runs on the HAL IO thread lives in this C target, so that no Swift runtime code
// (reference counting, allocation, locks) can ever end up on the real-time thread.

#ifndef SK_RENDER_H
#define SK_RENDER_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang assume_nonnull begin

// ---------------------------------------------------------------------------------------------------------------------
// Signal generator. A port of CSoundSession::Render() from Sound Keeper for Windows.
// ---------------------------------------------------------------------------------------------------------------------

typedef CF_ENUM(int32_t, SKStreamType) {
    SKStreamTypeOpenOnly   = 0, // Nothing is rendered (the device is started without an IOProc).
    SKStreamTypeZero       = 1, // Stream of zeroes.
    SKStreamTypeFluctuate  = 2, // Zeroes with the smallest non-zero sample now and then.
    SKStreamTypeSine       = 3,
    SKStreamTypeWhiteNoise = 4,
    SKStreamTypeBrownNoise = 5,
    SKStreamTypePinkNoise  = 6,
};

typedef struct SKSignalConfig {
    SKStreamType type;
    double sampleRate;   // Hz.
    double frequency;    // Hz. Fluctuate: fluctuations per second. Sine: tone frequency.
    double amplitude;    // 0...1. Sine and noise.
    double playSeconds;  // Length of sound. 0 is infinite.
    double waitSeconds;  // Waiting time between sounds.
    double fadeSeconds;  // Fading time. Sine and noise.
    bool use16BitStep;   // Fluctuate: use the smallest step of 16-bit PCM instead of 24-bit PCM.
    uint64_t seed;       // Noise generator seed.
} SKSignalConfig;

typedef struct SKSignal {
    SKSignalConfig config;

    // Derived from the config.
    uint64_t playFrames;
    uint64_t waitFrames;
    uint64_t fadeFrames;
    uint64_t periodFrames;
    uint64_t fluctuateInterval;
    double thetaIncrement;

    // Current state.
    uint64_t frame;
    double theta;        // Sine.
    double brown;        // Brown noise.
    double pink[7];      // Pink noise.
    uint64_t lcg;        // White noise source.
} SKSignal;

void SKSignalInit(SKSignal* signal, const SKSignalConfig* config);

// Renders the next `frames` frames. The same sample goes to all `channels` interleaved channels of `out`.
void SKSignalRender(SKSignal* signal, float* out, uint32_t frames, uint32_t channels);

// ---------------------------------------------------------------------------------------------------------------------
// Render context: the state behind one IOProc on one output device.
// ---------------------------------------------------------------------------------------------------------------------

// What the IOProc expects to find in the i-th AudioBuffer (one buffer per output stream of the device).
typedef struct SKStreamLayout {
    uint32_t channels;
    bool writable;       // The stream is native 32-bit float linear PCM, so it's safe to write samples to it.
} SKStreamLayout;

typedef struct SKRenderContext SKRenderContext;

SKRenderContext* _Nullable SKRenderContextCreate(const SKSignalConfig* config, const SKStreamLayout* _Nullable streams, uint32_t streamCount);
void SKRenderContextDestroy(SKRenderContext* _Nullable context);

// A disarmed context renders zeroes only. Used while the device format is being changed.
void SKRenderContextSetArmed(SKRenderContext* context, bool armed);

// Counters for the watchdog and diagnostics. Safe to call from any thread.
uint64_t SKRenderContextGetCallbackCount(const SKRenderContext* context);
uint64_t SKRenderContextGetFrameCount(const SKRenderContext* context);
uint64_t SKRenderContextGetMismatchCount(const SKRenderContext* context);

// Fills all output buffers. This is what the IOProc does; exposed for tests.
void SKRenderContextRender(SKRenderContext* context, AudioBufferList* output);

// Registers the IOProc of this context on the device.
OSStatus SKRenderContextCreateIOProc(SKRenderContext* context, AudioObjectID device, AudioDeviceIOProcID _Nullable * _Nonnull outProcID);

// Tells the HAL that the IOProc doesn't use input streams of the device. Otherwise starting IO on a device that has
// a microphone (USB headsets, audio interfaces) would also start recording.
OSStatus SKDisableInputStreams(AudioObjectID device, AudioDeviceIOProcID procID);

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif // SK_RENDER_H
