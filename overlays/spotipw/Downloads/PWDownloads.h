#import <UIKit/UIKit.h>

#define PWKeyDownloadSource @"spotifyglass.download.source"
BOOL PWDownloadsEnabled(void);
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
+ (void)startOfflineMonitor;
+ (void)stopOfflinePlayback;
+ (NSDictionary *)trackInfoFromModel:(id)model uri:(NSString *)uri title:(NSString *)title subtitle:(NSString *)subtitle;
+ (id)playlistModelFromController:(UIViewController *)controller;
+ (void)captureNativePlayerAppearance:(UIViewController *)controller;
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
