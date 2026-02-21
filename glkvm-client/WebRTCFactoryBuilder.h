#import <Foundation/Foundation.h>

#import <WebRTC/WebRTC.h>

NS_ASSUME_NONNULL_BEGIN

@interface WebRTCFactoryBuilder : NSObject

+ (RTCPeerConnectionFactory *)makeFactory;

@end

NS_ASSUME_NONNULL_END
