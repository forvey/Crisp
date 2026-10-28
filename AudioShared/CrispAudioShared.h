#ifndef CRISP_AUDIO_SHARED_H
#define CRISP_AUDIO_SHARED_H
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

#define CRISP_MIC_CONTROL ((uint32_t)0x636d6374)
#define CRISP_MIC_WRITE ((uint32_t)0x636d7772)
#define CRISP_MIC_STATUS ((uint32_t)0x636d7374)
#define CRISP_MIC_VERSION 1
#define CRISP_MIC_RATE 48000
#define CRISP_MIC_PACKET_FRAMES 960
#define CRISP_MIC_UID "com.forvey.Crisp.RemoteMicrophone"
#define CRISP_MIC_NAME "远程麦克风"

typedef struct { uint32_t version, enabled; uint64_t generation; } CrispMicControl;
typedef struct {
    uint32_t version, frames;
    uint64_t generation;
    float samples[CRISP_MIC_PACKET_FRAMES];
} CrispMicPacket;

typedef struct {
    pthread_mutex_t mutex;
    float *samples;
    size_t capacity, head, count;
    uint64_t generation, lastWrite;
    bool enabled;
} CrispAudioRing;

static inline void *CrispRingCreate(size_t capacity) {
    CrispAudioRing *ring = calloc(1, sizeof(*ring));
    if (!ring) return NULL;
    ring->samples = calloc(capacity, sizeof(float));
    if (!ring->samples) { free(ring); return NULL; }
    ring->capacity = capacity;
    pthread_mutex_init(&ring->mutex, NULL);
    return ring;
}
static inline void CrispRingDestroy(void *reference) {
    CrispAudioRing *ring = reference;
    if (!ring) return;
    pthread_mutex_destroy(&ring->mutex);
    free(ring->samples);
    free(ring);
}
static inline void CrispRingPushUnlocked(CrispAudioRing *ring, const float *samples, size_t count) {
    if (count > ring->capacity) { samples += count - ring->capacity; count = ring->capacity; }
    if (ring->count + count > ring->capacity) {
        size_t drop = ring->count + count - ring->capacity;
        ring->head = (ring->head + drop) % ring->capacity;
        ring->count -= drop;
    }
    for (size_t i = 0; i < count; ++i) ring->samples[(ring->head + ring->count + i) % ring->capacity] = samples[i];
    ring->count += count;
    ring->lastWrite = mach_absolute_time();
}
static inline size_t CrispRingTakeUnlocked(CrispAudioRing *ring, float *output, size_t count) {
    size_t available = ring->count < count ? ring->count : count;
    for (size_t i = 0; i < available; ++i) output[i] = ring->samples[(ring->head + i) % ring->capacity];
    if (available < count) memset(output + available, 0, (count - available) * sizeof(float));
    ring->head = (ring->head + available) % ring->capacity;
    ring->count -= available;
    return available;
}
// A real-time producer never waits on a worker. Contended input is dropped, not queued
// or allocated on the audio thread. All conversion and networking happen elsewhere.
static inline size_t CrispRingPushRealtime(void *reference, const float *samples, size_t count) {
    CrispAudioRing *ring = reference;
    if (!ring || pthread_mutex_trylock(&ring->mutex) != 0) return 0;
    CrispRingPushUnlocked(ring, samples, count);
    pthread_mutex_unlock(&ring->mutex);
    return count;
}
static inline size_t CrispRingRead(void *reference, float *output, size_t count) {
    CrispAudioRing *ring = reference;
    if (!ring) { memset(output, 0, count * sizeof(float)); return 0; }
    pthread_mutex_lock(&ring->mutex);
    size_t read = CrispRingTakeUnlocked(ring, output, count);
    pthread_mutex_unlock(&ring->mutex);
    return read;
}
static inline void CrispRingClear(void *reference) {
    CrispAudioRing *ring = reference;
    if (!ring) return;
    pthread_mutex_lock(&ring->mutex);
    ring->head = ring->count = 0;
    pthread_mutex_unlock(&ring->mutex);
}
static inline uint64_t CrispRingLastWrite(void *reference) {
    CrispAudioRing *ring = reference;
    pthread_mutex_lock(&ring->mutex);
    uint64_t value = ring->lastWrite;
    pthread_mutex_unlock(&ring->mutex);
    return value;
}
#endif
