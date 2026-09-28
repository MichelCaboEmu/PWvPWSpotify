#import <Foundation/Foundation.h>
typedef NS_ENUM(NSInteger, PWArtworkSource) {
    PWArtworkSourceNone, PWArtworkSourceSpotify, PWArtworkSourceApple, PWArtworkSourceGenerated
};
// A source is eligible only after its asset is ready; Spotify can arrive late.
PWArtworkSource PWChooseArtwork(NSInteger mode, BOOL spotify, BOOL apple, BOOL generated);
