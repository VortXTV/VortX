#import <AVFoundation/AVFoundation.h>

#include <TargetConditionals.h>

#if TARGET_OS_TV
#include <Security/SecItem.h>

// Explicit tvOS SDK compatibility exception, not a nondeprecated API migration.
// Security's public Fail constant preserves noninteractive failures, while its
// recommended LAContext.interactionNotAllowed replacement is unavailable here.
// Never substitute default Allow, silent Skip, or a previously authenticated context.
// Only this original constant initializer is excepted from deprecation diagnostics;
// every other warning, availability check and warnings-as-errors policy remains active.
static inline CFStringRef _Nonnull VortXTVKeychainAuthenticationUIFailCompatibilityValue(void)
    CF_RETURNS_NOT_RETAINED;

static inline CFStringRef _Nonnull VortXTVKeychainAuthenticationUIFailCompatibilityValue(void) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    const CFStringRef value = kSecUseAuthenticationUIFail;
#pragma clang diagnostic pop
    return value;
}
#endif

// C11-atomic cancellation/progress bridge for the noncapturing FFmpeg remux callback.
#include "VortXRemuxInputProbe.h"

// Process-lifetime C-owned crash signal state; no Swift executes on a fatal signal.
#include "VortXCrashSignal.h"

// Network shares over SMB: the libsmbclient calls the share browser makes (see the header for why these are
// declared rather than imported). Quoted path relative to this header, like the QuickJS bridge below.
#include "../../SourcesShared/SMB/VortXSMBShim.h"

// Community JS provider runtime: exposes the QuickJS C bridge to Swift
// (JSProviderRuntime.swift calls VortXQuickJSRun / VortXQuickJSFree). Quoted path is relative to this
// header's directory and resolves on every target that compiles the QuickJS C sources.
#include "../../SourcesShared/JSProviders/QuickJS/VortXQuickJSBridge.h"

// The trailer range proxy owns Network.framework objects in Objective-C. Swift receives only value callbacks
// (lease ID, port and success/failure), so no nw_* object crosses the Swift 6 boundary.
#include "VXTrailerNetworkOwner.h"

// macOS 26 (Tahoe) SwiftUI toolbar-crash guard. Swallows the NSException thrown by
// NSToolbar's private -_insertNewItemWithItemIdentifier:... under SwiftUI's
// ToolbarBridge on a hidden, unused window toolbar, which AppKit otherwise turns
// into a fatal SIGTRAP. Implemented in SourcesShared/VortXToolbarCrashGuard.mm;
// a no-op on non-macOS. Call once at launch from the macOS app delegate.
void VortXInstallToolbarCrashGuard(void);

// AVDisplayCriteria's integer initializer is private SPI, retained only as the
// FALLBACK for HDR display-mode switching: the public
// initWithRefreshRate:formatDescription: (tvOS 17+) built with a 'dvh1'
// (kCMVideoCodecType_DolbyVisionHEVC) format description is the primary path
// (HDRDisplayMode.makeCriteria). This class extension re-declares the private
// members so Swift can call them; every call site guards with
// instancesRespondToSelector: first, so an OS that removes the SPI degrades
// cleanly instead of crashing.
//
// videoDynamicRange values on CURRENT tvOS (KVC readback of criteria built via
// the PUBLIC formatDescription initializer, tvOS 26.5 simulator):
//   1 = SDR, 2 = HLG, 4 = HDR10/PQ, 5 = Dolby Vision (dvh1)
// The old table (2 = HDR10, 3 = HLG, 4 = DV) came from tvOS 11-13-era console
// logs and is STALE on modern tvOS: sending 4 today requests HDR10, not DV.
#if __has_include(<AVFoundation/AVDisplayCriteria.h>)
#import <AVFoundation/AVDisplayCriteria.h>

@interface AVDisplayCriteria ()
@property(readonly) int videoDynamicRange;
@property(readonly, nonatomic) float refreshRate;
- (instancetype _Null_unspecified)initWithRefreshRate:(float)refreshRate videoDynamicRange:(int)videoDynamicRange;
@end
#endif
