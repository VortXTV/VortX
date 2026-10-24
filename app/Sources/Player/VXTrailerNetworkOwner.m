#import "VXTrailerNetworkOwner.h"

#import <Network/Network.h>

static const NSUInteger VXTrailerWindowSize = 1048576;
static const NSUInteger VXTrailerMaxWindowAttempts = 4;
static const NSTimeInterval VXTrailerWindowRetryBaseDelay = 0.3;
static const NSTimeInterval VXTrailerWindowTimeout = 20.0;
static const NSTimeInterval VXTrailerHeaderDeadline = 15.0;

static NSData *VXDataFromDispatchData(dispatch_data_t content);
static NSString *VXDecodeBase64URL(NSString *encoded);
static BOOL VXParseExactInteger(NSString *value, NSInteger *result);

@class VXTrailerNetworkOwner;

@interface VXTrailerConnectionState : NSObject
@property(nonatomic, assign) uint64_t connectionID;
@property(nonatomic, assign) uint64_t leaseID;
@property(nonatomic, strong) nw_connection_t connection;
@property(nonatomic, strong) NSMutableData *requestData;
@property(nonatomic, assign) BOOL requestHeaderComplete;
@property(nonatomic, assign) NSUInteger rangeStart;
@property(nonatomic, assign) NSUInteger rangeStop;
@property(nonatomic, assign) NSUInteger rangeEnd;
@property(nonatomic, assign) NSUInteger promisedLength;
@property(nonatomic, assign) NSUInteger bytesSent;
@property(nonatomic, assign) NSUInteger attempt;
@property(nonatomic, strong, nullable) NSURL *upstreamURL;
@property(nonatomic, copy) NSString *mime;
@property(nonatomic, copy, nullable) NSString *requestUserAgent;
@property(nonatomic, strong, nullable) NSURLSessionDataTask *windowTask;
@property(nonatomic, assign) uint64_t headerGeneration;
@end

@interface VXTrailerLeaseState : NSObject
@property(nonatomic, assign) uint64_t leaseID;
@property(nonatomic, strong) nw_listener_t listener;
@property(nonatomic, copy) NSString *userAgent;
@property(nonatomic, assign) BOOL readyDelivered;
@property(nonatomic, assign) BOOL accepting;
@property(nonatomic, assign) BOOL stopping;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, VXTrailerConnectionState *> *connections;
@property(nonatomic, strong) NSMutableArray *readyCompletions;
@property(nonatomic, strong) NSMutableArray *failureCompletions;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *userAgentsByURL;
@property(nonatomic, assign) uint64_t readinessGeneration;
@end

@interface VXTrailerNetworkOwner ()
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, VXTrailerLeaseState *> *leases;
@property(nonatomic, assign) uint64_t nextConnectionID;
- (void)stopLeaseOnQueue:(uint64_t)leaseID state:(VXTrailerLeaseState *)lease;
- (void)drainLeaseOnQueue:(uint64_t)leaseID state:(VXTrailerLeaseState *)lease;
- (void)retireDrainedLeaseIfEmpty:(VXTrailerLeaseState *)lease;
@end

@implementation VXTrailerConnectionState
- (instancetype)init {
    self = [super init];
    if (self) {
        _requestData = [NSMutableData data];
        _mime = @"video/mp4";
    }
    return self;
}
@end

@implementation VXTrailerLeaseState
- (instancetype)init {
    self = [super init];
    if (self) {
        _connections = [NSMutableDictionary dictionary];
        _readyCompletions = [NSMutableArray array];
        _failureCompletions = [NSMutableArray array];
        _userAgentsByURL = [NSMutableDictionary dictionary];
    }
    return self;
}
@end

@implementation VXTrailerNetworkOwner

+ (instancetype)sharedOwner {
    static VXTrailerNetworkOwner *owner;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        owner = [[self alloc] initPrivate];
    });
    return owner;
}

- (instancetype)init {
    return [VXTrailerNetworkOwner sharedOwner];
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.vortx.trailer.native-owner", DISPATCH_QUEUE_SERIAL);
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        configuration.URLCache = nil;
        _session = [NSURLSession sessionWithConfiguration:configuration];
        _leases = [NSMutableDictionary dictionary];
        _nextConnectionID = 1;
    }
    return self;
}

