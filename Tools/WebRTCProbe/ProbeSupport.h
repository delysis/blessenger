#pragma once
#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>
#import <mach/mach_time.h>
#import "RTCAudioDevice.h"
#include <math.h>

// Diagnostic audio device: dedicated clock thread, generated input, retained
// decoded output. No Core Audio hardware unit, microphone or speaker is opened.
@interface ToneDevice : NSObject <RTCAudioDevice>
@property(atomic) BOOL initialized, running, playing, recording;
@property(atomic, strong) id<RTCAudioDeviceDelegate> delegate;
@property double frequency;
@property(strong) NSMutableData *captured;
@property(strong) dispatch_semaphore_t ended;
@end
@implementation ToneDevice
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
  self.delegate = delegate; self.initialized = YES; self.running = YES;
  self.captured = [NSMutableData data]; self.ended = dispatch_semaphore_create(0);
  NSThread *thread = [[NSThread alloc] initWithBlock:^{
    uint64_t offset = 0;
    while (self.running) {
      @autoreleasepool {
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:.01];
        id<RTCAudioDeviceDelegate> delegate = self.delegate;
        AudioTimeStamp stamp = {0}; stamp.mSampleTime = offset; stamp.mHostTime = mach_absolute_time();
        stamp.mFlags = kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid;
        AudioUnitRenderActionFlags flags = 0;
        int16_t input[480], output[480] = {0};
        AudioBufferList in = { .mNumberBuffers = 1, .mBuffers = {{1, sizeof(input), input}} };
        AudioBufferList out = { .mNumberBuffers = 1, .mBuffers = {{1, sizeof(output), output}} };
        if (self.recording && delegate) {
          for (int i = 0; i < 480; ++i) input[i] = (int16_t)(6000 * sin(2 * M_PI * self.frequency * (offset + i) / 48000));
          delegate.deliverRecordedData(&flags, &stamp, 0, 480, &in, NULL, nil);
        }
        if (self.playing && delegate) {
          delegate.getPlayoutData(&flags, &stamp, 0, 480, &out);
          [self.captured appendBytes:output length:sizeof(output)];
        }
        offset += 480;
        [NSThread sleepUntilDate:deadline];
      }
    }
    dispatch_semaphore_signal(self.ended);
  }];
  thread.name = @"Blessenger.WebRTC.ProbeAudio"; [thread start];
  return YES;
}
- (BOOL)terminateDevice { self.running = NO; self.delegate = nil; self.initialized = NO; return YES; }
- (BOOL)isPlayoutInitialized { return YES; }
- (BOOL)initializePlayout { return YES; }
- (BOOL)isPlaying { return self.playing; }
- (BOOL)startPlayout { self.playing = YES; return YES; }
- (BOOL)stopPlayout { self.playing = NO; return YES; }
- (BOOL)isRecordingInitialized { return YES; }
- (BOOL)initializeRecording { return YES; }
- (BOOL)isRecording { return self.recording; }
- (BOOL)startRecording { self.recording = YES; return YES; }
- (BOOL)stopRecording { self.recording = NO; return YES; }
@end

