#import "WebRTCFactoryBuilder.h"

@implementation WebRTCFactoryBuilder

+ (RTCPeerConnectionFactory *)makeFactory {
    RTCDefaultVideoEncoderFactory *encoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
    RTCDefaultVideoDecoderFactory *decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];

    return [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory
                                                     decoderFactory:decoderFactory];
}

@end
