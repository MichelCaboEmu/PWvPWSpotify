#import <UIKit/UIKit.h>
// Returns a local, clear video (no encrypted playlists) and its first frame.
void PWAppleArtwork(NSString *album, NSString *artist, NSURL *destination, void (^done)(NSURL *, UIImage *));
