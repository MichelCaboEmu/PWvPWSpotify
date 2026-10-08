#import "PWDownloads.h"
#import "Core/SGCore.h"
#import "Core/PWDiagnostics.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Navigation/Links.h"
#import <objc/message.h>

// All selectors and dictionary keys checked in the 9.1.78 executable.
@protocol PWSpotifyLocalSettings <NSObject>
- (void)enableDocumentsFolderAccess;
- (BOOL)enabled;
@end
@interface NSObject (PWSpotifyLocalConstructors)
- (id)initWithDictionary:(NSDictionary *)dictionary;
- (id)provideLocalFilesSettingsModel;
- (id)playContext:(id)context options:(id)options;
- (id)pause:(id)options;
- (id)resume:(id)options;
@end
static __weak id<PWSpotifyLocalSettings> pw_localSettings;
BOOL PWNativeLocalPlayback(void) { return [SGURIString(SGPlayerState().track.URI) hasPrefix:@"spotify:local:"]; }

// The native scanner can rebuild a track without our context metadata. Restore
// only its local cover reference; Spotify's SPTLocalAVAssetImageLoaderRequest
// reads the embedded picture and delivers it to its own views and queue.
%hook SPTPlayerTrack
- (NSDictionary *)metadata {
    NSDictionary *original = %orig;
    NSURL *image = [PWDownloadsBridge nativeArtworkURLForURI:SGURIString([(SPTPlayerTrack *)self URI]) ?: @""];
    if (!image) return original;
    NSMutableDictionary *metadata = [original mutableCopy] ?: [NSMutableDictionary new];
    for (NSString *key in @[@"image_url", @"image_small_url", @"image_large_url", @"image_xlarge_url"]) metadata[key] = image.absoluteString;
    return metadata;
}
- (NSURL *)imageURL {
    NSURL *image = [PWDownloadsBridge nativeArtworkURLForURI:SGURIString([(SPTPlayerTrack *)self URI]) ?: @""];
    return image ?: %orig;
}
%end

@interface PWNativeStateObserver : NSObject <SGPlayerStateObserver>
@end
@implementation PWNativeStateObserver
- (void)playerStateDidChange:(SPTPlayerState *)state {
    [PWDownloadsBridge nativePlaybackState:@{@"uri":SGURIString(state.track.URI) ?: @"",
        @"context":SGURIString(state.contextURI) ?: @"",
        @"playing":@(state.isPlaying && !state.isPaused), @"loading":@(state.isLoading)}];
}
@end

static BOOL command(NSDictionary *request) {
    if (!NSThread.isMainThread) return NO;
    @try {
        NSString *operation=request[@"operation"];
        if ([operation isEqualToString:@"enable"]) {
            if (![pw_localSettings respondsToSelector:@selector(enableDocumentsFolderAccess)]) return NO;
            [pw_localSettings enableDocumentsFolderAccess];
            PWEventDetails(@"download",@"native_documents_scan_requested",0,@{@"enabled":@([pw_localSettings enabled])});
            return YES;
        }
        if ([operation isEqualToString:@"open_player"]) return SGOpenSpotifyURI([NSURL URLWithString:@"spotify:now-playing"]);
        if ([operation isEqualToString:@"open_files"]) return SGOpenSpotifyURI([NSURL URLWithString:@"spotify:local-files"]);
        if ([operation isEqualToString:@"toggle"] && PWNativeLocalPlayback()) {
            id player=SGKaraokePlayer();
            if (![player respondsToSelector:@selector(pause:)] || ![player respondsToSelector:@selector(resume:)]) return NO;
            return (SGPlayerState().isPaused ? [player resume:nil] : [player pause:nil]) != nil;
        }
        if (![operation isEqualToString:@"play"]) return NO;
        id player=SGKaraokePlayer();
        Class contextClass=NSClassFromString(@"SPTPlayerContext"), optionsClass=NSClassFromString(@"SPTPlayOptions");
        NSDictionary *data=request[@"context"], *options=request[@"options"];
        if (![data isKindOfClass:NSDictionary.class] || ![options isKindOfClass:NSDictionary.class] ||
            ![player respondsToSelector:@selector(playContext:options:)] ||
            ![contextClass instancesRespondToSelector:@selector(initWithDictionary:)] ||
            ![optionsClass instancesRespondToSelector:@selector(initWithDictionary:)]) return NO;
        // Never hand online track URIs to this path, or let a missing local item
        // fall back to streaming. Spotify handles all subsequent queue commands.
        NSArray *pages=data[@"pages"];
        if (![pages isKindOfClass:NSArray.class] || pages.count!=1) return NO;
        NSArray *tracks=pages[0][@"tracks"];
        if (![tracks isKindOfClass:NSArray.class] || !tracks.count || [options[@"always_play_something"] boolValue]) return NO;
        for (NSDictionary *track in tracks) {
            if (![track isKindOfClass:NSDictionary.class] || ![track[@"uri"] isKindOfClass:NSString.class] ||
                ![track[@"uri"] hasPrefix:@"spotify:local:"]) return NO;
        }
        id context=[[contextClass alloc] initWithDictionary:data];
        id playOptions=[[optionsClass alloc] initWithDictionary:options];
        if (!context || !playOptions) return NO;
        return [player playContext:context options:playOptions] != nil;
    } @catch (NSException *exception) {
        PWEventDetails(@"download",@"native_play_exception",1,@{@"error_message":exception.reason ?: @""});
        return NO;
    }
}
%hook _TtC19LocalFiles_CoreImpl20LocalFilesAPIService
- (id)provideLocalFilesSettingsModel {
    id model=%orig;
    if ([model respondsToSelector:@selector(enableDocumentsFolderAccess)]) pw_localSettings=model;
    return model;
}
- (void)_injectDependenciesWithProvider:(id)provider {
    %orig;
    // Use the app-created model after its dependencies have been injected.
    id model=[(id)self provideLocalFilesSettingsModel];
    if ([model respondsToSelector:@selector(enableDocumentsFolderAccess)]) pw_localSettings=model;
}
%end
// Observe the actual native offline setting, including its initial value. No
// preference or connectivity state is forged. Physical disconnection is handled
// independently by NWPathMonitor; a present Wi-Fi link is not manual Online mode.
%hook SPTConnectivityManagerImplementation
- (id)initWithAnalyticsDelegate:(id)delegate allowNetwork:(BOOL)allowed scheduler:(id)scheduler callbackQueue:(id)queue {
    id value=%orig;
    if (value) dispatch_async(dispatch_get_main_queue(), ^{ [PWDownloadsBridge nativeNetworkAllowed:allowed]; });
    return value;
}
- (void)setAllowNetwork:(BOOL)allowed callback:(id)callback {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ [PWDownloadsBridge nativeNetworkAllowed:allowed]; });
}
- (void)setAllowNetwork:(BOOL)allowed {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ [PWDownloadsBridge nativeNetworkAllowed:allowed]; });
}
%end
%ctor {
    %init;
    [PWDownloadsBridge configureNativePlayback:^BOOL(NSDictionary *request){ return command(request); }];
    static PWNativeStateObserver *observer;
    observer=[PWNativeStateObserver new]; SGAddPlayerStateObserver(observer);
    dispatch_async(dispatch_get_main_queue(), ^{ [PWDownloadsBridge startOfflinePlaylistBridge]; });
}
