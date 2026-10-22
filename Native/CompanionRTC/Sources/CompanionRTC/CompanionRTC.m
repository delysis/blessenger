#import "CompanionRTC.h"
#import <WebRTC/WebRTC.h>
#import <mach/mach_time.h>
#import "RTCAudioDevice.h"

static NSError *failure(NSString *text) {
  return [NSError errorWithDomain:@"Blessenger.WebRTC" code:1 userInfo:@{NSLocalizedDescriptionKey:text}];
}

@interface RemoteDevice : NSObject <RTCAudioDevice>
@property(atomic) BOOL initialized, running, playing;
@property(atomic, strong) id<RTCAudioDeviceDelegate> delegate;
@property(atomic, copy) void (^audio)(NSData *);
@end
@implementation RemoteDevice
- (double)deviceInputSampleRate { return 16000; }
- (double)deviceOutputSampleRate { return 16000; }
- (NSTimeInterval)inputIOBufferDuration { return .01; }
- (NSTimeInterval)outputIOBufferDuration { return .01; }
- (NSInteger)inputNumberOfChannels { return 1; }
- (NSInteger)outputNumberOfChannels { return 1; }
- (NSTimeInterval)inputLatency { return 0; }
- (NSTimeInterval)outputLatency { return 0; }
- (BOOL)isInitialized { return self.initialized; }
- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate {
  self.delegate=delegate; self.initialized=YES; self.running=YES;
  NSThread *thread=[[NSThread alloc] initWithBlock:^{
    // This device has no hardware audio callback to keep the process awake.
    // An ordinary background timer can be coalesced to ~100 ms, starving Opus.
    // Scope the precision request to the peer's audio thread, including teardown.
    id activity=[NSProcessInfo.processInfo beginActivityWithOptions:
      NSActivityUserInitiatedAllowingIdleSystemSleep|NSActivityLatencyCritical
      reason:@"WebRTC audio capture"];
    uint64_t samples=0;
    mach_timebase_info_data_t timebase; mach_timebase_info(&timebase);
    const double milliseconds=(double)timebase.numer/timebase.denom/1e6;
    uint64_t first=mach_absolute_time(), frames=0, workTicks=0, sleepTicks=0, maxWork=0, maxSleep=0;
    const uint64_t interval=(uint64_t)(10.0/milliseconds);
    uint64_t deadline=first;
    while (self.running) {
      @autoreleasepool {
        uint64_t tick=mach_absolute_time();
        id<RTCAudioDeviceDelegate> delegate=self.delegate;
        void (^callback)(NSData *)=self.audio;
        if (self.playing && delegate && callback) {
          int16_t pcm[160]={0}; AudioBufferList buffer={.mNumberBuffers=1,.mBuffers={{1,sizeof(pcm),pcm}}};
          AudioTimeStamp stamp={0}; stamp.mSampleTime=samples; stamp.mHostTime=mach_absolute_time();
          stamp.mFlags=kAudioTimeStampSampleTimeValid|kAudioTimeStampHostTimeValid;
          AudioUnitRenderActionFlags flags=0;
          OSStatus status=delegate.getPlayoutData(&flags,&stamp,0,160,&buffer);
          if (status==noErr && self.running) { callback([NSData dataWithBytes:pcm length:sizeof(pcm)]); frames++; }
        }
        uint64_t work=mach_absolute_time()-tick; workTicks+=work; maxWork=MAX(maxWork,work);
        uint64_t sleep=mach_absolute_time();
        // Anchor to the sample clock, not the previous wakeup: timer lateness
        // must not accumulate into progressively slower microphone delivery.
        deadline+=interval;
        if (deadline<=sleep) deadline=sleep+interval; // Never burst stale frames.
        samples+=160; mach_wait_until(deadline);
        sleep=mach_absolute_time()-sleep; sleepTicks+=sleep; maxSleep=MAX(maxSleep,sleep);
      }
    }
    NSLog(@"Blessenger remote audio clock: frames=%llu elapsed_ms=%.3f work_ms=%.3f sleep_ms=%.3f max_work_ms=%.3f max_sleep_ms=%.3f",
          frames,(mach_absolute_time()-first)*milliseconds,workTicks*milliseconds,sleepTicks*milliseconds,maxWork*milliseconds,maxSleep*milliseconds);
    [NSProcessInfo.processInfo endActivity:activity];
  }];
  thread.name=@"Blessenger.RemotePCM"; [thread start]; return YES;
}
- (BOOL)terminateDevice { self.running=NO; self.delegate=nil; self.initialized=NO; return YES; }
- (BOOL)isPlayoutInitialized { return YES; }
- (BOOL)initializePlayout { return YES; }
- (BOOL)isPlaying { return self.playing; }
- (BOOL)startPlayout { self.playing=YES; return YES; }
- (BOOL)stopPlayout { self.playing=NO; return YES; }
- (BOOL)isRecordingInitialized { return YES; }
- (BOOL)initializeRecording { return YES; }
- (BOOL)isRecording { return NO; }
- (BOOL)startRecording { return YES; }
- (BOOL)stopRecording { return YES; }
@end

