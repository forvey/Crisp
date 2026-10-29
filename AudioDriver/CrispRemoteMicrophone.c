// Input-only AudioServerPlugIn. No physical microphone, output stream, file I/O or
// network access. Audio is injected through marshalled CFData custom properties.
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <stdatomic.h>
#include <math.h>
#include <dispatch/dispatch.h>
#include "../AudioShared/CrispAudioShared.h"

enum { Device = 2, Input = 3 };
typedef AudioServerPlugInDriverRef Driver;
typedef const AudioObjectPropertyAddress *Address;
static AudioServerPlugInDriverInterface interface;
static AudioServerPlugInDriverInterface *interfacePointer = &interface;
static Driver reference = &interfacePointer;
static _Atomic UInt32 references = 1, running = 0;
static _Atomic uint64_t anchor = 0, seed = 1;
static CrispAudioRing *ring;
static double ticksPerFrame;
static uint64_t expirationTicks;
static float cached[4096];
static double cachedTime;
static UInt32 cachedFrames;
static bool cacheValid = false;
static _Atomic bool streamActive = true;
static AudioServerPlugInHostRef pluginHost;
static _Atomic bool probeEnabled = false;
static _Atomic uint64_t probeAccepted = 0, probeRejected = 0, probeRead = 0, probeNonzero = 0;
static _Atomic uint64_t probeOverflow = 0, probeUnderflow = 0, probePriming = 0, probeContention = 0, probeExpired = 0;
// One playback buffer, consumed only by ReadInput. 160 ms covers the observed
// 140-ms delivery gap; a real underrun grows the reserve to 200 ms. Cap at 300
// ms rather than accumulate old conversation indefinitely. Protected by ring.
enum { InitialReserve = 7680, MaximumReserve = 9600, BufferCapacity = 14400 };
static size_t reserveFrames = InitialReserve;
static bool priming = true;

// Only StartIO/StopIO call this, never the real-time sample callback. Notify
// asynchronously so querying the new property cannot re-enter StartIO/StopIO.
static void usageChanged(void) {
    AudioServerPlugInHostRef host = pluginHost;
    if (!host || !host->PropertiesChanged) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        AudioObjectPropertyAddress addresses[] = {
            {CRISP_MIC_USAGE, kAudioObjectPropertyScopeGlobal, 0},
            {kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal, 0},
            {kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, 0}};
        host->PropertiesChanged(host, Device, 3, addresses);
    });
}

static void clearInput(void) {
    pthread_mutex_lock(&ring->mutex);
    ring->head = ring->count = ring->lastWrite = 0;
    priming = true; reserveFrames = InitialReserve;
    cacheValid = false;
    pthread_mutex_unlock(&ring->mutex);
}

static AudioStreamBasicDescription format(void) {
    return (AudioStreamBasicDescription){ .mSampleRate = 48000, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagsNativeFloatPacked, .mBytesPerPacket = 4,
        .mFramesPerPacket = 1, .mBytesPerFrame = 4, .mChannelsPerFrame = 1, .mBitsPerChannel = 32 };
}
static OSStatus copy(void *out, UInt32 capacity, UInt32 *size, const void *value, UInt32 bytes) {
    *size = bytes;
    if (!out) return noErr;
    if (capacity < bytes) return kAudioHardwareBadPropertySizeError;
    if (bytes) memcpy(out, value, bytes);
    return noErr;
}
#define VALUE(type, expression) do { type value = (expression); return copy(out, capacity, size, &value, sizeof(value)); } while (0)
#define STRING(text) do { \
    *size = sizeof(CFStringRef); \
    if (!out) return noErr; \
    if (capacity < *size) return kAudioHardwareBadPropertySizeError; \
    *(CFStringRef *)out = CFRetain(CFSTR(text)); return noErr; \
} while (0)