- (void)startLease:(uint64_t)leaseID
         userAgent:(NSString *)userAgent
        completion:(VXTrailerNetworkReadyBlock)completion
          failure:(VXTrailerNetworkFailureBlock)failure {
    NSString *ua = [userAgent copy] ?: @"";
    VXTrailerNetworkReadyBlock ready = [completion copy];
    VXTrailerNetworkFailureBlock failed = [failure copy];
    dispatch_async(self.queue, ^{
        NSNumber *key = @(leaseID);
        VXTrailerLeaseState *existing = self.leases[key];
        if (existing != nil && existing.readyDelivered && existing.accepting && !existing.stopping) {
            uint16_t port = (uint16_t)nw_listener_get_port(existing.listener);
            if (port != 0) {
                if (failed != nil) { [existing.failureCompletions addObject:failed]; }
                [self deliverReady:existing success:YES port:port completion:ready];
                return;
            }
            // The native object has lost its port before its state callback
            // reached us. Drain accepted streams; only create a replacement
            // when the old lease has no connections left. Reusing this ID
            // while an old stream is alive would overwrite its state.
            [self drainLeaseOnQueue:leaseID state:existing];
            if (self.leases[key] == existing) {
                if (ready != nil) { [self deliverReady:existing success:NO port:0 completion:ready]; }
                if (failed != nil) { [self deliverFailure:existing completion:failed]; }
                return;
            }
            existing = nil;
        }
        if (existing != nil && existing.readyDelivered && !existing.accepting) {
            if (ready != nil) { [self deliverReady:existing success:NO port:0 completion:ready]; }
            if (failed != nil) { [self deliverFailure:existing completion:failed]; }
            return;
        }
        if (existing != nil && !existing.stopping) {
            // Same-lease callers share the one pending listener. Replacing it
            // would fail the first continuation and make the second result
            // untrustworthy; queue both value-only callbacks instead.
            if (ready != nil) { [existing.readyCompletions addObject:ready]; }
            if (failed != nil) { [existing.failureCompletions addObject:failed]; }
            return;
        }
        if (existing != nil) {
            [self stopLeaseOnQueue:leaseID state:existing];
        }

        VXTrailerLeaseState *lease = [[VXTrailerLeaseState alloc] init];
        lease.leaseID = leaseID;
        lease.userAgent = ua;
        lease.accepting = YES;
        if (ready != nil) { [lease.readyCompletions addObject:ready]; }
        if (failed != nil) { [lease.failureCompletions addObject:failed]; }
        lease.readinessGeneration += 1;

        nw_parameters_t parameters = nw_parameters_create_secure_tcp(
            NW_PARAMETERS_DISABLE_PROTOCOL,
            NW_PARAMETERS_DEFAULT_CONFIGURATION
        );
        nw_parameters_set_reuse_local_address(parameters, true);
        nw_endpoint_t loopback = nw_endpoint_create_host("127.0.0.1", "0");
        nw_parameters_set_local_endpoint(parameters, loopback);

        nw_listener_t listener = nw_listener_create_with_port("0", parameters);
        if (listener == NULL) {
            [self deliverReady:lease success:NO port:0 completion:ready];
            return;
        }
        lease.listener = listener;
        self.leases[key] = lease;

        __weak VXTrailerNetworkOwner *weakSelf = self;
        nw_listener_set_queue(listener, self.queue);
        nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error) {
            VXTrailerNetworkOwner *strongSelf = weakSelf;
            if (strongSelf == nil) { return; }
            // The listener queue is the owner's serial queue. Do not dispatch
            // a Network object to another queue or to Swift.
            [strongSelf listenerState:state error:error lease:lease];
        });
        nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) {
            VXTrailerNetworkOwner *strongSelf = weakSelf;
            if (strongSelf == nil) {
                nw_connection_cancel(connection);
                return;
            }
            [strongSelf acceptConnection:connection lease:lease];
        });
        nw_listener_start(listener);
        uint64_t readinessGeneration = lease.readinessGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       self.queue, ^{
            if (self.leases[key] == lease && !lease.stopping && !lease.readyDelivered &&
                lease.readinessGeneration == readinessGeneration) {
                // stopLeaseOnQueue retires the pending readiness callback and
                // cancels the listener. This is the bounded equivalent of the
                // former Swift semaphore deadline.
                [self stopLeaseOnQueue:leaseID state:lease];
            }
        });
    });
}