@interface BGCompanionPeer () <RTCPeerConnectionDelegate,RTCDataChannelDelegate>
@property(strong) RTCPeerConnectionFactory *factory;
@property(strong) RTCPeerConnection *peer;
@property(strong) RemoteDevice *device;
@property(strong) RTCDataChannel *channel;
@property(copy) void (^message)(NSData *);
@property(copy) void (^state)(NSString *);
@property(copy) void (^candidate)(NSData *);
@property(strong) NSMutableArray<RTCIceCandidate *> *pendingCandidates;
@property BOOL remoteReady;
@property NSUInteger receivedCandidates;
@property(strong) dispatch_queue_t candidateQueue;
@property(copy) void (^answer)(NSString *,NSError *);
@property(strong) NSUUID *negotiation;
@property BOOL closed;
@property BOOL offered, localReady;
@end
@implementation BGCompanionPeer
- (instancetype)initWithICEServers:(NSData *)json relayOnly:(BOOL)relayOnly message:(void (^)(NSData *))message audio:(void (^)(NSData *))audio candidate:(void (^)(NSData *))candidate state:(void (^)(NSString *))state error:(NSError **)error {
  if (!(self=[super init])) return nil;
  NSArray *records=[NSJSONSerialization JSONObjectWithData:json options:0 error:error];
  if (![records isKindOfClass:NSArray.class] || records.count>16) { if(error)*error=failure(@"Invalid ICE server configuration."); return nil; }
  NSMutableArray *servers=[NSMutableArray array];
  for (id record in records) {
    if (![record isKindOfClass:NSDictionary.class] || ![record[@"urls"] isKindOfClass:NSArray.class]) { if(error)*error=failure(@"Invalid ICE server."); return nil; }
    NSArray *urls=record[@"urls"];
    if (urls.count==0 || urls.count>8) { if(error)*error=failure(@"Invalid ICE URLs."); return nil; }
    for (id url in urls) if (![url isKindOfClass:NSString.class] || [url length]>2048 || !([url hasPrefix:@"stun:"] || [url hasPrefix:@"turn:"] || [url hasPrefix:@"turns:"])) { if(error)*error=failure(@"Invalid ICE URL."); return nil; }
    NSString *username=[record[@"username"] isKindOfClass:NSString.class]?record[@"username"]:@"";
    NSString *credential=[record[@"credential"] isKindOfClass:NSString.class]?record[@"credential"]:@"";
    [servers addObject:[[RTCIceServer alloc] initWithURLStrings:urls username:username credential:credential]];
  }
  static dispatch_once_t once; dispatch_once(&once,^{RTCInitializeSSL();});
  self.message=message; self.state=state; self.device=[RemoteDevice new]; self.device.audio=audio;
  self.candidate=candidate; self.pendingCandidates=[NSMutableArray array];
  self.candidateQueue=dispatch_queue_create("blessenger.rtc.candidates", DISPATCH_QUEUE_SERIAL);
  self.factory=[[RTCPeerConnectionFactory alloc] initWithEncoderFactory:nil decoderFactory:nil audioDevice:self.device];
  RTCConfiguration *config=[RTCConfiguration new]; config.sdpSemantics=RTCSdpSemanticsUnifiedPlan; config.iceServers=servers;
  if(relayOnly)config.iceTransportPolicy=RTCIceTransportPolicyRelay;
  RTCMediaConstraints *constraints=[[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil];
  self.peer=[self.factory peerConnectionWithConfiguration:config constraints:constraints delegate:self];
  if (!self.peer) { if(error)*error=failure(@"Could not create WebRTC peer."); [self close]; return nil; }
  return self;
}
- (void)finishAnswer:(NSError *)error {
  void (^callback)(NSString *,NSError *); NSString *sdp;
  @synchronized(self) {
    if(!error && !self.localReady)return;
    callback=self.answer; self.answer=nil; self.negotiation=nil;
  }
  if(!error)sdp=self.peer.localDescription.sdp;
  if(!error && !sdp.length)error=failure(@"Missing local session description.");
  if(callback)callback(error?nil:sdp,error);
}
- (BOOL)isNegotiating:(NSUUID *)generation {
  @synchronized(self) { return !self.closed && [self.negotiation isEqual:generation]; }
}
- (void)answerOffer:(NSString *)offer completion:(void (^)(NSString *,NSError *))completion {
  NSUUID *generation=[NSUUID UUID];
  @synchronized(self) {
    if(self.closed || self.offered || offer.length>262144 || ![offer hasPrefix:@"v=0"]) { completion(nil,failure(@"Offer is invalid or peer is busy.")); return; }
    self.offered=YES; self.answer=completion; self.negotiation=generation;
  }
  __weak BGCompanionPeer *weak=self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
    BGCompanionPeer *strong=weak; if(!strong)return;
    @synchronized(strong) { if(![strong.negotiation isEqual:generation])return; }
    [strong finishAnswer:failure(@"ICE negotiation timed out.")];
    [strong close];
  });
  [self.peer setRemoteDescription:[[RTCSessionDescription alloc] initWithType:RTCSdpTypeOffer sdp:offer] completionHandler:^(NSError *error){
    BGCompanionPeer *strong=weak; if(![strong isNegotiating:generation])return;
    if(error){[strong finishAnswer:error];return;}
    NSArray *pending;
    @synchronized(strong) {
      strong.remoteReady=YES;
      pending=[strong.pendingCandidates copy];
      [strong.pendingCandidates removeAllObjects];
    }
    for(RTCIceCandidate *candidate in pending)[strong admitCandidate:candidate];
    RTCMediaConstraints *constraints=[[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil];
    [strong.peer answerForConstraints:constraints completionHandler:^(RTCSessionDescription *answer,NSError *error){
      BGCompanionPeer *strong=weak;if(![strong isNegotiating:generation])return;
      if(error){[strong finishAnswer:error];return;}
      [strong.peer setLocalDescription:answer completionHandler:^(NSError *error){
        BGCompanionPeer *strong=weak;if(![strong isNegotiating:generation])return;
        @synchronized(strong) { strong.localReady=!error; }
        [strong finishAnswer:error];
      }];
    }];
  }];
}
- (void)admitCandidate:(RTCIceCandidate *)candidate {
  __weak BGCompanionPeer *weak=self;
  dispatch_async(self.candidateQueue, ^{
   BGCompanionPeer *owner=weak; RTCPeerConnection *peer;
   @synchronized(owner){peer=owner.closed?nil:owner.peer;}
   [peer addIceCandidate:candidate completionHandler:^(NSError *error){
    if(!error)return;
    BGCompanionPeer *strong=weak; void (^callback)(NSString *);
    @synchronized(strong){callback=strong.closed?nil:strong.state;}
    if(callback)callback(@"failed");
   }];
  });
}
- (BOOL)addRemoteCandidate:(NSData *)json {
  if(json.length>16384)return NO;
  NSDictionary *value=[NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
  if(![value isKindOfClass:NSDictionary.class])return NO;
  NSString *sdp=value[@"candidate"], *mid=value[@"sdpMid"];
  NSNumber *line=value[@"sdpMLineIndex"];
  if(![sdp isKindOfClass:NSString.class] || ![sdp hasPrefix:@"candidate:"] || sdp.length>8192 ||
     ![mid isKindOfClass:NSString.class] || mid.length>256 ||
     ![line isKindOfClass:NSNumber.class] || line.doubleValue!=line.intValue || line.intValue<0 || line.intValue>32)return NO;
  RTCIceCandidate *candidate=[[RTCIceCandidate alloc] initWithSdp:sdp sdpMLineIndex:line.intValue sdpMid:mid];
  BOOL admit;
  @synchronized(self) {
    if(self.closed || self.receivedCandidates>=256 || (!self.remoteReady && self.pendingCandidates.count>=64))return NO;
    self.receivedCandidates++;
    admit=self.remoteReady;
    if(!admit)[self.pendingCandidates addObject:candidate];
  }
  if(admit)[self admitCandidate:candidate];
  return YES;
}
- (BOOL)sendMessage:(NSData *)data {
  RTCDataChannel *channel;
  @synchronized(self) {
    if(self.closed || data.length>65536)return NO;
    channel=self.channel;
  }
  if(channel.readyState!=RTCDataChannelStateOpen || channel.bufferedAmount>524288)return NO;
  return [channel sendData:[[RTCDataBuffer alloc] initWithData:data isBinary:NO]];
}
- (void)close {
  RTCPeerConnection *peer;
  @synchronized(self) { if(self.closed)return; self.closed=YES; peer=self.peer; self.message=nil; self.state=nil; self.candidate=nil; [self.pendingCandidates removeAllObjects]; }
  [self finishAnswer:failure(@"Peer closed.")];
  self.device.audio=nil; self.device.running=NO;
  [peer close];
}
- (void)dealloc { [self close]; }
- (void)peerConnection:(RTCPeerConnection *)peer didOpenDataChannel:(RTCDataChannel *)channel {
  BOOL reject;
  @synchronized(self) {
    reject=self.closed || self.channel || ![channel.label isEqual:@"control"];
    if(!reject)self.channel=channel;
  }
  if(reject)[channel close]; else channel.delegate=self;
}
- (void)dataChannelDidChangeState:(RTCDataChannel *)channel {
  void (^callback)(NSString *); @synchronized(self){callback=self.state;}
  if(callback)callback(channel.readyState==RTCDataChannelStateOpen?@"open":channel.readyState==RTCDataChannelStateClosed?@"closed":@"connecting");
}
- (void)dataChannel:(RTCDataChannel *)channel didReceiveMessageWithBuffer:(RTCDataBuffer *)buffer {
  if(buffer.data.length>65536 || buffer.isBinary){[self close];return;}
  void (^callback)(NSData *); @synchronized(self){callback=self.message;}
  if(callback)callback(buffer.data);
}
- (void)peerConnection:(RTCPeerConnection *)peer didChangeIceGatheringState:(RTCIceGatheringState)state {}
- (void)peerConnection:(RTCPeerConnection *)peer didChangeIceConnectionState:(RTCIceConnectionState)state {
  if(state==RTCIceConnectionStateFailed || state==RTCIceConnectionStateDisconnected){void (^callback)(NSString *);@synchronized(self){callback=self.state;}if(callback)callback(state==RTCIceConnectionStateFailed?@"failed":@"disconnected");}
}
- (void)peerConnection:(RTCPeerConnection *)peer didChangeSignalingState:(RTCSignalingState)state {}
- (void)peerConnection:(RTCPeerConnection *)peer didAddStream:(RTCMediaStream *)stream {}
- (void)peerConnection:(RTCPeerConnection *)peer didRemoveStream:(RTCMediaStream *)stream {}
- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peer {}
- (void)peerConnection:(RTCPeerConnection *)peer didGenerateIceCandidate:(RTCIceCandidate *)candidate {
  void (^callback)(NSData *); @synchronized(self){callback=self.closed?nil:self.candidate;}
  if(!callback)return;
  NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"candidate":candidate.sdp,@"sdpMid":candidate.sdpMid?:@"",@"sdpMLineIndex":@(candidate.sdpMLineIndex)} options:0 error:nil];
  if(json.length<=16384)dispatch_async(self.candidateQueue, ^{ callback(json); });
}
- (void)peerConnection:(RTCPeerConnection *)peer didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {}
@end
