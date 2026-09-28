#import <UIKit/UIKit.h>

#define PWKeyDownloadSource @"spotifyglass.download.source"
BOOL PWDownloadsEnabled(void);
// Main thread. Uses the displayed header's verified model, never the current player context.
UIView *PWDownloadControl(UIView *root, id model);
void PWPrepareNativeDownloads(UIView *row);

@interface PWDownloadsBridge : NSObject
+ (NSString *)folderName;
+ (NSString *)summary;
+ (void)presentFrom:(UIViewController *)controller playlistURI:(NSString *)uri title:(NSString *)title authorization:(NSString *)authorization;
+ (void)chooseFolderFrom:(UIViewController *)controller;
+ (void)resetFolder;
@end
