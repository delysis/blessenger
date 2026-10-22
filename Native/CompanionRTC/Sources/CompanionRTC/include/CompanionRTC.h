#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Receive-only Opus audio and a bounded reliable control channel. No hardware
/// audio unit is opened. Callbacks run on WebRTC/audio threads; callers must
/// enqueue bounded work rather than blocking them.
@interface BGCompanionPeer : NSObject
- (nullable instancetype)initWithICEServers:(NSData *)json
    relayOnly:(BOOL)relayOnly
    message:(void (NS_SWIFT_SENDABLE ^)(NSData *))message
    audio:(void (NS_SWIFT_SENDABLE ^)(NSData *))audio
    candidate:(void (NS_SWIFT_SENDABLE ^)(NSData *))candidate
    state:(void (NS_SWIFT_SENDABLE ^)(NSString *))state
    error:(NSError **)error;
/// One offer per peer; reconnect creates a new peer. PCM callback data is
/// 16 kHz mono signed int16, 160 frames per callback. An already-dispatched
/// callback may race close; consumers must reject obsolete session epochs.
- (void)answerOffer:(NSString *)offer completion:(void (NS_SWIFT_SENDABLE ^)(NSString * _Nullable, NSError * _Nullable))completion;
/// Trickle ICE JSON: candidate, sdpMid, sdpMLineIndex. May precede the offer;
/// a bounded queue is drained after its remote description is accepted.
- (BOOL)addRemoteCandidate:(NSData *)json;
- (BOOL)sendMessage:(NSData *)data;
- (void)close;
@end
NS_ASSUME_NONNULL_END
