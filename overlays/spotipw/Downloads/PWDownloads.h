#import <UIKit/UIKit.h>

#define PWKeyDownloadSource @"spotifyglass.download.source"
BOOL PWDownloadsEnabled(void);
// Main thread. Uses the displayed header's verified model, never the current player context.
UIView *PWDownloadControl(UIView *root, id model);
void PWPrepareNativeDownloads(UIView *row);

@interface PWDownloadsBridge : NSObject
+ (void)libraryFrom:(UIViewController *)controller;
+ (void)errorsFrom:(UIViewController *)controller;
+ (NSString *)errorSummary;
+ (void)metadataFrom:(UIViewController *)controller;
+ (NSString *)metadataSummary;
+ (void)startOfflineMonitor;
+ (void)stopOfflinePlayback;
+ (void)configureSoundCloudFrom:(UIViewController *)controller;
+ (NSString *)soundCloudSummary;
+ (NSDictionary *)trackInfoFromModel:(id)model uri:(NSString *)uri title:(NSString *)title subtitle:(NSString *)subtitle;
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
