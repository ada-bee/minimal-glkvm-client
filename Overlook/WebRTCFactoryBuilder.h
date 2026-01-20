#import <Foundation/Foundation.h>

#import <WebRTC/WebRTC.h>

#import "RTCAudioDeviceShim.h"

NS_ASSUME_NONNULL_BEGIN

@interface WebRTCFactoryBuilder : NSObject

+ (RTCPeerConnectionFactory *)makeFactoryWithAudioDevice:(nullable id<RTCAudioDevice>)audioDevice;

+ (void)setPlayoutDelayHintIfSupportedForReceiver:(RTCRtpReceiver *)receiver seconds:(double)seconds;

@end

NS_ASSUME_NONNULL_END
