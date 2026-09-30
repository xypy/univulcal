#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol MNDirectUVCBackendDelegate <NSObject>
- (void)uvcBackendDidStartWithWidth:(NSUInteger)width height:(NSUInteger)height fps:(NSUInteger)fps;
- (void)uvcBackendDidReceiveRGB:(NSData *)rgb width:(NSUInteger)width height:(NSUInteger)height;
- (void)uvcBackendDidLog:(NSString *)message;
- (void)uvcBackendDidFail:(NSString *)message;
@end

@interface MNDirectUVCBackend : NSObject
@property(nonatomic, weak) id<MNDirectUVCBackendDelegate> delegate;
- (void)startWithWidth:(NSUInteger)width height:(NSUInteger)height fps:(NSUInteger)fps;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
