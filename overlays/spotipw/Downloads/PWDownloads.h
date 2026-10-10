#import <UIKit/UIKit.h>

#define PWKeyDownloadSource @"spotifyglass.download.source"
BOOL PWDownloadsEnabled(void);
BOOL PWNativeLocalPlayback(void);
// Main thread. Uses the displayed header's verified model, never the current player context.
UIView *PWDownloadControl(UIView *root, id model);
void PWPrepareNativeDownloads(UIView *row);
void PWRefreshMetadataSession(void);

@interface PWDownloadsBridge : NSObject
+ (void)setSpotifyAuthorization:(NSString *)authorization;
+ (void)libraryFrom:(UIViewController *)controller;
+ (void)errorsFrom:(UIViewController *)controller;
+ (NSString *)errorSummary;
+ (void)metadataFrom:(UIViewController *)controller;
+ (NSString *)metadataSummary;
+ (NSURL *)nativeArtworkURLForURI:(NSString *)uri;
+ (void)loadNativeArtworkForURI:(NSString *)uri completion:(void (^)(UIImage *image))completion;
+ (void)configureNativePlayback:(BOOL (^)(NSDictionary *request))handler;
+ (void)configureNativeFolderScanner:(void (^)(NSString *path, void (^completion)(NSData *response)))handler;
+ (NSData *)nativeFolderPayload:(NSString *)path;
+ (void)nativePlaybackState:(NSDictionary *)state;
+ (void)startOfflinePlaylistBridge;
+ (void)nativeNetworkAllowed:(BOOL)allowed;
+ (BOOL)offlinePlaylistEnabled;
+ (BOOL)isOriginalPlaylistURI:(NSString *)uri;
+ (void)observeOfflinePlaylistRow:(UIView *)view;
+ (BOOL)playOfflinePlaylistFrom:(UIViewController *)presenter model:(id)model uri:(NSString *)uri title:(NSString *)title selected:(NSString *)selected;
+ (NSDictionary *)trackInfoFromModel:(id)model uri:(NSString *)uri title:(NSString *)title subtitle:(NSString *)subtitle;
+ (id)playlistModelFromController:(UIViewController *)controller;
+ (void)decorateDownloadSubtitle:(UIView *)subtitle downloaded:(BOOL)downloaded;
+ (void)refreshTrackMenuHeader:(UITableView *)table;
+ (void)selectMenuTrack:(NSDictionary *)info;
+ (void)installTrackMenu:(UIViewController *)menu;
+ (NSString *)folderName;
+ (NSString *)summary;
+ (void)recordDiagnostics;
+ (void)presentFrom:(UIViewController *)controller playlistURI:(NSString *)uri title:(NSString *)title authorization:(NSString *)authorization;
+ (void)presentFrom:(UIViewController *)controller playlistURI:(NSString *)uri title:(NSString *)title authorization:(NSString *)authorization nativeModel:(id)model;
+ (void)chooseFolderFrom:(UIViewController *)controller;
+ (void)resetFolder;
@end
