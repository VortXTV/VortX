#import <AVFoundation/AVFoundation.h>

// AVDisplayCriteria's integer initializer is private SPI, but it is what the
// field-proven tvOS players ship for HDR display-mode switching: the public
// initWithRefreshRate:formatDescription: has been observed building criteria
// that tvOS then ignores for synthetic format descriptions. This class
// extension re-declares the private members so Swift can call them; every call
// site guards with instancesRespondToSelector: first, so an OS that removes
// the SPI degrades to the public path instead of crashing.
//
// videoDynamicRange values (reverse engineered, corroborated across projects):
//   0 = SDR, 2 = HDR10/PQ, 3 = HLG, 4 = Dolby Vision
#if __has_include(<AVFoundation/AVDisplayCriteria.h>)
#import <AVFoundation/AVDisplayCriteria.h>

@interface AVDisplayCriteria ()
@property(readonly) int videoDynamicRange;
@property(readonly, nonatomic) float refreshRate;
- (instancetype)initWithRefreshRate:(float)refreshRate videoDynamicRange:(int)videoDynamicRange;
@end
#endif
