#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>
#import "RTCAudioDevice.h"

@interface ProbeDevice : NSObject <RTCAudioDevice>
@property(nonatomic) BOOL initialized;
@property(nonatomic) NSUInteger initializations;
@property(nonatomic, strong) id<RTCAudioDeviceDelegate> delegate;
@end
@implementation ProbeDevice
- (double)deviceInputSampleRate { return 48000; }
- (double)deviceOutputSampleRate { return 48000; }
- (NSTimeInterval)inputIOBufferDuration { return .01; }
- (NSTimeInterval)outputIOBufferDuration { return .01; }
- (NSInteger)inputNumberOfChannels { return 1; }
- (NSInteger)outputNumberOfChannels { return 1; }
- (NSTimeInterval)inputLatency { return 0; }
- (NSTimeInterval)outputLatency { return 0; }
- (BOOL)isInitialized { return self.initialized; }
- (BOOL)initializeWithDelegate:(id<RTCAudioDeviceDelegate>)delegate {
  self.delegate = delegate; self.initialized = YES; self.initializations++;
  return YES;
}
- (BOOL)terminateDevice { self.delegate = nil; self.initialized = NO; return YES; }
- (BOOL)isPlayoutInitialized { return YES; }
- (BOOL)initializePlayout { return YES; }
- (BOOL)isPlaying { return NO; }
- (BOOL)startPlayout { return YES; }
- (BOOL)stopPlayout { return YES; }
- (BOOL)isRecordingInitialized { return YES; }
- (BOOL)initializeRecording { return YES; }
- (BOOL)isRecording { return NO; }
- (BOOL)startRecording { return YES; }
- (BOOL)stopRecording { return YES; }
@end
int main(void) {
  @autoreleasepool {
    RTCInitializeSSL();
    ProbeDevice *device = [ProbeDevice new];
    RTCPeerConnectionFactory *factory = [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:nil decoderFactory:nil audioDevice:device];
    RTCConfiguration *configuration = [RTCConfiguration new];
    configuration.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    RTCMediaConstraints *constraints = [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil];
    RTCPeerConnection *peer = [factory peerConnectionWithConfiguration:configuration constraints:constraints delegate:nil];
    RTCAudioTrack *track = [factory audioTrackWithTrackId:@"probe"];
    [peer addTrack:track streamIds:@[@"probe"]];
    if (!factory || device.initializations != 1 || !device.delegate) {
      fprintf(stderr, "FAIL custom device not initialized\n"); return 1;
    }
    if (!device.delegate.deliverRecordedData || !device.delegate.getPlayoutData) {
      fprintf(stderr, "FAIL missing PCM callbacks\n"); return 2;
    }
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    __block BOOL opus = NO;
    [peer offerForConstraints:constraints completionHandler:^(RTCSessionDescription *description, NSError *error) {
      opus = !error && [description.sdp containsString:@"opus/48000/2"] && [description.sdp containsString:@"m=audio"];
      dispatch_semaphore_signal(completed);
    }];
    if (dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) || !opus) {
      fprintf(stderr, "FAIL Opus offer unavailable\n"); return 3;
    }
    [peer close];
    printf("PASS macOS peer initializes custom audio device and supplies PCM input/output callbacks and produces an Opus audio offer; no hardware audio opened.\n");
  }
  return 0;
}
