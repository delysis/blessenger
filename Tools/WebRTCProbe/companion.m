#import "ProbeSupport.h"
#import "CompanionRTC.h"

// Exercise the actual bridge, with generated input and no hardware device.
int main(int argc, const char **argv) {
  @autoreleasepool {
    BOOL relayOnly=argc==2 && strcmp(argv[1],"--relay")==0;
    NSData *ice=relayOnly?[[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile]:[@"[]" dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *records=[NSJSONSerialization JSONObjectWithData:ice options:0 error:nil];
    if(![records isKindOfClass:NSArray.class])return 5;
    NSMutableArray *servers=[NSMutableArray array];
    for(NSDictionary *record in records)[servers addObject:[[RTCIceServer alloc] initWithURLStrings:record[@"urls"] username:record[@"username"] credential:record[@"credential"]]];
    NSMutableArray *runs=[NSMutableArray array]; BOOL passed=YES;
    for(int run=0;run<3;run++) {
      ToneDevice *source=[ToneDevice new]; source.frequency=440;
      RTCPeerConnectionFactory *factory=[[RTCPeerConnectionFactory alloc] initWithEncoderFactory:nil decoderFactory:nil audioDevice:source];
      PeerObserver *observer=[PeerObserver new];
      RTCConfiguration *config=[RTCConfiguration new]; config.sdpSemantics=RTCSdpSemanticsUnifiedPlan; config.iceServers=servers; if(relayOnly)config.iceTransportPolicy=RTCIceTransportPolicyRelay;
      RTCMediaConstraints *empty=[[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil];
      RTCPeerConnection *sender=[factory peerConnectionWithConfiguration:config constraints:empty delegate:observer];
      RTCMediaConstraints *audio=[[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:@{@"googEchoCancellation":@"false",@"googAutoGainControl":@"false",@"googNoiseSuppression":@"false"}];
      [sender addTrack:[factory audioTrackWithSource:[factory audioSourceWithConstraints:audio] trackId:@"microphone"] streamIds:@[@"microphone"]];
      observer.channel=[sender dataChannelForLabel:@"control" configuration:[RTCDataChannelConfiguration new]]; observer.channel.delegate=observer;
      NSMutableData *captured=[NSMutableData data]; NSObject *lock=[NSObject new];
      NSMutableArray *pending=[NSMutableArray array]; __block BOOL remoteReady=NO;
      __block BOOL malformed=NO; __block NSUInteger received=0;
      __block __weak BGCompanionPeer *weakReceiver;
      NSError *error=nil;
      BGCompanionPeer *receiver=[[BGCompanionPeer alloc] initWithICEServers:ice relayOnly:relayOnly
        message:^(NSData *data){ @synchronized(lock){received++;} [weakReceiver sendMessage:data]; }
        audio:^(NSData *data){ @synchronized(lock){if(data.length!=320)malformed=YES; [captured appendData:data];} }
        candidate:^(NSData *data){
          NSDictionary *value=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
          RTCIceCandidate *candidate=[[RTCIceCandidate alloc] initWithSdp:value[@"candidate"] sdpMLineIndex:[value[@"sdpMLineIndex"] intValue] sdpMid:value[@"sdpMid"]];
          @synchronized(lock){if(remoteReady)[sender addIceCandidate:candidate completionHandler:^(NSError *error){if(error)malformed=YES;}];else [pending addObject:candidate];}
        }
        state:^(NSString *state){} error:&error]; weakReceiver=receiver;
      if(!receiver){fprintf(stderr,"Bridge initialization failed\n");return 2;}
      observer.candidate=^(RTCIceCandidate *candidate){
        NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"candidate":candidate.sdp,@"sdpMid":candidate.sdpMid?:@"",@"sdpMLineIndex":@(candidate.sdpMLineIndex)} options:0 error:nil];
        if(![weakReceiver addRemoteCandidate:json])malformed=YES;
      };
      NSDate *setupStart=[NSDate date];
      setDescription(sender,description(sender,empty,YES),YES);
      dispatch_semaphore_t answered=dispatch_semaphore_create(0);
      __block NSString *answer; __block NSError *answerError;
      [receiver answerOffer:sender.localDescription.sdp completion:^(NSString *sdp,NSError *error){answer=sdp;answerError=error;dispatch_semaphore_signal(answered);}];
      waitFor(answered,"bridge answer");
      if(answerError || !answer){fprintf(stderr,"Bridge answer failed: %s\n",answerError.localizedDescription.UTF8String);return 3;}
      double answerSeconds=-setupStart.timeIntervalSinceNow;
      setDescription(sender,[[RTCSessionDescription alloc] initWithType:RTCSdpTypeAnswer sdp:answer],NO);
      @synchronized(lock){remoteReady=YES;for(RTCIceCandidate *candidate in pending)[sender addIceCandidate:candidate completionHandler:^(NSError *error){if(error)malformed=YES;}];[pending removeAllObjects];}
      NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];
      while(observer.channel.readyState!=RTCDataChannelStateOpen && deadline.timeIntervalSinceNow>0)[NSThread sleepForTimeInterval:.01];
      double connectedSeconds=-setupStart.timeIntervalSinceNow;
      BOOL sent=[observer.channel sendData:[[RTCDataBuffer alloc] initWithData:[@"blessenger-probe" dataUsingEncoding:NSUTF8StringEncoding] isBinary:NO]];
      [NSThread sleepForTimeInterval:2];
      observer.candidate=nil; [receiver close]; [receiver close]; [sender close]; source.running=NO; waitFor(source.ended,"sender shutdown");
      [NSThread sleepForTimeInterval:.05];
      NSData *pcm; NSUInteger messages;
      @synchronized(lock){pcm=[captured copy];messages=received;}
      [NSThread sleepForTimeInterval:.1];
      BOOL stopped; @synchronized(lock){stopped=captured.length==pcm.length;}
      const int16_t *samples=pcm.bytes; NSUInteger count=pcm.length/2, start=count>16000?count-16000:0;
      double re=0,im=0,power=0;
      for(NSUInteger i=start;i<count;i++){double x=samples[i]/32768.;re+=x*cos(2*M_PI*440*i/16000);im+=x*sin(2*M_PI*440*i/16000);power+=x*x;}
      double n=MAX(1,count-start), amplitude=2*hypot(re,im)/n;
      BOOL ok=sent && observer.received && messages==1 && count>=16000 && amplitude>.03 && !malformed && stopped;
      passed &= ok;
      [runs addObject:@{@"answerSeconds":@(answerSeconds),@"connectedSeconds":@(connectedSeconds),@"passed":@(ok),@"samples":@(count),@"amplitude440Hz":@(amplitude),@"rms":@(sqrt(power/n)),@"controlEcho":@(observer.received),@"stopped":@(stopped),@"validFrames":@(!malformed)}];
    }
    NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"passed":@(passed),@"relayOnly":@(relayOnly),@"runs":runs,@"scope":@"Actual CompanionRTC bridge, three sequential trickle-ICE Opus and control sessions, generated input, no app or hardware"} options:NSJSONWritingPrettyPrinted error:nil];
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String); return passed?0:4;
  }
}