- (void)stopLease:(uint64_t)leaseID {
    dispatch_async(self.queue, ^{
        VXTrailerLeaseState *lease = self.leases[@(leaseID)];
        if (lease != nil) {
            [self stopLeaseOnQueue:leaseID state:lease];
        }
    });
}

- (void)drainLease:(uint64_t)leaseID {
    dispatch_async(self.queue, ^{
        VXTrailerLeaseState *lease = self.leases[@(leaseID)];
        if (lease != nil) {
            [self drainLeaseOnQueue:leaseID state:lease];
        }
    });
}

- (void)registerUpstreamURL:(NSString *)upstreamURL
                   userAgent:(NSString *)userAgent
                     leaseID:(uint64_t)leaseID {
    NSString *url = [upstreamURL copy] ?: @"";
    NSString *ua = [userAgent copy] ?: @"";
    dispatch_sync(self.queue, ^{
        VXTrailerLeaseState *lease = self.leases[@(leaseID)];
        NSURL *parsed = [NSURL URLWithString:url];
        if (lease == nil || lease.stopping || !lease.accepting || parsed.host.length == 0 ||
            ![parsed.host containsString:@"googlevideo"] || ua.length == 0) {
            return;
        }
        lease.userAgentsByURL[parsed.absoluteString] = ua;
    });
}

- (void)stopLeaseOnQueue:(uint64_t)leaseID state:(VXTrailerLeaseState *)lease {
    lease.stopping = YES;
    lease.accepting = NO;
    // A cancelled readiness wait still owns a Swift continuation. Retire the
    // callback exactly once, after clearing the lease's handler, so cancellation
    // cannot leave `prepare` suspended forever. A ready lease has already
    // delivered its callback and therefore has no completion here.
    NSArray *pendingCompletions = [lease.readyCompletions copy];
    [lease.readyCompletions removeAllObjects];
    [lease.failureCompletions removeAllObjects];
    lease.readinessGeneration += 1;
    if (lease.listener != NULL) {
        nw_listener_set_state_changed_handler(lease.listener, nil);
        nw_listener_set_new_connection_handler(lease.listener, nil);
        nw_listener_cancel(lease.listener);
    }
    for (VXTrailerConnectionState *connection in lease.connections.allValues) {
        [self cancelConnection:connection];
    }
    [lease.connections removeAllObjects];
    NSNumber *key = @(leaseID);
    if (self.leases[key] == lease) {
        [self.leases removeObjectForKey:key];
    }
    if (!lease.readyDelivered) {
        for (VXTrailerNetworkReadyBlock pendingCompletion in pendingCompletions) {
            [self deliverReady:lease success:NO port:0 completion:pendingCompletion];
        }
    }
}

- (void)drainLeaseOnQueue:(uint64_t)leaseID state:(VXTrailerLeaseState *)lease {
    if (self.leases[@(leaseID)] != lease || lease.stopping) { return; }
    if (!lease.readyDelivered) {
        // No accepted connection can exist before readiness. Retire pending
        // callbacks normally so a canceled Swift wait cannot remain suspended.
        [self stopLeaseOnQueue:leaseID state:lease];
        return;
    }
    lease.accepting = NO;
    lease.readinessGeneration += 1;
    // No future listener failure callback can be delivered after the handler
    // is detached. Do not retain Swift failure closures for the drain life.
    [lease.readyCompletions removeAllObjects];
    [lease.failureCompletions removeAllObjects];
    if (lease.listener != NULL) {
        nw_listener_set_state_changed_handler(lease.listener, nil);
        nw_listener_set_new_connection_handler(lease.listener, nil);
        nw_listener_cancel(lease.listener);
        lease.listener = nil;
    }
    // Accepted connections remain in the lease dictionary and continue to use
    // the serial owner queue. Once the last one closes, retire the old lease.
    [self retireDrainedLeaseIfEmpty:lease];
}

- (void)retireDrainedLeaseIfEmpty:(VXTrailerLeaseState *)lease {
    if (lease == nil || lease.stopping || lease.accepting || lease.connections.count != 0) {
        return;
    }
    NSNumber *key = @(lease.leaseID);
    if (self.leases[key] == lease) {
        [self.leases removeObjectForKey:key];
    }
}