static OSStatus property(AudioObjectID object, Address address, UInt32 qualifierSize, const void *qualifier,
                         UInt32 capacity, UInt32 *size, void *out) {
    if (!address || !size) return kAudioHardwareIllegalOperationError;
    if (object != kAudioObjectPlugInObject && object != Device && object != Input) return kAudioHardwareBadObjectError;
    bool input = address->mScope != kAudioObjectPropertyScopeOutput;
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass: VALUE(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass:
        VALUE(AudioClassID, object == Device ? kAudioDeviceClassID : object == Input ? kAudioStreamClassID : kAudioPlugInClassID);
    case kAudioObjectPropertyOwner:
        VALUE(AudioObjectID, object == Device ? kAudioObjectPlugInObject : object == Input ? Device : kAudioObjectUnknown);
    case kAudioObjectPropertyName: STRING(CRISP_MIC_NAME);
    case kAudioObjectPropertyManufacturer: STRING("Crisp");
    case kAudioObjectPropertyElementName: STRING(CRISP_MIC_NAME);
    case kAudioObjectPropertyOwnedObjects:
        if (object == kAudioObjectPlugInObject) VALUE(AudioObjectID, Device);
        if (object == Device && input) VALUE(AudioObjectID, Input);
        return copy(out, capacity, size, NULL, 0);
    default: break;
    }
    if (object == kAudioObjectPlugInObject) {
        switch (address->mSelector) {
        case kAudioPlugInPropertyDeviceList: VALUE(AudioObjectID, Device);
        case kAudioPlugInPropertyBoxList: return copy(out, capacity, size, NULL, 0);
        case kAudioPlugInPropertyResourceBundle: STRING("");
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID result = kAudioObjectUnknown;
            if (qualifier && qualifierSize == sizeof(CFStringRef) &&
                CFEqual(*(CFStringRef const *)qualifier, CFSTR(CRISP_MIC_UID))) result = Device;
            VALUE(AudioObjectID, result);
        }
        default: return kAudioHardwareUnknownPropertyError;
        }
    }
    if (object == Device) {
        switch (address->mSelector) {
        case kAudioDevicePropertyDeviceUID: STRING(CRISP_MIC_UID);
        case kAudioDevicePropertyModelUID: STRING("com.forvey.Crisp.RemoteMicrophone.model");
        case kAudioDevicePropertyTransportType: VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyDeviceIsAlive: VALUE(UInt32, 1);
        case kAudioDevicePropertyIsHidden: VALUE(UInt32, 0);
        case kAudioDevicePropertyDeviceIsRunning: case kAudioDevicePropertyDeviceIsRunningSomewhere:
            VALUE(UInt32, atomic_load(&running) > 0);
        // Eligibility is not a request to select the default. Sound settings
        // and capture applications filter out ineligible input devices.
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: VALUE(UInt32, input ? 1 : 0);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: VALUE(UInt32, 0);
        case kAudioDevicePropertyRelatedDevices: VALUE(AudioObjectID, Device);
        case kAudioDevicePropertyClockDomain: VALUE(UInt32, 0);
        case kAudioDevicePropertyClockIsStable: VALUE(UInt32, 1);
        case kAudioDevicePropertyClockAlgorithm: VALUE(UInt32, kAudioDeviceClockAlgorithmRaw);
        case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset: VALUE(UInt32, 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: case kAudioDevicePropertyBufferFrameSize: VALUE(UInt32, 480);
        case kAudioDevicePropertyBufferFrameSizeRange: {
            AudioValueRange range = {128, 2048}; return copy(out, capacity, size, &range, sizeof(range));
        }
        case kAudioDevicePropertyNominalSampleRate: VALUE(Float64, 48000);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange range = {48000, 48000}; return copy(out, capacity, size, &range, sizeof(range));
        }
        case kAudioObjectPropertyControlList: return copy(out, capacity, size, NULL, 0);
        case kAudioDevicePropertyStreams:
            if (input) VALUE(AudioObjectID, Input);
            return copy(out, capacity, size, NULL, 0);
        case kAudioDevicePropertyStreamConfiguration: {
            UInt32 bytes = (UInt32)offsetof(AudioBufferList, mBuffers) + (input ? sizeof(AudioBuffer) : 0);
            *size = bytes;
            if (!out) return noErr;
            if (capacity < bytes) return kAudioHardwareBadPropertySizeError;
            memset(out, 0, bytes);
            AudioBufferList *buffers = out;
            buffers->mNumberBuffers = input ? 1 : 0;
            if (input) buffers->mBuffers[0].mNumberChannels = 1;
            return noErr;
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            UInt32 channels[] = {1, 1}; return copy(out, capacity, size, channels, sizeof(channels));
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            AudioChannelLayout layout = {.mChannelLayoutTag = kAudioChannelLayoutTag_Mono};
            return copy(out, capacity, size, &layout, offsetof(AudioChannelLayout, mChannelDescriptions));
        }
        case kAudioObjectPropertyCustomPropertyInfoList: {
            AudioServerPlugInCustomPropertyInfo infos[] = {
                {CRISP_MIC_CONTROL, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, 0},
                {CRISP_MIC_WRITE, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, 0},
                {CRISP_MIC_STATUS, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, 0},
                {CRISP_MIC_USAGE, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, 0},
                {CRISP_MIC_PROBE, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, 0},
                {CRISP_MIC_BUFFER_STATS, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, 0}};
            return copy(out, capacity, size, infos, sizeof(infos));
        }
        case CRISP_MIC_USAGE: {
            *size = sizeof(CFPropertyListRef);
            if (!out) return noErr;
            if (capacity < *size) return kAudioHardwareBadPropertySizeError;
            CrispMicUsage usage = {1, atomic_load(&running) > 0};
            *(CFDataRef *)out = CFDataCreate(NULL, (const UInt8 *)&usage, sizeof(usage));
            return noErr;
        }
        case CRISP_MIC_PROBE: {
            *size = sizeof(CFPropertyListRef);
            if (!out) return noErr;
            if (capacity < *size) return kAudioHardwareBadPropertySizeError;
            CrispMicProbeStats stats = {1, atomic_load(&probeEnabled),
                atomic_load(&probeAccepted), atomic_load(&probeRejected),
                atomic_load(&probeRead), atomic_load(&probeNonzero)};
            *(CFDataRef *)out = CFDataCreate(NULL, (const UInt8 *)&stats, sizeof(stats));
            return noErr;
        }
        case CRISP_MIC_BUFFER_STATS: {
            *size = sizeof(CFPropertyListRef);
            if (!out) return noErr;
            if (capacity < *size) return kAudioHardwareBadPropertySizeError;
            CrispMicBufferStats stats = {1, atomic_load(&probeEnabled),
                atomic_load(&probeOverflow), atomic_load(&probeUnderflow), atomic_load(&probePriming),
                atomic_load(&probeContention), atomic_load(&probeExpired)};
            *(CFDataRef *)out = CFDataCreate(NULL, (const UInt8 *)&stats, sizeof(stats));
            return noErr;
        }
        case CRISP_MIC_CONTROL: case CRISP_MIC_WRITE: case CRISP_MIC_STATUS: {
            *size = sizeof(CFPropertyListRef);
            if (!out) return noErr;
            if (capacity < *size || !ring) return kAudioHardwareBadPropertySizeError;
            pthread_mutex_lock(&ring->mutex);
            CrispMicControl control = {1, ring->enabled, ring->generation};
            pthread_mutex_unlock(&ring->mutex);
            *(CFDataRef *)out = CFDataCreate(NULL, (const UInt8 *)&control, sizeof(control));
            return noErr;
        }
        default: return kAudioHardwareUnknownPropertyError;
        }
    }
    switch (address->mSelector) {
    case kAudioStreamPropertyDirection: VALUE(UInt32, 1);
    case kAudioStreamPropertyTerminalType: VALUE(UInt32, kAudioStreamTerminalTypeMicrophone);
    case kAudioStreamPropertyStartingChannel: VALUE(UInt32, 1);
    case kAudioStreamPropertyLatency: VALUE(UInt32, 0);
    case kAudioStreamPropertyIsActive: VALUE(UInt32, atomic_load(&streamActive));
    case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: {
        AudioStreamBasicDescription value = format(); return copy(out, capacity, size, &value, sizeof(value));
    }
    case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: {
        AudioStreamRangedDescription value = {.mFormat = format(), .mSampleRateRange = {48000, 48000}};
        return copy(out, capacity, size, &value, sizeof(value));
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static HRESULT query(void *driver, REFIID iid, LPVOID *out) {
    if (!out || driver != reference) return E_NOINTERFACE;
    CFUUIDRef ident = CFUUIDCreateFromUUIDBytes(NULL, iid);
    bool supported = CFEqual(ident, IUnknownUUID) || CFEqual(ident, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(ident);
    *out = supported ? reference : NULL;
    if (supported) atomic_fetch_add(&references, 1);
    return supported ? S_OK : E_NOINTERFACE;
}
static ULONG addRef(void *driver) { return driver == reference ? atomic_fetch_add(&references, 1) + 1 : 0; }
static ULONG releaseRef(void *driver) {
    if (driver != reference) return 0;
    UInt32 count = atomic_load(&references);
    while (count && !atomic_compare_exchange_weak(&references, &count, count - 1)) {}
    return count ? count - 1 : 0;
}
static OSStatus initialize(Driver driver, AudioServerPlugInHostRef host) {
    if (driver != reference) return kAudioHardwareBadObjectError;
    if (!ring) ring = CrispRingCreate(BufferCapacity);
    if (!ring) return kAudioHardwareUnspecifiedError;
    pluginHost = host;
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    ticksPerFrame = 1e9 * info.denom / info.numer / 48000;
    expirationTicks = (uint64_t)(ticksPerFrame * 9600);
    return noErr;
}
static OSStatus createDevice(Driver d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *c, AudioObjectID *out) {
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus destroyDevice(Driver d, AudioObjectID id) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus client(Driver d, AudioObjectID id, const AudioServerPlugInClientInfo *c) {
    return d == reference && id == Device ? noErr : kAudioHardwareBadObjectError;
}
static OSStatus configuration(Driver d, AudioObjectID id, UInt64 action, void *info) {
    return d == reference && id == Device ? noErr : kAudioHardwareBadObjectError;
}
static Boolean has(Driver d, AudioObjectID id, pid_t pid, Address a) {
    UInt32 size = 0;
    return d == reference && property(id, a, 0, NULL, 0, &size, NULL) == noErr;
}
static OSStatus settable(Driver d, AudioObjectID id, pid_t pid, Address a, Boolean *out) {
    if (!out || !has(d, id, pid, a)) return kAudioHardwareUnknownPropertyError;
    *out = (id == Device && (a->mSelector == CRISP_MIC_CONTROL || a->mSelector == CRISP_MIC_WRITE || a->mSelector == CRISP_MIC_PROBE)) ||
           (id == Input && a->mSelector == kAudioStreamPropertyIsActive);
    return noErr;
}
static OSStatus sizeOf(Driver d, AudioObjectID id, pid_t pid, Address a, UInt32 qs, const void *q, UInt32 *out) {
    return d == reference ? property(id, a, qs, q, 0, out, NULL) : kAudioHardwareBadObjectError;
}
static OSStatus get(Driver d, AudioObjectID id, pid_t pid, Address a, UInt32 qs, const void *q,
                    UInt32 capacity, UInt32 *size, void *out) {
    return d == reference ? property(id, a, qs, q, capacity, size, out) : kAudioHardwareBadObjectError;
}
static OSStatus set(Driver d, AudioObjectID id, pid_t pid, Address a, UInt32 qs, const void *q, UInt32 bytes, const void *data) {
    if (d != reference || !a || !data) return kAudioHardwareBadObjectError;
    if (id == Input && a->mSelector == kAudioStreamPropertyIsActive && bytes == sizeof(UInt32)) {
        atomic_store(&streamActive, *(const UInt32 *)data != 0); return noErr;
    }
    if (id != Device || (a->mSelector != CRISP_MIC_CONTROL && a->mSelector != CRISP_MIC_WRITE && a->mSelector != CRISP_MIC_PROBE))
        return kAudioHardwareUnknownPropertyError;
    if (bytes != sizeof(CFPropertyListRef) || !ring) return kAudioHardwareBadPropertySizeError;
    CFDataRef payload = *(CFDataRef const *)data;
    if (!payload || CFGetTypeID(payload) != CFDataGetTypeID()) return kAudioHardwareIllegalOperationError;
    if (a->mSelector == CRISP_MIC_PROBE) {
        if (CFDataGetLength(payload) != sizeof(CrispMicProbeControl)) return kAudioHardwareBadPropertySizeError;
        CrispMicProbeControl control;
        memcpy(&control, CFDataGetBytePtr(payload), sizeof(control));
        if (control.version != 1 || control.enabled > 1) return kAudioHardwareIllegalOperationError;
        atomic_store(&probeEnabled, false);
        if (control.enabled) {
            atomic_store(&probeAccepted, 0); atomic_store(&probeRejected, 0);
            atomic_store(&probeRead, 0); atomic_store(&probeNonzero, 0);
            atomic_store(&probeOverflow, 0); atomic_store(&probeUnderflow, 0); atomic_store(&probePriming, 0);
            atomic_store(&probeContention, 0); atomic_store(&probeExpired, 0);
            atomic_store(&probeEnabled, true);
        }
    } else if (a->mSelector == CRISP_MIC_CONTROL) {
        if (CFDataGetLength(payload) != sizeof(CrispMicControl)) return kAudioHardwareBadPropertySizeError;
        CrispMicControl control;
        memcpy(&control, CFDataGetBytePtr(payload), sizeof(control));
        if (control.version != 1 || control.enabled > 1) return kAudioHardwareIllegalOperationError;
        pthread_mutex_lock(&ring->mutex);
        ring->enabled = control.enabled;
        ring->generation = control.generation;
        ring->head = ring->count = ring->lastWrite = 0;
        priming = true; reserveFrames = InitialReserve;
        cacheValid = false;
        pthread_mutex_unlock(&ring->mutex);
    } else {
        if (CFDataGetLength(payload) != sizeof(CrispMicPacket)) return kAudioHardwareBadPropertySizeError;
        CrispMicPacket packet;
        memcpy(&packet, CFDataGetBytePtr(payload), sizeof(packet));
        if (packet.version != 1 || packet.frames != 960) return kAudioHardwareIllegalOperationError;
        for (size_t i = 0; i < 960; ++i) packet.samples[i] = isfinite(packet.samples[i]) ? fmaxf(-1, fminf(1, packet.samples[i])) : 0;
        pthread_mutex_lock(&ring->mutex);
        bool accepted = atomic_load(&running) > 0 && ring->enabled && ring->generation == packet.generation;
        if (accepted) {
            if (atomic_load(&probeEnabled) && ring->count + packet.frames > ring->capacity)
                atomic_fetch_add(&probeOverflow, ring->count + packet.frames - ring->capacity);
            CrispRingPushUnlocked(ring, packet.samples, packet.frames);
        }
        if (atomic_load(&probeEnabled)) {
            if (accepted) atomic_fetch_add(&probeAccepted, 1);
            else atomic_fetch_add(&probeRejected, 1);
        }
        pthread_mutex_unlock(&ring->mutex);
    }
    return noErr;
}
static OSStatus start(Driver d, AudioObjectID id, UInt32 c) {
    if (d != reference || id != Device) return kAudioHardwareBadObjectError;
    if (atomic_fetch_add(&running, 1) == 0) {
        clearInput();
        atomic_store(&anchor, mach_absolute_time()); atomic_fetch_add(&seed, 1);
        usageChanged();
    }
    return noErr;
}
static OSStatus stop(Driver d, AudioObjectID id, UInt32 c) {
    if (d != reference || id != Device) return kAudioHardwareBadObjectError;
    UInt32 count = atomic_load(&running);
    while (count && !atomic_compare_exchange_weak(&running, &count, count - 1)) {}
    if (count == 1) { atomic_store(&probeEnabled, false); clearInput(); usageChanged(); }
    return noErr;
}
static OSStatus timestamp(Driver d, AudioObjectID id, UInt32 c, Float64 *sample, UInt64 *host, UInt64 *outSeed) {
    if (d != reference || id != Device || !sample || !host || !outSeed) return kAudioHardwareBadObjectError;
    UInt64 base = atomic_load(&anchor), now = mach_absolute_time();
    if (!base) base = now;
    double periods = floor((now - base) / (ticksPerFrame * 480));
    *sample = periods * 480; *host = base + (UInt64)(*sample * ticksPerFrame); *outSeed = atomic_load(&seed);
    return noErr;
}
static OSStatus will(Driver d, AudioObjectID id, UInt32 c, UInt32 op, Boolean *yes, Boolean *inPlace) {
    if (yes) *yes = op == kAudioServerPlugInIOOperationReadInput;
    if (inPlace) *inPlace = true;
    return d == reference && id == Device ? noErr : kAudioHardwareBadObjectError;
}
static OSStatus begin(Driver d, AudioObjectID id, UInt32 c, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *info) {
    return d == reference && id == Device ? noErr : kAudioHardwareBadObjectError;
}
static OSStatus io(Driver d, AudioObjectID id, AudioObjectID stream, UInt32 c, UInt32 op, UInt32 frames,
                   const AudioServerPlugInIOCycleInfo *info, void *main, void *secondary) {
    if (d != reference || id != Device || stream != Input || !main || frames > 4096) return kAudioHardwareBadObjectError;
    if (op != kAudioServerPlugInIOOperationReadInput) return noErr;
    bool probing = atomic_load(&probeEnabled);
    if (probing) atomic_fetch_add(&probeRead, frames);
    // Real-time: never wait, allocate, convert formats, log, or perform IPC here.
    if (!ring || pthread_mutex_trylock(&ring->mutex) != 0) {
        if (probing) atomic_fetch_add(&probeContention, frames);
        memset(main, 0, frames * 4); return noErr;
    }
    UInt64 now = mach_absolute_time();
    if (!atomic_load(&running) || !ring->enabled || !atomic_load(&streamActive) ||
        (ring->lastWrite && now - ring->lastWrite >= expirationTicks)) {
        if (probing && ring->lastWrite && now - ring->lastWrite >= expirationTicks)
            atomic_fetch_add(&probeExpired, ring->count);
        ring->head = ring->count = ring->lastWrite = 0; cacheValid = false; priming = true;
        memset(main, 0, frames * 4);
    } else if (info && cacheValid && info->mInputTime.mSampleTime == cachedTime && cachedFrames == frames) {
        memcpy(main, cached, frames * 4);
    } else {
        if (priming && ring->count < reserveFrames) {
            memset(main, 0, frames * 4);
            if (probing) atomic_fetch_add(&probePriming, frames);
        } else {
            priming = false;
            size_t read = CrispRingTakeUnlocked(ring, main, frames);
            if (read < frames) {
                if (probing) atomic_fetch_add(&probeUnderflow, frames - read);
                priming = true;
                reserveFrames = MaximumReserve;
            }
        }
        memcpy(cached, main, frames * 4);
        cachedFrames = frames; cachedTime = info ? info->mInputTime.mSampleTime : NAN; cacheValid = info != NULL;
    }
    if (probing) {
        UInt64 nonzero = 0;
        for (UInt32 i = 0; i < frames; ++i) if (((float *)main)[i] != 0) ++nonzero;
        atomic_fetch_add(&probeNonzero, nonzero);
    }
    pthread_mutex_unlock(&ring->mutex);
    return noErr;
}
static AudioServerPlugInDriverInterface interface = {
    NULL, query, addRef, releaseRef, initialize, createDevice, destroyDevice, client, client,
    configuration, configuration, has, settable, sizeOf, get, set, start, stop, timestamp, will, begin, io, begin
};
__attribute__((visibility("default"))) void *CrispRemoteMicrophone_Create(CFAllocatorRef allocator, CFUUIDRef type) {
    return CFEqual(type, kAudioServerPlugInTypeUUID) ? reference : NULL;
}