@interface PeerObserver : NSObject <RTCPeerConnectionDelegate, RTCDataChannelDelegate>
@property(strong) dispatch_semaphore_t gathered;
@property(strong) RTCDataChannel *channel;
@property(atomic) BOOL received;
@property BOOL echo;
@property(copy) void (^candidate)(RTCIceCandidate *);
@property(atomic) NSInteger candidateCount;
@property(atomic, strong) NSDate *firstCandidate;
@end
@implementation PeerObserver
- (instancetype)init { if ((self = [super init])) self.gathered = dispatch_semaphore_create(0); return self; }
- (void)peerConnection:(RTCPeerConnection *)peer didChangeIceGatheringState:(RTCIceGatheringState)state {
  if (state == RTCIceGatheringStateComplete) dispatch_semaphore_signal(self.gathered);
}
- (void)peerConnection:(RTCPeerConnection *)peer didOpenDataChannel:(RTCDataChannel *)channel {
  self.channel = channel; channel.delegate = self;
}
- (void)dataChannelDidChangeState:(RTCDataChannel *)channel {}
- (void)dataChannel:(RTCDataChannel *)channel didReceiveMessageWithBuffer:(RTCDataBuffer *)buffer {
  NSString *text = [[NSString alloc] initWithData:buffer.data encoding:NSUTF8StringEncoding];
  if ([text isEqualToString:@"blessenger-probe"]) {
    self.received = YES;
    if (self.echo) [channel sendData:buffer];
  }
}
- (void)peerConnection:(RTCPeerConnection *)peer didChangeSignalingState:(RTCSignalingState)state {}
- (void)peerConnection:(RTCPeerConnection *)peer didAddStream:(RTCMediaStream *)stream {}
- (void)peerConnection:(RTCPeerConnection *)peer didRemoveStream:(RTCMediaStream *)stream {}
- (void)peerConnectionShouldNegotiate:(RTCPeerConnection *)peer {}
- (void)peerConnection:(RTCPeerConnection *)peer didChangeIceConnectionState:(RTCIceConnectionState)state {}
- (void)peerConnection:(RTCPeerConnection *)peer didGenerateIceCandidate:(RTCIceCandidate *)candidate { self.candidateCount++; if (!self.firstCandidate) self.firstCandidate = [NSDate date]; void (^callback)(RTCIceCandidate *)=self.candidate; if(callback)callback(candidate); }
- (void)peerConnection:(RTCPeerConnection *)peer didRemoveIceCandidates:(NSArray<RTCIceCandidate *> *)candidates {}
@end

static void waitFor(dispatch_semaphore_t semaphore, const char *stage) {
  if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) {
    fprintf(stderr, "Timeout: %s\n", stage); exit(1);
  }
}
static void setDescription(RTCPeerConnection *peer, RTCSessionDescription *description, BOOL local) {
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  void (^completion)(NSError *) = ^(NSError *error) {
    if (error) { fprintf(stderr, "SDP error: %s\n", error.localizedDescription.UTF8String); exit(2); }
    dispatch_semaphore_signal(done);
  };
  if (local) [peer setLocalDescription:description completionHandler:completion];
  else [peer setRemoteDescription:description completionHandler:completion];
  waitFor(done, "set description");
}
static RTCSessionDescription *description(RTCPeerConnection *peer, RTCMediaConstraints *constraints, BOOL offer) {
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  __block RTCSessionDescription *result;
  void (^completion)(RTCSessionDescription *, NSError *) = ^(RTCSessionDescription *value, NSError *error) {
    if (error || !value) { fprintf(stderr, "Cannot create SDP\n"); exit(3); }
    result = value; dispatch_semaphore_signal(done);
  };
  if (offer) [peer offerForConstraints:constraints completionHandler:completion];
  else [peer answerForConstraints:constraints completionHandler:completion];
  waitFor(done, "create description"); return result;
}
static NSDictionary *measure(NSData *data, double expected, double own) {
  const int16_t *pcm = data.bytes; NSUInteger count = data.length / 2;
  double power = 0, re = 0, im = 0, ownRe = 0, ownIm = 0;
  NSUInteger start = count > 48000 ? count - 48000 : 0;
  for (NSUInteger i = start; i < count; i++) {
    double x = pcm[i] / 32768.0; power += x * x;
    re += x * cos(2 * M_PI * expected * i / 48000); im += x * sin(2 * M_PI * expected * i / 48000);
    ownRe += x * cos(2 * M_PI * own * i / 48000); ownIm += x * sin(2 * M_PI * own * i / 48000);
  }
  double n = MAX(1, count - start), amplitude = 2 * hypot(re, im) / n;
  double ownAmplitude = 2 * hypot(ownRe, ownIm) / n;
  BOOL passed = count >= 48000 && sqrt(power / n) > .02 && amplitude > .03 && amplitude > ownAmplitude * 10;
  return @{ @"passed": @(passed), @"samples": @(count), @"rms": @(sqrt(power/n)),
            @"expectedHz": @(expected), @"amplitude": @(amplitude), @"ownToneAmplitude": @(ownAmplitude) };
}