- (void)listenerState:(nw_listener_state_t)state
                error:(nw_error_t)error
                lease:(VXTrailerLeaseState *)lease {
    (void)error;
    NSNumber *key = @(lease.leaseID);
    if (self.leases[key] != lease || lease.stopping) { return; }
    switch (state) {
        case nw_listener_state_ready: {
            uint16_t port = nw_listener_get_port(lease.listener);
            if (port == 0) {
                [self stopLeaseOnQueue:lease.leaseID state:lease];
                return;
            }
            lease.readyDelivered = YES;
            NSArray *completions = [lease.readyCompletions copy];
            [lease.readyCompletions removeAllObjects];
            for (VXTrailerNetworkReadyBlock completion in completions) {
                [self deliverReady:lease success:YES port:port completion:completion];
            }
            break;
        }
        case nw_listener_state_failed:
        case nw_listener_state_cancelled: {
            NSArray *completions = [lease.readyCompletions copy];
            NSArray *failures = [lease.failureCompletions copy];
            [lease.readyCompletions removeAllObjects];
            [lease.failureCompletions removeAllObjects];
            for (VXTrailerNetworkReadyBlock completion in completions) {
                [self deliverReady:lease success:NO port:0 completion:completion];
            }
            if (lease.readyDelivered) {
                for (VXTrailerNetworkFailureBlock failure in failures) {
                    [self deliverFailure:lease completion:failure];
                }
                [self drainLeaseOnQueue:lease.leaseID state:lease];
            } else {
                [self stopLeaseOnQueue:lease.leaseID state:lease];
            }
            break;
        }
        default:
            break;
    }
}

- (void)deliverFailure:(VXTrailerLeaseState *)lease
            completion:(VXTrailerNetworkFailureBlock)completion {
    if (completion == nil) { return; }
    uint64_t leaseID = lease.leaseID;
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(leaseID);
    });
}

- (void)deliverReady:(VXTrailerLeaseState *)lease
             success:(BOOL)success
                port:(uint16_t)port
          completion:(VXTrailerNetworkReadyBlock)completion {
    if (completion == nil) { return; }
    uint64_t leaseID = lease.leaseID;
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(leaseID, port, success);
    });
}

- (void)acceptConnection:(nw_connection_t)connection lease:(VXTrailerLeaseState *)lease {
    if (self.leases[@(lease.leaseID)] != lease || lease.stopping || !lease.accepting) {
        nw_connection_cancel(connection);
        return;
    }
    VXTrailerConnectionState *state = [[VXTrailerConnectionState alloc] init];
    state.connectionID = self.nextConnectionID++;
    state.leaseID = lease.leaseID;
    state.connection = connection;
    lease.connections[@(state.connectionID)] = state;

    __weak VXTrailerNetworkOwner *weakSelf = self;
    nw_connection_set_queue(state.connection, self.queue);
    nw_connection_set_state_changed_handler(state.connection, ^(nw_connection_state_t connectionState, nw_error_t error) {
        (void)error;
        VXTrailerNetworkOwner *strongSelf = weakSelf;
        if (strongSelf == nil) { return; }
        if (connectionState == nw_connection_state_failed || connectionState == nw_connection_state_cancelled) {
            [strongSelf removeConnection:state];
        }
    });
    nw_connection_start(state.connection);

    uint64_t generation = ++state.headerGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VXTrailerHeaderDeadline * NSEC_PER_SEC)),
                   self.queue, ^{
        VXTrailerNetworkOwner *strongSelf = weakSelf;
        if (strongSelf == nil) { return; }
        if (state.headerGeneration == generation && !state.requestHeaderComplete) {
            [strongSelf cancelConnection:state];
        }
    });
    [self receiveHeaderForConnection:state];
}

- (void)receiveHeaderForConnection:(VXTrailerConnectionState *)state {
    if (![self connectionIsLive:state]) { return; }
    nw_connection_receive(state.connection, 1, 16384, ^(dispatch_data_t content,
                                                         nw_content_context_t context,
                                                         bool isComplete,
                                                         nw_error_t error) {
        (void)context;
        NSData *chunk = VXDataFromDispatchData(content);
        [self receivedHeaderChunk:chunk complete:isComplete error:error connection:state];
    });
}

