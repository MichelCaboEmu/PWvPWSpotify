// Spotify 9.1.78 already publishes MPMediaItemAnimatedArtwork. Keep its video
// source and both artwork flags enabled together, in either interface.
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "PWLockScreenArtwork.h"

BOOL PWLockScreenArtworkStored(void) {
    if (@available(iOS 26.0, *)) return SGEnabled(PWKeyLockScreenArtwork);
    return NO;
}

BOOL PWLockScreenArtworkEnabled(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ enabled = PWLockScreenArtworkStored(); });
    return enabled;
}

NSString *PWLockScreenArtworkStatus(void) {
    if (@available(iOS 26.0, *)) {
        if (PWLockScreenArtworkStored() != PWLockScreenArtworkEnabled()) return @"Restart Spotify";
        if (!PWLockScreenArtworkEnabled()) return @"Off";
        if (NSProcessInfo.processInfo.lowPowerModeEnabled) return @"Low Power Mode";
        if (UIAccessibilityIsReduceMotionEnabled()) return @"Reduce Motion is on";
        if (!MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys.count) return @"Not supported by iOS";
        NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
        for (NSString *key in MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys) {
            if ([info[key] isKindOfClass:MPMediaItemAnimatedArtwork.class]) return @"Animation supplied by Spotify";
        }
        return @"No animation supplied for this track";
    }
    return @"Needs iOS 26";
}

__attribute__((constructor)) static void PWRegisterLockScreenArtwork(void) {
    NSSet<NSString *> *keys = [NSSet setWithArray:@[
        @"ios-feature-lockscreen.animated_artwork_enabled",
        @"ios-feature-lockscreen.vit_artwork_enabled",
        @"ios-feature-canvas.canvas_enabled",
    ]];
    // Capture launch state before Spotify's flag provider starts. The settings
    // side remains live, so its rows correctly preview changes awaiting restart.
    BOOL enabled = PWLockScreenArtworkEnabled();
    SGRegisterFlagForcer(YES,
        ^id(NSString *key) { return enabled && [keys containsObject:key] ? @YES : nil; },
        ^id(NSString *key) { return PWLockScreenArtworkStored() && [keys containsObject:key] ? @YES : nil; });
}
