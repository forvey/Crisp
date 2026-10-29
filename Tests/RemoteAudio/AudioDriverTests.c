#include <CoreAudio/AudioServerPlugIn.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include "../../AudioShared/CrispAudioShared.h"
extern void *CrispRemoteMicrophone_Create(CFAllocatorRef, CFUUIDRef);
static _Atomic unsigned usageNotifications = 0;

static OSStatus propertiesChanged(AudioServerPlugInHostRef host, AudioObjectID object, UInt32 count,
                                  const AudioObjectPropertyAddress *addresses) {
    for (UInt32 i = 0; i < count; ++i)
        if (object == 2 && addresses[i].mSelector == CRISP_MIC_USAGE) atomic_fetch_add(&usageNotifications, 1);
    return noErr;
}

static void waitNotifications(unsigned count) {
    for (unsigned i = 0; i < 100 && atomic_load(&usageNotifications) < count; ++i) usleep(10000);
    assert(atomic_load(&usageNotifications) == count);
}

static AudioObjectPropertyAddress address(UInt32 selector, UInt32 scope) {
    return (AudioObjectPropertyAddress){selector, scope, 0};
}
static OSStatus inject(AudioServerPlugInDriverRef d, UInt32 selector, const void *bytes, size_t length) {
    CFDataRef data = CFDataCreate(NULL, bytes, length);
    AudioObjectPropertyAddress a = address(selector, kAudioObjectPropertyScopeGlobal);
    OSStatus result = (*d)->SetPropertyData(d, 2, getpid(), &a, 0, NULL, sizeof(data), &data);
    CFRelease(data);
    return result;
}
static void control(AudioServerPlugInDriverRef d, bool enabled, uint64_t generation) {
    CrispMicControl value = {1, enabled, generation};
    assert(inject(d, CRISP_MIC_CONTROL, &value, sizeof(value)) == noErr);
}
static void writePacket(AudioServerPlugInDriverRef d, float level, uint64_t generation) {
    CrispMicPacket packet = {.version=1, .frames=960, .generation=generation};
    for (size_t i=0;i<960;++i) packet.samples[i]=level;
    assert(inject(d, CRISP_MIC_WRITE, &packet, sizeof(packet)) == noErr);
}
static void readPacket(AudioServerPlugInDriverRef d, float expected, double sampleTime) {
    float samples[480];
    AudioServerPlugInIOCycleInfo info = {0}; info.mInputTime.mSampleTime=sampleTime;
    assert((*d)->DoIOOperation(d,2,3,1,kAudioServerPlugInIOOperationReadInput,480,&info,samples,NULL)==noErr);
    for (size_t i=0;i<480;++i) assert(fabsf(samples[i]-expected)<0.00001);
}
static CrispMicProbeStats probeStats(AudioServerPlugInDriverRef d) {
    AudioObjectPropertyAddress a = address(CRISP_MIC_PROBE, kAudioObjectPropertyScopeGlobal);
    CFDataRef data = NULL; UInt32 bytes = 0;
    assert((*d)->GetPropertyData(d,2,getpid(),&a,0,NULL,sizeof(data),&bytes,&data)==noErr);
    CrispMicProbeStats result = {0};
    assert(CFDataGetLength(data)==sizeof(result));
    CFDataGetBytes(data,CFRangeMake(0,sizeof(result)),(UInt8 *)&result);
    CFRelease(data); return result;
}
int main(int argc, char **argv) {
    void *handle = argc > 1 ? dlopen(argv[1], RTLD_NOW | RTLD_LOCAL) : NULL;
    if (argc > 1) assert(handle);
    typedef void *(*Factory)(CFAllocatorRef, CFUUIDRef);
    Factory factory = handle ? (Factory)dlsym(handle, "CrispRemoteMicrophone_Create") : CrispRemoteMicrophone_Create;
    assert(factory);
    AudioServerPlugInDriverRef d = factory(NULL,kAudioServerPlugInTypeUUID);
    assert(d);
    AudioServerPlugInHostInterface host={0}; host.PropertiesChanged = propertiesChanged;
    assert((*d)->Initialize(d,&host)==noErr);
    AudioObjectPropertyAddress a=address(kAudioPlugInPropertyDeviceList,kAudioObjectPropertyScopeGlobal);
    UInt32 bytes=0, device=0;
    assert((*d)->GetPropertyDataSize(d,1,getpid(),&a,0,NULL,&bytes)==noErr && bytes==sizeof(device));
    assert((*d)->GetPropertyData(d,1,getpid(),&a,0,NULL,sizeof(device),&bytes,&device)==noErr && device==2);
    a=address(kAudioDevicePropertyStreams,kAudioObjectPropertyScopeOutput);
    assert((*d)->GetPropertyDataSize(d,2,getpid(),&a,0,NULL,&bytes)==noErr && bytes==0);
    a.mScope=kAudioObjectPropertyScopeInput;
    assert((*d)->GetPropertyDataSize(d,2,getpid(),&a,0,NULL,&bytes)==noErr && bytes==sizeof(UInt32));
    a=address(kAudioDevicePropertyDeviceCanBeDefaultDevice,kAudioObjectPropertyScopeInput);
    UInt32 defaultable=0;
    assert((*d)->GetPropertyData(d,2,getpid(),&a,0,NULL,sizeof(defaultable),&bytes,&defaultable)==noErr && defaultable==1);
    a.mScope=kAudioObjectPropertyScopeOutput;
    assert((*d)->GetPropertyData(d,2,getpid(),&a,0,NULL,sizeof(defaultable),&bytes,&defaultable)==noErr && defaultable==0);
    // A device being visible/allowed is not a consumer. First actual reader
    // starts demand; a second reader must not toggle it; only the last close stops it.
    a=address(CRISP_MIC_USAGE,kAudioObjectPropertyScopeGlobal);
    CFDataRef usageData=NULL;
    assert((*d)->GetPropertyData(d,2,getpid(),&a,0,NULL,sizeof(usageData),&bytes,&usageData)==noErr);
    CrispMicUsage usage={0}; CFDataGetBytes(usageData,CFRangeMake(0,sizeof(usage)),(UInt8 *)&usage); CFRelease(usageData);
    assert(usage.version==1 && usage.running==0);
    assert((*d)->StartIO(d,2,1)==noErr); waitNotifications(1);
    assert((*d)->StartIO(d,2,2)==noErr);
    assert((*d)->StopIO(d,2,1)==noErr);
    a=address(kAudioDevicePropertyDeviceIsRunning,kAudioObjectPropertyScopeGlobal);
    UInt32 running=0;
    assert((*d)->GetPropertyData(d,2,getpid(),&a,0,NULL,sizeof(running),&bytes,&running)==noErr && running==1);
    a=address(kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,kAudioObjectPropertyScopeOutput);
    assert((*d)->GetPropertyData(d,2,getpid(),&a,0,NULL,sizeof(defaultable),&bytes,&defaultable)==noErr && defaultable==0);
    writePacket(d,0.25,1); readPacket(d,0,0); // Closed by default.
    control(d,true,2); writePacket(d,0.25,2);
    readPacket(d,0.25,480); readPacket(d,0.25,480); // Same-cycle fanout must not consume twice.
    readPacket(d,0.25,960); readPacket(d,0,1440); // Underrun must not replay old samples.
    writePacket(d,0.5,2); control(d,false,3); readPacket(d,0,1920);
    control(d,true,4); writePacket(d,0.5,2); readPacket(d,0,2400); // Reject previous connection's epoch.
    writePacket(d,0.5,4); usleep(230000); readPacket(d,0,2880); // Hardware-side 200-ms silence failsafe.
    control(d,true,5);
    for(int i=1;i<=10;++i) writePacket(d,(float)i/10,5);
    readPacket(d,0.6,3360); // Only newest five packets (100 ms) survive overflow.
    control(d,false,6); readPacket(d,0,3840);
    control(d,true,7); writePacket(d,0.75,7);
    assert((*d)->StopIO(d,2,2)==noErr); waitNotifications(2);
    writePacket(d,0.75,7); // Late network packet while nobody reads must not be retained.
    assert((*d)->StartIO(d,2,3)==noErr); waitNotifications(3);
    readPacket(d,0,4320);
    assert((*d)->StopIO(d,2,3)==noErr); waitNotifications(4);
    // A successful property write can still be rejected by generation or
    // disabled input. Measure actual acceptance, only during an explicit test.
    CrispMicProbeStats before = probeStats(d);
    assert(before.enabled==0 && before.acceptedPackets==0 && before.readFrames==0);
    a=address(CRISP_MIC_PROBE,kAudioObjectPropertyScopeGlobal);
    Boolean writable=false;
    assert((*d)->IsPropertySettable(d,2,getpid(),&a,&writable)==noErr && writable);
    CrispMicProbeControl probe = {1,1};
    assert(inject(d,CRISP_MIC_PROBE,&probe,sizeof(probe))==noErr);
    assert((*d)->StartIO(d,2,4)==noErr);
    control(d,true,20);
    writePacket(d,0.25,19); // API succeeds, driver rejects old generation.
    writePacket(d,0.25,20);
    readPacket(d,0.25,0); readPacket(d,0.25,480); readPacket(d,0,960);
    CrispMicProbeStats measured = probeStats(d);
    assert(measured.acceptedPackets==1 && measured.rejectedPackets==1);
    assert(measured.readFrames==1440 && measured.nonzeroFrames==960);
    probe.enabled=0;
    assert(inject(d,CRISP_MIC_PROBE,&probe,sizeof(probe))==noErr);
    writePacket(d,0.5,20); readPacket(d,0.5,1440);
    CrispMicProbeStats stopped = probeStats(d);
    assert(stopped.enabled==0 && stopped.acceptedPackets==1 && stopped.readFrames==1440);
    // Last-reader stop is a failsafe even if the test client disappears.
    probe.enabled=1;
    assert(inject(d,CRISP_MIC_PROBE,&probe,sizeof(probe))==noErr);
    assert((*d)->StopIO(d,2,4)==noErr);
    assert(probeStats(d).enabled==0 && probeStats(d).acceptedPackets==0);
    CrispAudioRing *ring=CrispRingCreate(4800); float input[480]={0};
    pthread_mutex_lock(&ring->mutex);
    assert(CrispRingPushRealtime(ring,input,480)==0); // Real-time path never waits on the worker.
    pthread_mutex_unlock(&ring->mutex); CrispRingDestroy(ring);
    puts("HAL fake-host tests passed: input-only properties, generation, silence, timeout, fanout and bounded queue.");
    return 0;
}
