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
    # These logs can contain URLs and search terms. Our separate diagnostic events contain only codes.
    # Keep upstream code intact apart from resource routing and use of a disabled log.
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
           'SafariServices Security MetricKit CoreMedia CoreVideo JavaScriptCore')
    change(sg / 'scripts/pipeline.sh', 'FILES=("$TWEAK_DEB")', 'FILES=("$TWEAK_DEB" "$ROOT/PWYouTubeKit.bundle")')
    # Documents are exported audio, visible through Files; the private queue lives in Application Support.
    plist = sg / 'plist/liquid-glass.plist'
    values = plistlib.loads(plist.read_bytes())
    values.update(UIFileSharingEnabled=True, LSSupportsOpeningDocumentsInPlace=True)
    plist.write_bytes(plistlib.dumps(values))

    native = source / 'Native/Playlist/Playlist.x'
    change(native, '#import "Playlist.h"', '#import "Playlist.h"\n#import "Shared/Downloads/PWDownloads.h"')
    change(native, '            if (identNamed(action, buttons[i].ident)) hide(action, buttons[i].key);',
           '            if (PWDownloadsEnabled() && [buttons[i].key isEqualToString:SGHidePlaylistDownload]) continue;\n'
           '            if (identNamed(action, buttons[i].ident)) hide(action, buttons[i].key);')
    change(native, 'if ([self.accessibilityIdentifier isEqualToString:@"HeaderActionsRow"] && playlistHeaderOf(self)) applyActions(self);',
           'if ([self.accessibilityIdentifier isEqualToString:@"HeaderActionsRow"] && playlistHeaderOf(self)) {\n'
           '        applyActions(self);\n        PWPrepareNativeDownloads(self);\n    }')

    redesigned = source / 'Redesigned/Playlist/PlaylistHeader.x'
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
