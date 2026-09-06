#import <MediaPlayer/MediaPlayer.h>

/*
 * iPhone OS 2.x exposed this compatibility selector before controlStyle was
 * public. The iOS 10 implementation treats mode 2 as hidden and every other
 * value as the default embedded controls, so express it through the public
 * property instead of requiring the private selector on the current host.
 */
@interface MPMoviePlayerController (LC32MovieControlMode)
- (void)setMovieControlMode:(NSInteger)mode;
@end

@implementation MPMoviePlayerController (LC32MovieControlMode)
- (void)setMovieControlMode:(NSInteger)mode {
    self.controlStyle = mode == 2
        ? MPMovieControlStyleNone
        : MPMovieControlStyleDefault;
}
@end
