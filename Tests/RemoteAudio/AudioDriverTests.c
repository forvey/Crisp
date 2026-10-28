#include <CoreAudio/AudioServerPlugIn.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <unistd.h>
#include <dlfcn.h>
#include "../../AudioShared/CrispAudioShared.h"
extern void *CrispRemoteMicrophone_Create(CFAllocatorRef, CFUUIDRef);

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
int main(int argc, char **argv) {
    void *handle = argc > 1 ? dlopen(argv[1], RTLD_NOW | RTLD_LOCAL) : NULL;
    if (argc > 1) assert(handle);
    typedef void *(*Factory)(CFAllocatorRef, CFUUIDRef);
    Factory factory = handle ? (Factory)dlsym(handle, "CrispRemoteMicrophone_Create") : CrispRemoteMicrophone_Create;
    assert(factory);
    AudioServerPlugInDriverRef d = factory(NULL,kAudioServerPlugInTypeUUID);
    assert(d);
    AudioServerPlugInHostInterface host={0};
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
    CrispAudioRing *ring=CrispRingCreate(4800); float input[480]={0};
    pthread_mutex_lock(&ring->mutex);
    assert(CrispRingPushRealtime(ring,input,480)==0); // Real-time path never waits on the worker.
    pthread_mutex_unlock(&ring->mutex); CrispRingDestroy(ring);
    puts("HAL fake-host tests passed: input-only properties, generation, silence, timeout, fanout and bounded queue.");
    return 0;
}
