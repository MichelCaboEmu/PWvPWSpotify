#import "PWArtworkPolicy.h"
PWArtworkSource PWChooseArtwork(NSInteger mode, BOOL spotify, BOOL apple, BOOL generated) {
    if (mode == 3) return spotify ? PWArtworkSourceSpotify : PWArtworkSourceNone;
    if (mode == 2) return generated ? PWArtworkSourceGenerated : PWArtworkSourceNone;
    if (mode == 1 && apple) return PWArtworkSourceApple;
    if (spotify) return PWArtworkSourceSpotify;
    if (apple) return PWArtworkSourceApple;
    return generated ? PWArtworkSourceGenerated : PWArtworkSourceNone;
}
