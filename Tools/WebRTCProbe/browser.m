#import "ProbeSupport.h"

static void emit(NSDictionary *value) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
  puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String); fflush(stdout);
}
int main(void) {
  @autoreleasepool {
    RTCInitializeSSL();
    ToneDevice *device = [ToneDevice new]; device.frequency = 880;
    RTCPeerConnectionFactory *factory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:nil decoderFactory:nil audioDevice:device];
    PeerObserver *observer = [PeerObserver new];
    RTCConfiguration *config = [RTCConfiguration new]; config.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    RTCMediaConstraints *empty = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil];
    RTCPeerConnection *peer = [factory peerConnectionWithConfiguration:config constraints:empty delegate:observer];
    RTCMediaConstraints *audio = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:
      @{ @"googEchoCancellation": @"false", @"googAutoGainControl": @"false", @"googNoiseSuppression": @"false" }];
    [peer addTrack:[factory audioTrackWithSource:[factory audioSourceWithConstraints:audio] trackId:@"native"] streamIds:@[@"native"]];
    observer.channel = [peer dataChannelForLabel:@"control" configuration:[RTCDataChannelConfiguration new]];
    observer.channel.delegate = observer;
    setDescription(peer, description(peer, empty, YES), YES); waitFor(observer.gathered, "offer candidates");
    emit(@{ @"type": @"offer", @"sdp": peer.localDescription.sdp });
    char input[262144];
    if (!fgets(input, sizeof(input), stdin) || !strchr(input, '\n')) return 5;
    NSData *data = [NSData dataWithBytes:input length:strlen(input)];
    NSDictionary *answer = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![answer[@"type"] isEqual:@"answer"] || ![answer[@"sdp"] isKindOfClass:NSString.class]) return 6;
    setDescription(peer, [[RTCSessionDescription alloc] initWithType:RTCSdpTypeAnswer sdp:answer[@"sdp"]], NO);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (observer.channel.readyState != RTCDataChannelStateOpen && [deadline timeIntervalSinceNow] > 0) [NSThread sleepForTimeInterval:.01];
    BOOL sent = [observer.channel sendData:[[RTCDataBuffer alloc] initWithData:[@"blessenger-probe" dataUsingEncoding:NSUTF8StringEncoding] isBinary:NO]];
    [NSThread sleepForTimeInterval:3];
    [peer close]; device.running = NO; waitFor(device.ended, "native audio shutdown");
    NSDictionary *audioResult = measure(device.captured, 440, 880);
    BOOL passed = sent && observer.received && [audioResult[@"passed"] boolValue];
    emit(@{ @"passed": @(passed), @"dataChannelEcho": @(sent && observer.received), @"audio": audioResult });
    return passed ? 0 : 7;
  }
}
