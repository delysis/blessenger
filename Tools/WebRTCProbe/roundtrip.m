#import "ProbeSupport.h"
static NSDictionary *gather(PeerObserver *observer, NSString *stage, double limit) {
  NSDate *start = [NSDate date];
  BOOL complete = dispatch_semaphore_wait(observer.gathered, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(limit * NSEC_PER_SEC))) == 0;
  NSDictionary *result = @{ @"stage":stage, @"complete":@(complete), @"seconds":@(-start.timeIntervalSinceNow),
    @"candidates":@(observer.candidateCount), @"firstCandidateSeconds": observer.firstCandidate ? @([observer.firstCandidate timeIntervalSinceDate:start]) : [NSNull null] };
  if (!complete) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"passed":@NO,@"gather":result} options:0 error:nil];
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String); exit(1);
  }
  return result;
}
int main(int argc, const char **argv) {
  @autoreleasepool {
    RTCInitializeSSL();
    ToneDevice *a = [ToneDevice new], *b = [ToneDevice new]; a.frequency = 440; b.frequency = 880;
    RTCPeerConnectionFactory *fa = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:nil decoderFactory:nil audioDevice:a];
    RTCPeerConnectionFactory *fb = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:nil decoderFactory:nil audioDevice:b];
    PeerObserver *oa = [PeerObserver new], *ob = [PeerObserver new]; ob.echo = YES;
    RTCConfiguration *config = [RTCConfiguration new]; config.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    BOOL longGather = argc == 2 && strcmp(argv[1], "--relay-long") == 0;
    BOOL relayOnly = longGather || (argc == 2 && strcmp(argv[1], "--relay") == 0);
    if (relayOnly) {
      NSData *data = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
      NSArray *records = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
      if (![records isKindOfClass:NSArray.class] || records.count == 0 || records.count > 16) return 5;
      NSMutableArray *servers = [NSMutableArray array];
      for (NSDictionary *record in records) {
        if (![record isKindOfClass:NSDictionary.class] || ![record[@"urls"] isKindOfClass:NSArray.class]) return 5;
        [servers addObject:[[RTCIceServer alloc] initWithURLStrings:record[@"urls"] username:record[@"username"] credential:record[@"credential"]]];
      }
      config.iceServers = servers;
      config.iceTransportPolicy = RTCIceTransportPolicyRelay;
    }
    RTCMediaConstraints *empty = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil];
    RTCPeerConnection *pa = [fa peerConnectionWithConfiguration:config constraints:empty delegate:oa];
    RTCPeerConnection *pb = [fb peerConnectionWithConfiguration:config constraints:empty delegate:ob];
    RTCMediaConstraints *audio = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:
      @{ @"googEchoCancellation": @"false", @"googAutoGainControl": @"false", @"googNoiseSuppression": @"false" }];
    [pa addTrack:[fa audioTrackWithSource:[fa audioSourceWithConstraints:audio] trackId:@"a"] streamIds:@[@"a"]];
    [pb addTrack:[fb audioTrackWithSource:[fb audioSourceWithConstraints:audio] trackId:@"b"] streamIds:@[@"b"]];
    oa.channel = [pa dataChannelForLabel:@"control" configuration:[RTCDataChannelConfiguration new]]; oa.channel.delegate = oa;
    setDescription(pa, description(pa, empty, YES), YES); NSDictionary *offerGather = gather(oa, @"offer", longGather ? 30 : 5);
    setDescription(pb, pa.localDescription, NO);
    setDescription(pb, description(pb, empty, NO), YES); NSDictionary *answerGather = gather(ob, @"answer", longGather ? 30 : 5);
    setDescription(pa, pb.localDescription, NO);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (oa.channel.readyState != RTCDataChannelStateOpen && [deadline timeIntervalSinceNow] > 0) [NSThread sleepForTimeInterval:.01];
    BOOL sent = [oa.channel sendData:[[RTCDataBuffer alloc] initWithData:[@"blessenger-probe" dataUsingEncoding:NSUTF8StringEncoding] isBinary:NO]];
    [NSThread sleepForTimeInterval:2];
    [pa close]; [pb close];
    a.running = NO; b.running = NO; waitFor(a.ended, "audio A shutdown"); waitFor(b.ended, "audio B shutdown");
    NSDictionary *ma = measure(a.captured, 880, 440), *mb = measure(b.captured, 440, 880);
    BOOL passed = sent && oa.received && ob.received && [ma[@"passed"] boolValue] && [mb[@"passed"] boolValue];
    NSDictionary *receipt = @{ @"passed": @(passed), @"dataChannelEcho": @(sent && oa.received && ob.received), @"receiverA": ma, @"receiverB": mb,
      @"offerGather":offerGather, @"answerGather":answerGather, @"diagnosticLongGather":@(longGather), @"relayOnly": @(relayOnly), @"scope": relayOnly ? @"Two native peers, relay-only ICE, bidirectional Opus and control echo; no hardware, browser or call integration" : @"Two native peers, host ICE, bidirectional Opus PCM and data-channel echo; no audio hardware, browser, TURN or app integration" };
    NSData *json = [NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingPrettyPrinted error:nil];
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    return passed ? 0 : 4;
  }
}
