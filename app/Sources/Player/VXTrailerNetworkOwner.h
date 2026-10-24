#import <Foundation/Foundation.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// Value-only readiness result delivered to Swift. No Network framework type
/// crosses this boundary. The implementation invokes this block on the main
/// queue after the owner has committed the lease's listener port.
typedef void (^VXTrailerNetworkReadyBlock)(uint64_t leaseID, uint16_t port, BOOL success);
typedef void (^VXTrailerNetworkFailureBlock)(uint64_t leaseID);

/// Internal Objective-C owner for the local trailer range proxy. Network
/// objects and their callback lifetime stay inside the implementation's one
/// serial queue; Swift receives only the lease ID, port and prepared URLs.
@interface VXTrailerNetworkOwner : NSObject

+ (instancetype)sharedOwner;

- (void)startLease:(uint64_t)leaseID
         userAgent:(NSString *)userAgent
        completion:(VXTrailerNetworkReadyBlock)completion
          failure:(VXTrailerNetworkFailureBlock)failure;

/// Register the resolver-approved User-Agent for one exact upstream URL. The
/// implementation stores this on the lease and never accepts a caller-supplied
/// header value from the loopback request itself.
- (void)registerUpstreamURL:(NSString *)upstreamURL
                   userAgent:(NSString *)userAgent
                     leaseID:(uint64_t)leaseID;

- (void)stopLease:(uint64_t)leaseID;

/// Stop accepting new connections for a ready lease while allowing already
/// accepted connection windows to drain. The lease is retired after its last
/// connection closes. This is the scene/listener-failure path; callers that
/// own the current work and need cancellation use stopLease: instead.
- (void)drainLease:(uint64_t)leaseID;

@end

NS_ASSUME_NONNULL_END
