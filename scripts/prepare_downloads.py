"""Pin and embed the native Swift extractor; no Python runtime or remote fallback."""
import json, plistlib, shutil, subprocess

def apply(root, sg, change):
    upstream = root / 'upstream/youtubekit'
    expected = json.loads((root / 'upstreams.json').read_text())['youtubekit']['commit']
    actual = subprocess.check_output(['git', '-C', str(upstream), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != expected:
        raise RuntimeError('Unexpected YouTubeKit revision: ' + actual)
    source = sg / 'tweak/Sources'
    destination = source / 'Shared/Downloads'
    shutil.copytree(root / 'overlays/spotipw/Downloads', destination)
    vendor = destination / 'YouTubeKit'
    shutil.copytree(upstream / 'Sources/YouTubeKit', vendor)
    shutil.copy2(upstream / 'LICENSE', vendor / 'LICENSE')
    change(vendor / 'SignatureSolver.swift', 'Bundle.module', 'Bundle.pwYouTubeKit')
    # Carry only the user's YouTube cookie preference into the local extractor.
    # OAuth/session cookies stay untouched; the fusion invokes useOAuth=false.
    change(vendor / 'YouTube.swift', 'request.httpShouldHandleCookies = false',
           'request.httpShouldHandleCookies = false\n            PWYouTubeAccess.apply(to: &request)\n            try Task.checkCancellation()', count=2)
    change(vendor / 'InnerTube.swift', 'let (responseData, _) = try await URLSession.shared.data(for: request)',
           'PWYouTubeAccess.apply(to: &request)\n        try Task.checkCancellation()\n        let (responseData, _) = try await URLSession.shared.data(for: request)')
    change(vendor / 'YouTube.swift', 'let (data, _) = try await URLSession.shared.data(from: jsURL)',
           'try Task.checkCancellation()\n                var scriptRequest = URLRequest(url: jsURL, timeoutInterval: 25)\n'
           '                PWYouTubeAccess.apply(to: &scriptRequest)\n'
           '                let (data, _) = try await URLSession.shared.data(for: scriptRequest)')
    change(vendor / 'Extensions/Retry.swift', 'for method in methods {',
           'for method in methods {\n            try Task<Never, Never>.checkCancellation()')
    # Keep distinct public URLs for an identical format: a URL returned by one
    # client can expire/refuse HTTP 403 while another already-returned URL works.
    # The app caps attempts at three and never changes authentication or clients.
    change(vendor / 'YouTube.swift', 'var existingITags = Set<Int>()',
           'var existingStreamURLs = Set<String>()')
    change(vendor / 'YouTube.swift', 'existingITags.insert(stream.itag.itag).inserted',
           'existingStreamURLs.insert(stream.url.absoluteString).inserted')
    # The app emits structured diagnostics instead of raw upstream URLs/bodies.
    for path in vendor.rglob('*.swift'):
        text = path.read_text()
        import re
        text = re.sub(r'OSLog\((?:[A-Za-z]+\.self|category: "[^"]+")\)', 'OSLog.disabled', text)
        path.write_text(text)
    bundle = sg / 'PWYouTubeKit.bundle'
    shutil.copytree(vendor / 'Resources', bundle)
    (bundle / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'pw.spotify.YouTubeKit.resources', 'CFBundleName': 'PWYouTubeKit',
        'CFBundlePackageType': 'BNDL', 'CFBundleVersion': '1'}))
    shutil.copy2(upstream / 'LICENSE', bundle / 'LICENSE-YouTubeKit.txt')
    change(sg / 'tweak/Makefile', 'SafariServices Security MetricKit CoreMedia CoreVideo',
           'SafariServices Security MetricKit CoreMedia CoreVideo JavaScriptCore WebKit AVKit CoreText')
    change(sg / 'scripts/pipeline.sh', 'FILES=("$TWEAK_DEB")', 'FILES=("$TWEAK_DEB" "$ROOT/PWYouTubeKit.bundle")')
    # Documents are exported audio, visible through Files; the private queue lives in Application Support.
    plist = sg / 'plist/liquid-glass.plist'
    values = plistlib.loads(plist.read_bytes())
    values.update(UIFileSharingEnabled=True, LSSupportsOpeningDocumentsInPlace=True)
    plist.write_bytes(plistlib.dumps(values))

    # The existing session observer must also run when every lyrics feature is disabled.
    lyrics = source / 'Shared/Lyrics/KaraokeSource.x'
    change(lyrics, '#import "Lyrics.h"', '#import "Lyrics.h"\n#import "Shared/Downloads/PWDownloads.h"')
    change(lyrics, 'if (!SGRedesignedUI() && !SGFlag(SGKeyLockScreenLyrics, NO) && !SGLyricsEnabled()) return;',
           'if (!SGRedesignedUI() && !SGFlag(SGKeyLockScreenLyrics, NO) && !SGLyricsEnabled() && !PWDownloadsEnabled()) return;')
    # Only Spotify hosts may contribute the session credential, including when downloading alone.
    change(lyrics, 'if (![request.URL.host containsString:@"spclient"]) return;',
           'NSString *host = request.URL.host.lowercaseString;\n'
           '    if (![host hasSuffix:@".spotify.com"] || ![host containsString:@"spclient"]) return;')

    native = source / 'Native/Playlist/Playlist.x'
    change(native, '#import "Playlist.h"', '#import "Playlist.h"\n#import "Shared/Downloads/PWDownloads.h"')
    change(native, '            if (identNamed(action, buttons[i].ident)) hide(action, buttons[i].key);',
           '            if (PWDownloadsEnabled() && [buttons[i].key isEqualToString:SGHidePlaylistDownload]) continue;\n'
           '            if (identNamed(action, buttons[i].ident)) hide(action, buttons[i].key);')
    change(native, 'if ([self.accessibilityIdentifier isEqualToString:@"HeaderActionsRow"] && playlistHeaderOf(self)) applyActions(self);',
           'if ([self.accessibilityIdentifier isEqualToString:@"HeaderActionsRow"] && playlistHeaderOf(self)) {\n'
           '        applyActions(self);\n        PWPrepareNativeDownloads(self);\n    }')

    redesigned = source / 'Redesigned/Playlist/PlaylistHeader.x'
    change(redesigned, '#import "Playlist.h"', '#import "Playlist.h"\n#import "Redesigned/Kit/SGRGlass.h"')
    change(redesigned, 'static void applyToolbar(UIView *headerRoot) {', '''// The toolbar contains two independent controls, Find and Sort. A glass layer
// behind the entire toolbar made a double background and joined their spacing.
// Keep Spotify's frames, gestures and pull-to-reveal lifecycle unchanged.
static void pwStylePlaylistSearchControl(UIView *control) {
    CGSize size = control.bounds.size;
    if (size.width < 44 || size.height < 26 || size.height > 64) return;
    UIVisualEffectView *pane = SGGlassAt(control, 0);
    pane.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    pane.frame = control.bounds;
    SGShapeGlass(pane, size.height / 2, YES);
    if (UIAccessibilityIsReduceTransparencyEnabled()) {
        pane.effect = nil; pane.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
    }
    control.layer.cornerRadius = size.height / 2;
    control.layer.cornerCurve = kCACornerCurveContinuous;
    SGForEachView(control, ^(UIView *v) {
        if (v == pane || [v isDescendantOfView:pane]) return;
        v.backgroundColor = UIColor.clearColor;
        v.layer.backgroundColor = NULL;
        if ([v isKindOfClass:UILabel.class]) {
            UILabel *label = (UILabel *)v;
            label.textColor = UIColor.whiteColor;
            label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        } else if ([v isKindOfClass:UITextField.class]) {
            UITextField *field = (UITextField *)v;
            field.borderStyle = UITextBorderStyleNone;
            field.textColor = UIColor.whiteColor;
            field.font = [UIFont systemFontOfSize:15];
        } else if ([NSStringFromClass(v.class) containsString:@"IconView"]) {
            // Same verified Encore setter used by Navbar/SearchField.x.
            SEL setter = NSSelectorFromString(@"setForegroundColor:");
            if ([v respondsToSelector:setter]) ((void(*)(id,SEL,id))objc_msgSend)(v,setter,UIColor.whiteColor);
            else v.tintColor = UIColor.whiteColor;
        }
    });
}
static void pwStylePlaylistSearchChildren(UIView *view) {
    for (UIView *child in view.subviews) {
        if ([child isKindOfClass:UIVisualEffectView.class]) continue;
        if ([child isKindOfClass:UIControl.class] && child.bounds.size.width >= 44 && child.bounds.size.height >= 26) {
            pwStylePlaylistSearchControl(child);
        } else {
            // Layout wrappers must stay transparent but keep visibility/layout.
            child.backgroundColor = UIColor.clearColor;
            pwStylePlaylistSearchChildren(child);
        }
    }
}

static void applyToolbar(UIView *headerRoot) {''')
    change(redesigned, '    for (UIView *v = toolbar; v && v != headerRoot; v = v.superview) {\n        if (![NSStringFromClass(v.class) containsString:@"HeaderView"]) continue;\n        conceal(v);\n        break;\n    }', '    // Spotify owns initial hiding and the pull-to-reveal gesture.\n    toolbar.backgroundColor = UIColor.clearColor;\n    pwStylePlaylistSearchChildren(toolbar);')
    change(redesigned, '#import "Playlist.h"', '#import "Playlist.h"\n#import "Shared/Downloads/PWDownloads.h"')
    change(redesigned, 'UIView *download = save ? nil : SGRFindByIdentifier(block, @"DownloadButton.Granular*", &kDownloadKey);',
           'UIView *download = PWDownloadsEnabled() ? PWDownloadControl(block, model) :\n'
           '        (save ? nil : SGRFindByIdentifier(block, @"DownloadButton.Granular*", &kDownloadKey));\n'
           '    [info showExtraDownload:save ? download : nil];')
    header = source / 'Redesigned/Kit/SGRHeaderInfo.h'
    change(header, '@interface SGRHeaderInfo : UIView', '@interface SGRHeaderInfo : UIView\n- (void)showExtraDownload:(UIView *)download;')
    impl = source / 'Redesigned/Kit/SGRHeaderInfo.m'
    change(impl, 'SGRMirrorButton *_shuffle, *_trailing;', 'SGRMirrorButton *_shuffle, *_trailing, *_download;')
    change(impl, '    _trailing = [[SGRMirrorButton alloc] initWithFrame:CGRectZero];',
           '    _download = [[SGRMirrorButton alloc] initWithFrame:CGRectZero];\n'
           '    _download.fallbackGlyph = [UIImage systemImageNamed:@"arrow.down"];\n'
           '    _download.hidden = YES; [self addSubview:_download];\n'
           '    _trailing = [[SGRMirrorButton alloc] initWithFrame:CGRectZero];')
    change(impl, '- (CGFloat)contentHeightForWidth:(CGFloat)width {', '''- (void)showExtraDownload:(UIView *)download {
    if (download) [_download feedFrom:download];
    BOOL hidden = download == nil;
    if (_download.hidden != hidden) { _download.hidden = hidden; [self setNeedsLayout]; }
}

- (CGFloat)contentHeightForWidth:(CGFloat)width {''')
    change(impl, '    y += side;', '''    if (!_download.hidden) {
        CGFloat gap = 8;
        CGFloat available = MAX(0, width - 2 * kSide);
        CGFloat mainWidth = MAX(80, MIN(playWidth, available - 3 * side - 3 * gap));
        CGFloat x = round((width - (mainWidth + 3 * side + 3 * gap)) / 2);
        _shuffle.frame = CGRectMake(x, y, side, side); x += side + gap;
        _play.frame = CGRectMake(x, y, mainWidth, side); x += mainWidth + gap;
        _trailing.frame = CGRectMake(x, y, side, side); x += side + gap;
        _download.frame = CGRectMake(x, y, side, side);
    }
    y += side;''')

    # The download action shares the menu header with Speed and pitch. The
    # original block must resize in-place instead of replacing its wrapper.
    speed = source / 'Shared/Player/SpeedPitchMenu.x'
    change(speed, '#import "Core/SGCore.h"', '#import "Core/SGCore.h"\n#import "Shared/Downloads/PWDownloads.h"')
    change(speed, '        else table.tableHeaderView = self;',
           '        else if ([self isDescendantOfView:table.tableHeaderView]) [PWDownloadsBridge refreshTrackMenuHeader:table];\n'
           '        else table.tableHeaderView = self;')
    change(speed, '    if (placed != block || fabs(block.frame.size.width - width) > 0.5) {',
           '    if (!block.inFooter && placed != block && [block isDescendantOfView:placed]) {\n'
           '        block.frame = CGRectMake(0, 0, width, [SGSpeedPitchView heightOpen:sg_open]);\n'
           '        [PWDownloadsBridge refreshTrackMenuHeader:table];\n        return;\n    }\n'
           '    if (placed != block || fabs(block.frame.size.width - width) > 0.5) {')

    # Local playback goes through Spotify itself; only the unavailable lyrics
    # action needs an explicit guard in the redesigned footer.
    footer = source / 'Redesigned/Player/PlayerFooter.x'
    change(footer, '#import "Player.h"', '#import "Player.h"\n#import "Shared/Downloads/PWDownloads.h"')
    change(footer, 'BOOL enabled = SGRPlayerLyricsAvailable() || SGRPlayerLyricsOpen(), open = SGRPlayerLyricsOpen();',
           'BOOL local = PWNativeLocalPlayback();\n    BOOL enabled = !local && (SGRPlayerLyricsAvailable() || SGRPlayerLyricsOpen()), open = !local && SGRPlayerLyricsOpen();')