- (void)receivedHeaderChunk:(NSData *)chunk
                    complete:(BOOL)isComplete
                       error:(nw_error_t)error
                   connection:(VXTrailerConnectionState *)state {
    if (![self connectionIsLive:state]) { return; }
    if (error != NULL) {
        [self cancelConnection:state];
        return;
    }
    if (chunk.length > 0) {
        [state.requestData appendData:chunk];
    }
    NSData *terminator = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange terminatorRange = [state.requestData rangeOfData:terminator options:0 range:NSMakeRange(0, state.requestData.length)];
    if (terminatorRange.location != NSNotFound) {
        state.requestHeaderComplete = YES;
        ++state.headerGeneration;
        NSData *header = [state.requestData subdataWithRange:NSMakeRange(0, terminatorRange.location)];
        [self serveHeader:header connection:state];
        return;
    }
    if (isComplete || state.requestData.length > 64000) {
        [self cancelConnection:state];
        return;
    }
    [self receiveHeaderForConnection:state];
}

- (BOOL)connectionIsLive:(VXTrailerConnectionState *)state {
    VXTrailerLeaseState *lease = self.leases[@(state.leaseID)];
    return lease != nil && lease.connections[@(state.connectionID)] == state && !lease.stopping;
}

- (void)removeConnection:(VXTrailerConnectionState *)state {
    VXTrailerLeaseState *lease = self.leases[@(state.leaseID)];
    if (lease.connections[@(state.connectionID)] == state) {
        [lease.connections removeObjectForKey:@(state.connectionID)];
    }
    [self cancelConnection:state];
    [self retireDrainedLeaseIfEmpty:lease];
}

- (void)cancelConnection:(VXTrailerConnectionState *)state {
    [state.windowTask cancel];
    state.windowTask = nil;
    if (state.connection != NULL) {
        // The state-handler block captures `state` while the state retains
        // the Network connection. Remove the handler before cancellation and
        // clear the strong edge so a cancelled connection cannot keep its
        // request state alive indefinitely.
        nw_connection_set_state_changed_handler(state.connection, nil);
        nw_connection_cancel(state.connection);
        state.connection = nil;
    }
    VXTrailerLeaseState *lease = self.leases[@(state.leaseID)];
    if (lease.connections[@(state.connectionID)] == state) {
        [lease.connections removeObjectForKey:@(state.connectionID)];
    }
    [self retireDrainedLeaseIfEmpty:lease];
}

