#import <Foundation/Foundation.h>

#import <WebRTC/WebRTC.h>

NS_ASSUME_NONNULL_BEGIN

@interface WebRTCFactoryBuilder : NSObject

+ (RTCPeerConnectionFactory *)makeFactory;

+ (void)setPlayoutDelayHintIfSupportedForReceiver:(RTCRtpReceiver *)receiver seconds:(double)seconds;

@end

NS_ASSUME_NONNULL_END
