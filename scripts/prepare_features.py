"""Feature overlays. Strict patches against the pinned upstream revision."""
import pathlib, shutil, subprocess

def apply(root,sg,change):
    source=sg/'tweak/Sources'
    for folder, destination in [('Core','Core'),('App','App'),('Shared','Shared/Player')]:
        for path in (root/'overlays/spotipw'/folder).glob('*'):
            dest=source/destination/path.name
            if path.name.startswith('PWGenius') and folder=='Shared': dest=source/'Shared/Genius'/path.name
            dest.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(path,dest)
    sha=subprocess.check_output(['git','-C',str(root),'rev-parse','--short=12','HEAD'],text=True).strip()
    (source/'Core/PWBuildVersion.h').write_text(f'#define PW_BUILD_SHA "{sha}"\n')
    change(sg/'tweak/Makefile','MediaPlayer CoreImage AudioToolbox AVFoundation CoreHaptics',
           'MediaPlayer CoreImage AudioToolbox AVFoundation CoreHaptics SafariServices Security MetricKit')
    # Logos hook uses only the documented MediaPlayer API, already present in Spotify.
    page=source/'App/ModSettings.x'
    change(page,'#import "PWEeveeSettings.h"','#import "PWEeveeSettings.h"\n#import "PWFeatureSettings.h"')
    change(page,'        PWEeveeSettingsRow(),','        PWEeveeSettingsRow(),\n        PWArtworkSettingsRow(),\n        PWGeniusSettingsRow(),\n        PWDiagnosticsRow(),')
    # The redesigned view owns exact lyric lines and their track ID.
    view=source/'Redesigned/Lyrics/SGRKaraokeView.m'
    change(view,'#import "Shared/LyricsSources/LyricsSources.h"',
           '#import "Shared/LyricsSources/LyricsSources.h"\n#import "Shared/Genius/PWGenius.h"')
    change(view,'    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)]];', '''    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)];
    [self addGestureRecognizer:tap];
    if (SGEnabled(PWKeyGenius)) {
        UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(pwExplain:)];
        hold.minimumPressDuration = 0.5;
        [self addGestureRecognizer:hold];
        [tap requireGestureRecognizerToFail:hold];
    }''')
    change(view,'- (void)tapped:(UITapGestureRecognizer *)tap {', '''- (void)pwExplain:(UILongPressGestureRecognizer *)hold {
    if (hold.state != UIGestureRecognizerStateBegan) return;
    if (_extras && !_extras.hidden && CGRectContainsPoint(_extras.frame, [hold locationInView:self])) return;
    CGPoint point = [hold locationInView:_scroll];
    for (SGRKaraokeLineView *view in _shown.allValues) {
        if (!CGRectContainsPoint(CGRectInset(view.frame, -_margin, -_lineGap / 2), point)) continue;
        PWShowGenius(_track, SGKaraokeLineText(view.line), self);
        return;
    }
}

- (void)tapped:(UITapGestureRecognizer *)tap {''')
    # The native screen has its own hook/gesture, gated by its existing native ctor.
    native=source/'Native/Lyrics/LyricsPage.x'
    change(native,'#import "Native/Appearance/Repaint.h"',
           '#import "Native/Appearance/Repaint.h"\n#import "Shared/Genius/PWGenius.h"')
    change(native,'- (void)layoutSubviews {\n    %orig;',
           '- (void)layoutSubviews {\n    %orig;\n    PWInstallNativeGenius((UIView *)self);')
    # A lyrics refresh and a Spotify artwork update can come from different threads.
    # Thread-local recursion state prevents dropping another thread's real update.
    lyrics=source/'Shared/LockScreenLyrics/LockScreenLyrics.x'
    change(lyrics,'static BOOL sg_resending;','static _Thread_local BOOL sg_resending;')
    change(lyrics,'    shown[MPMediaItemPropertyArtist] = line;',
           '    shown[@"pw.originalArtist"] = info[MPMediaItemPropertyArtist] ?: @"";\n    shown[MPMediaItemPropertyArtist] = line;')
    change(lyrics,'''    sg_shownLine = line;
    sg_resending = YES;
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = line ? withLine(info, line, elapsed) : info;
    sg_resending = NO;''', '''    @synchronized (sg_lock) {
        // A newer track/artwork response arrived while we calculated the line.
        if (info != sg_spotifyInfo) return;
        sg_shownLine = line;
        sg_resending = YES;
        MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = line ? withLine(info, line, elapsed) : info;
        sg_resending = NO;
    }''')
