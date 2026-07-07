#import <AVFoundation/AVFoundation.h>

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
- (instancetype)initWithRefreshRate:(float)refreshRate videoDynamicRange:(int)videoDynamicRange;
@end
#endif