- (void)serveHeader:(NSData *)header connection:(VXTrailerConnectionState *)state {
    NSString *headerText = [[NSString alloc] initWithData:header encoding:NSUTF8StringEncoding];
    if (headerText == nil) {
        [self closeConnection:state status:@"400 Bad Request"];
        return;
    }
    NSArray<NSString *> *lines = [headerText componentsSeparatedByString:@"\r\n"];
    NSString *requestLine = lines.firstObject;
    NSArray<NSString *> *parts = [requestLine componentsSeparatedByString:@" "];
    if (parts.count < 2) {
        [self closeConnection:state status:@"400 Bad Request"];
        return;
    }
    NSURLComponents *components = [NSURLComponents componentsWithString:[NSString stringWithFormat:@"http://127.0.0.1%@", parts[1]]];
    if (components == nil) {
        [self closeConnection:state status:@"400 Bad Request"];
        return;
    }

    NSURLQueryItem *uItem = nil;
    NSURLQueryItem *mimeItem = nil;
    for (NSURLQueryItem *item in components.queryItems) {
        // Match Swift first(where:): a first nil/malformed item is still
        // authoritative and must not be replaced by a later duplicate.
        if (uItem == nil && [item.name isEqualToString:@"u"]) { uItem = item; }
        if (mimeItem == nil && [item.name isEqualToString:@"mime"]) { mimeItem = item; }
    }
    NSString *encoded = uItem.value;
    NSString *requestedMime = mimeItem.value;
    NSString *mime = ([requestedMime isEqualToString:@"video/mp4"] || [requestedMime isEqualToString:@"audio/mp4"])
        ? requestedMime : @"video/mp4";
    NSString *upstreamString = VXDecodeBase64URL(encoded);
    NSURL *upstream = upstreamString.length > 0 ? [NSURL URLWithString:upstreamString] : nil;
    if (upstream.host.length == 0 || ![upstream.host containsString:@"googlevideo"]) {
        [self closeConnection:state status:@"400 Bad Request"];
        return;
    }
    VXTrailerLeaseState *lease = self.leases[@(state.leaseID)];
    NSString *requestUserAgent = lease.userAgentsByURL[upstream.absoluteString];
    if (requestUserAgent.length == 0) {
        // Only resolver-registered exact upstream identities may be fetched;
        // an arbitrary loopback query must not become an upstream header.
        [self closeConnection:state status:@"403 Forbidden"];
        return;
    }
    state.requestUserAgent = requestUserAgent;
    NSURLComponents *upstreamComponents = [NSURLComponents componentsWithURL:upstream resolvingAgainstBaseURL:NO];
    NSInteger clen = 0;
    for (NSURLQueryItem *item in upstreamComponents.queryItems) {
        if ([item.name isEqualToString:@"clen"]) {
            NSInteger parsed = 0;
            if (VXParseExactInteger(item.value, &parsed)) { clen = parsed; }
            break;
        }
    }
    if (clen <= 0) {
        [self closeConnection:state status:@"404 Not Found"];
        return;
    }

    NSInteger start = 0;
    NSInteger end = clen - 1;
    for (NSString *line in lines) {
        if (![line.lowercaseString hasPrefix:@"range:"]) { continue; }
        NSRange equals = [line rangeOfString:@"="];
        // The first Range header is authoritative even when it has no '=';
        // the Swift parser then sees an empty spec and keeps its defaults.
        NSString *spec = equals.location == NSNotFound
            ? @""
            : [line substringFromIndex:equals.location + 1];
        NSArray<NSString *> *bounds = [spec componentsSeparatedByString:@"-"];
        NSString *first = bounds.firstObject ?: @"";
        NSString *last = bounds.count > 1 ? bounds[1] : @"";
        if (first.length == 0) {
            // Preserve the existing Swift fallback semantics. A valid
            // suffix uses the last N bytes; otherwise fall through to the
            // ordinary start/end parsing, which keeps malformed values at
            // the default full-file range except for an exact numeric end
            // such as the original `-0` behavior.
            NSInteger suffix = 0;
            if (bounds.count > 1 && VXParseExactInteger(last, &suffix) && suffix > 0) {
                start = MAX(0, clen - suffix);
                end = clen - 1;
            } else {
                NSInteger parsedStart = 0;
                if (VXParseExactInteger(first, &parsedStart) && parsedStart >= 0) {
                    start = parsedStart;
                }
                if (bounds.count > 1) {
                    NSInteger parsedEnd = 0;
                    if (VXParseExactInteger(last, &parsedEnd) && parsedEnd >= start) {
                        end = parsedEnd;
                    }
                }
            }
        } else {
            NSInteger parsedStart = 0;
            if (VXParseExactInteger(first, &parsedStart) && parsedStart >= 0) {
                start = parsedStart;
            }
            if (bounds.count > 1) {
                NSInteger parsedEnd = 0;
                if (VXParseExactInteger(last, &parsedEnd) && parsedEnd >= start) {
                    end = parsedEnd;
                }
            }
        }
        break;
    }
    end = MIN(end, clen - 1);
    if (start > end) {
        [self closeConnection:state status:@"416 Range Not Satisfiable"];
        return;
    }

    NSUInteger length = (NSUInteger)(end - start + 1);
    NSString *response = [NSString stringWithFormat:
        @"HTTP/1.1 206 Partial Content\r\nContent-Type: %@\r\nAccept-Ranges: bytes\r\nContent-Range: bytes %ld-%ld/%ld\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
        mime, (long)start, (long)end, (long)clen, (unsigned long)length];
    state.mime = mime;
    state.upstreamURL = upstream;
    state.rangeStart = (NSUInteger)start;
    state.rangeStop = (NSUInteger)end;
    state.rangeEnd = (NSUInteger)end;
    state.promisedLength = length;
    state.bytesSent = 0;
    [self sendData:[response dataUsingEncoding:NSUTF8StringEncoding] connection:state completion:^(BOOL success) {
        if (!success) {
            [self cancelConnection:state];
            return;
        }
        [self streamWindowsForConnection:state position:state.rangeStart sent:0];
    }];
}

- (void)streamWindowsForConnection:(VXTrailerConnectionState *)state
                           position:(NSUInteger)position
                               sent:(NSUInteger)sent {
    if (![self connectionIsLive:state]) { return; }
    if (position > state.rangeEnd) {
        NSLog(@"[trailer] proxy stream complete served=%lu/%lu bytes", (unsigned long)sent, (unsigned long)state.promisedLength);
        [self cancelConnection:state];
        return;
    }
    NSUInteger stop = MIN(position + VXTrailerWindowSize - 1, state.rangeEnd);
    [self fetchWindowForConnection:state position:position stop:stop sent:sent attempt:1];
}

