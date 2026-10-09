#include "../Sources/Player/VortXMPVNativeFrameBridge.h"
void TestNativeReset(void);
void TestNativeSetModeResult(int result);
void TestNativeAdvanceEpoch(uint64_t epoch);
void TestNativePublish(void *pixels, double pts, double rate, bool paused, uint64_t epoch);
int TestNativeOutstandingFrames(void);
int TestNativeDestroyCalls(void);
int TestNativeModeCalls(void);
int TestNativeForegroundCalls(void);