- (void)fetchWindowForConnection:(VXTrailerConnectionState *)state
                         position:(NSUInteger)position
                             stop:(NSUInteger)stop
                              sent:(NSUInteger)sent
                           attempt:(NSUInteger)attempt {
    if (![self connectionIsLive:state] || state.upstreamURL == nil) { return; }
    NSURLComponents *components = [NSURLComponents componentsWithURL:state.upstreamURL resolvingAgainstBaseURL:NO];
    NSMutableArray<NSURLQueryItem *> *items = [components.queryItems mutableCopy] ?: [NSMutableArray array];
    NSIndexSet *rangeIndexes = [items indexesOfObjectsPassingTest:^BOOL(NSURLQueryItem *item, NSUInteger idx, BOOL *stopFlag) {
        return [item.name isEqualToString:@"range"];
    }];
    [items removeObjectsAtIndexes:rangeIndexes];
    [items addObject:[NSURLQueryItem queryItemWithName:@"range" value:[NSString stringWithFormat:@"%lu-%lu", (unsigned long)position, (unsigned long)stop]]];
    components.queryItems = items;
    NSURL *windowURL = components.URL;
    if (windowURL == nil) {
        [self cancelConnection:state];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:windowURL];
    request.timeoutInterval = VXTrailerWindowTimeout;
    VXTrailerLeaseState *lease = self.leases[@(state.leaseID)];
    NSString *ua = state.requestUserAgent.length > 0 ? state.requestUserAgent : lease.userAgent;
    if (ua.length == 0) {
        ua = @"com.google.ios.youtube/21.02.3 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)";
    }
    [request setValue:ua forHTTPHeaderField:@"User-Agent"];
    state.rangeStart = position;
    state.rangeStop = stop;
    state.bytesSent = sent;
    state.attempt = attempt;

    __weak VXTrailerNetworkOwner *weakSelf = self;
    uint64_t connectionID = state.connectionID;
    uint64_t leaseID = state.leaseID;
    state.windowTask = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSData *payload = [data copy] ?: [NSData data];
        NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? (NSHTTPURLResponse *)response : nil;
        NSInteger status = httpResponse == nil ? 0 : httpResponse.statusCode;
        BOOL hasError = error != nil;
        NSInteger errorCode = error == nil ? 0 : error.code;
        VXTrailerNetworkOwner *strongSelf = weakSelf;
        if (strongSelf == nil) { return; }
        dispatch_async(strongSelf.queue, ^{
            [strongSelf windowResponse:payload status:status errorCode:errorCode
                              hasError:hasError
                             leaseID:leaseID connectionID:connectionID attempt:attempt
                             position:position stop:stop sent:sent];
        });
    }];
    [state.windowTask resume];
}

- (void)windowResponse:(NSData *)data
                status:(NSInteger)status
              errorCode:(NSInteger)errorCode
              hasError:(BOOL)hasError
               leaseID:(uint64_t)leaseID
          connectionID:(uint64_t)connectionID
               attempt:(NSUInteger)attempt
              position:(NSUInteger)position
                  stop:(NSUInteger)stop
                  sent:(NSUInteger)sent {
    VXTrailerLeaseState *lease = self.leases[@(leaseID)];
    VXTrailerConnectionState *state = lease.connections[@(connectionID)];
    if (state == nil || ![self connectionIsLive:state]) { return; }
    state.windowTask = nil;
    BOOL ok = !hasError && status >= 200 && status <= 299 && data.length > 0;
    if (!ok) {
        if (attempt < VXTrailerMaxWindowAttempts) {
            NSTimeInterval delay = VXTrailerWindowRetryBaseDelay * (double)attempt;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), self.queue, ^{
                [self fetchWindowForConnection:state position:position stop:stop sent:sent attempt:attempt + 1];
            });
        } else {
            NSLog(@"[trailer] proxy window %lu-%lu gave up after %lu attempts served=%lu/%lu (status=%ld errorCode=%ld hasError=%d)",
                  (unsigned long)position, (unsigned long)stop, (unsigned long)attempt,
                  (unsigned long)sent, (unsigned long)state.promisedLength, (long)status,
                  (long)errorCode, (int)hasError);
            [self cancelConnection:state];
        }
        return;
    }
    NSUInteger requested = stop - position + 1;
    NSData *payload = data.length > requested ? [data subdataWithRange:NSMakeRange(0, requested)] : data;
    if (payload.length < requested) {
        NSLog(@"[trailer] proxy short read window=%lu-%lu requested=%lu got=%lu (resuming from actual)",
              (unsigned long)position, (unsigned long)stop, (unsigned long)requested, (unsigned long)payload.length);
    }
    [self sendData:payload connection:state completion:^(BOOL success) {
        if (!success) {
            [self cancelConnection:state];
            return;
        }
        [self streamWindowsForConnection:state position:position + payload.length sent:sent + payload.length];
    }];
}

- (void)sendData:(NSData *)data
      connection:(VXTrailerConnectionState *)state
       completion:(void (^)(BOOL success))completion {
    if (![self connectionIsLive:state]) {
        completion(NO);
        return;
    }
    NSData *ownedData = [data copy];
    dispatch_data_t dispatchData = dispatch_data_create(ownedData.bytes, ownedData.length, self.queue, ^{
        (void)ownedData;
    });
    nw_connection_send(state.connection, dispatchData, NW_CONNECTION_DEFAULT_STREAM_CONTEXT, false, ^(nw_error_t error) {
        completion(error == NULL);
    });
}

- (void)closeConnection:(VXTrailerConnectionState *)state status:(NSString *)status {
    NSString *response = [NSString stringWithFormat:@"HTTP/1.1 %@\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", status];
    [self sendData:[response dataUsingEncoding:NSUTF8StringEncoding] connection:state completion:^(__unused BOOL success) {
        [self cancelConnection:state];
    }];
}

@end

static NSData *VXDataFromDispatchData(dispatch_data_t content) {
    if (content == NULL) { return [NSData data]; }
    const void *buffer = NULL;
    size_t size = 0;
    dispatch_data_t __attribute__((objc_precise_lifetime)) mapped =
        dispatch_data_create_map(content, &buffer, &size);
    if (mapped == NULL || buffer == NULL || size == 0) {
        return [NSData data];
    }
    // `buffer` is valid only while the mapped dispatch_data_t remains alive.
    // NSData copies the bytes before this scoped owner is released by ARC.
    return [NSData dataWithBytes:buffer length:size];
}

static BOOL VXParseExactInteger(NSString *value, NSInteger *result) {
    if (value.length == 0 || result == NULL) { return NO; }
    NSUInteger length = value.length;
    NSUInteger index = 0;
    BOOL negative = NO;
    unichar first = [value characterAtIndex:0];
    if (first == '+' || first == '-') {
        negative = first == '-';
        index = 1;
    }
    if (index == length) { return NO; }

    // NSScanner's scanInteger accepts leading whitespace and clamps overflow,
    // while the previous Swift Int initializer rejected both. Keep the
    // original fallback matrix by accepting only an optional sign followed by
    // ASCII decimal digits and rejecting overflow before it reaches NSInteger.
    uint64_t magnitude = 0;
    uint64_t limit = (uint64_t)NSIntegerMax + (negative ? 1u : 0u);
    for (; index < length; index += 1) {
        unichar character = [value characterAtIndex:index];
        if (character < '0' || character > '9') { return NO; }
        uint64_t digit = (uint64_t)(character - '0');
        if (magnitude > (limit - digit) / 10u) { return NO; }
        magnitude = magnitude * 10u + digit;
    }
    if (negative && magnitude == (uint64_t)NSIntegerMax + 1u) {
        *result = (NSInteger)(-NSIntegerMax - 1);
    } else {
        *result = negative ? -(NSInteger)magnitude : (NSInteger)magnitude;
    }
    return YES;
}

static NSString *VXDecodeBase64URL(NSString *encoded) {
    if (encoded.length == 0) { return nil; }
    NSMutableString *value = [encoded mutableCopy];
    [value replaceOccurrencesOfString:@"-" withString:@"+" options:0 range:NSMakeRange(0, value.length)];
    [value replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0, value.length)];
    while (value.length % 4 != 0) { [value appendString:@"="]; }
    NSData *data = [[NSData alloc] initWithBase64EncodedString:value options:0];
    return data == nil ? nil : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}
