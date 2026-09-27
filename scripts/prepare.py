#!/usr/bin/env python3
"""Assemble pinned GPL sources and apply the explicit fusion profile."""
import argparse, json, pathlib, re, shutil, subprocess
ROOT = pathlib.Path(__file__).resolve().parents[1]

def change(path, old, new, count=1):
    text = path.read_text()
    if text.count(old) != count:
        raise RuntimeError(f'Patch anchor mismatch in {path.name}: expected {count}, got {text.count(old)}')
    path.write_text(text.replace(old, new))

def main():
    p=argparse.ArgumentParser(); p.add_argument('--sources',type=pathlib.Path,default=ROOT/'upstream')
    args=p.parse_args()
    manifest=json.loads((ROOT/'upstreams.json').read_text())
    for name in ['spotipw','eevee']:
        src=args.sources/name
        sha=subprocess.check_output(['git','-C',str(src),'rev-parse','HEAD'],text=True).strip()
        if sha != manifest[name]['commit']: raise RuntimeError(f'{name}: unexpected upstream commit {sha}')
        dst=ROOT/'build'/name
        if dst.exists(): shutil.rmtree(dst)
        shutil.copytree(src,dst,ignore=shutil.ignore_patterns('.git','.theos','packages','obj','__pycache__'))
    sg=ROOT/'build/spotipw'; ee=ROOT/'build/eevee'
    swift=ee/'Sources/EeveeSpotify'
    tweak=swift/'Tweak.x.swift'
    content=tweak.read_text()
    # init() is the final member in the pinned Tweak type. Replace the entire
    # activation body, not its individual toggles (which other paths could bypass).
    marker='    init() {\n        eeveeBreadcrumb("Tweak init() entered")'
    assert content.count(marker)==1 and content.rstrip().endswith('    }\n}')
    content=content[:content.index(marker)]+'    init() {\n        pwFusionStart()\n    }\n}\n'
    tweak.write_text(content)
    shutil.copy2(ROOT/'overlays/eevee/PWFusion.swift',swift/'PWFusion.swift')

    # Give each SponsorBlock hook its own activation guard. A missing slider
    # should not take down the observer or cause Orion to hook an absent method.
    hooks=swift/'SponsorBlock/SponsorBlockHooks.x.swift'
    change(hooks,'typealias Group = SponsorBlockGroup','typealias Group = PWSponsorOverlayGroup',count=2)
    change(hooks,'class PlayerServiceObserverHook: ClassHook<NSObject> {\n    typealias Group = PWSponsorOverlayGroup',
           'class PlayerServiceObserverHook: ClassHook<NSObject> {\n    typealias Group = PWSponsorObserverGroup')
    change(hooks,'struct SponsorBlockGroup: HookGroup {}',
           'struct PWSponsorOverlayGroup: HookGroup {}\nstruct PWSponsorObserverGroup: HookGroup {}')
    change(hooks,'    SponsorBlockGroup().activate()', '''    if let player = NSClassFromString("SPTPlayerServiceImplementation"),
       class_getInstanceMethod(player, NSSelectorFromString("addPlayerObserver:")) != nil {
        PWSponsorObserverGroup().activate()
    }
    if let slider = NSClassFromString("_TtCO17NowPlaying_ECMKit11ProgressBar6Slider"),
       class_getInstanceMethod(slider, #selector(UIView.layoutSubviews)) != nil {
        PWSponsorOverlayGroup().activate()
    }''')
    # Objective-C runtime functions are needed for the guards above.
    change(hooks,'import UIKit','import UIKit\nimport ObjectiveC.runtime')

    # Both original providers block a worker while URLSession runs; cap network
    # resources so a failed provider does not stall the shared fallback chain.
    for provider in ['GeniusLyricsRepository.swift','PetitLyricsRepository.swift']:
        change(swift/'Lyrics/Repositories'/provider,
               'let configuration = URLSessionConfiguration.default',
               'let configuration = URLSessionConfiguration.ephemeral\n        configuration.timeoutIntervalForRequest = 3\n        configuration.timeoutIntervalForResource = 4')

    # All complement preferences participate in spoti.pw's prefix-based backup/reset.
    prefs=swift/'Shared/Models/Extensions/UserDefaults+Extension.swift'
    content=prefs.read_text()
    content=re.sub(r'(private static let \w+Key = ")([^"\n]+)(")',r'\1spotifyglass.eevee.\2\3',content)
    prefs.write_text(content)
    wrapper=swift/'Shared/Models/UserDefaultPropertyWrapper.swift'
    change(wrapper,'container.data(forKey: key)','container.data(forKey: "spotifyglass.eevee." + key)')
    change(wrapper,'container.set(data, forKey: key)','container.set(data, forKey: "spotifyglass.eevee." + key)')
    icon=swift/'Settings/Sections/AppIcon/Views/EeveeAppIconPickerView.swift'
    change(icon,'"EeveeSelectedAppIconName"','"spotifyglass.eevee.selectedAppIcon"')

    # Sideload builds resolve the resources in the application bundle and have
    # no jailbreak root. Do not introduce a libroot dependency on stock iOS.
    cfile=ee/'Sources/EeveeSpotifyC/Tweak.m'
    text=cfile.read_text()
    a=text.index('#if THEOS_PACKAGE_SCHEME_ROOTHIDE')
    b=text.index('void EeveeSBInvokeSeekDouble', a)
    cfile.write_text(text[:a]+'NSString *EeveeJBRootPath(NSString *path) { return path; }\n\n'+text[b:])
    change(ee/'Makefile','EeveeSpotify_LDFLAGS += -lroot\n','# PW fusion: no libroot dependency in a sideloaded IPA.\n')

    change(ee/'Makefile','TARGET := iphone:clang:latest:14.0','TARGET := iphone:clang:latest:16.1')

    # The selected karaoke UI is spoti.pw's, so its duplicate Metal resource is
    # not shipped. All original Swift types remain available for source references.
    makefile=ee/'Makefile'
    text=makefile.read_text(); start=text.index('\t# Compile the karaoke background Metal shader')
    end=text.index('# Build EeveeSwiftProtobuf.framework', start)
    makefile.write_text(text[:start]+text[end:])

    sgs=sg/'tweak/Sources'
    for name, dest in [('PWEeveeLyrics.m','Shared/LyricsSources/PWEeveeLyrics.m'),
                       ('PWLockScreenArtwork.h','Shared/Player/PWLockScreenArtwork.h'),
                       ('PWLockScreenArtwork.m','Shared/Player/PWLockScreenArtwork.m'),
                       ('PWEeveeSettings.h','App/PWEeveeSettings.h'),
                       ('PWEeveeSettings.m','App/PWEeveeSettings.m')]:
        shutil.copy2(ROOT/'overlays/spotipw'/name,sgs/dest)
    change(sgs/'Shared/LyricsSources/LyricsSources.h','extern SGLyricsAsk SGSpicyLyricsAsk;',
           'extern SGLyricsAsk SGSpicyLyricsAsk;\nextern SGLyricsAsk PWEeveeGeniusAsk;\nextern SGLyricsAsk PWEeveePetitAsk;')
    change(sgs/'Shared/LyricsSources/LyricsSources.m',
           '            make(@"lrclib", @"LRCLIB", @"Line timing, open fallback", SGLrcLibAsk),',
           '''            make(@"lrclib", @"LRCLIB", @"Line timing, open fallback", SGLrcLibAsk),
            make(@"petitlyrics", @"PetitLyrics", @"Eevee: Japanese catalogue, line timing", PWEeveePetitAsk),
            make(@"genius", @"Genius", @"Eevee: plain text fallback", PWEeveeGeniusAsk),''')
    change(sgs/'App/ModSettings.x','#import "Pages.h"','#import "Pages.h"\n#import "PWEeveeSettings.h"')
    change(sgs/'App/ModSettings.x','        audioEffects,','        audioEffects,\n        PWEeveeSettingsRow(),')
    change(sgs/'App/ModSettings.x','initWithTitle:@"spoti.pw"','initWithTitle:@"Spotify"')

    # Canvas is also a source for Spotify's lock-screen artwork. Do not let the
    # redesigned player's unconditional Canvas kill override that feature.
    player=sgs/'Redesigned/Player/PlayerField.x'
    change(player,'#import "Player.h"',
           '#import "Player.h"\n#import "Shared/Player/PWLockScreenArtwork.h"')
    change(player,'        @"ios-feature-canvas.canvas_enabled": @NO,\n','')
    change(player,'    SGRedesignForceFlags(@"player", flags);', '''    SGRedesignForceFlags(@"player", flags);
    SGRegisterFlagForcer(YES,
        ^id(NSString *key) {
            return SGRedesignedUI() && !PWLockScreenArtworkEnabled() &&
                [key isEqualToString:@"ios-feature-canvas.canvas_enabled"] ? @NO : nil;
        },
        ^id(NSString *key) {
            return SGRedesignedUIStored() && !PWLockScreenArtworkStored() &&
                [key isEqualToString:@"ios-feature-canvas.canvas_enabled"] ? @NO : nil;
        });''')
    settings=sgs/'Shared/Player/PlayerSettings.m'
    change(settings,'#import "PlayerSettings.h"',
           '#import "PlayerSettings.h"\n#import "PWLockScreenArtwork.h"')
    change(settings,'        SGSection(@"Artwork", @[', '''        SGNotedSection(@"Lock screen videos", @[
            SGSwitchRow(@"Lock screen videos", @"Available videos for the current track; iOS 26 required", PWKeyLockScreenArtwork),
            SGStatRow(@"Current status", ^NSString *{ return PWLockScreenArtworkStatus(); }),''')
    change(settings,'    ] footer:nil];', '''    ] footer:@"Restart Spotify after changing these switches. Play a track with video artwork, then tap its cover on the Lock Screen. Keep Canvas enabled in Spotify. iOS may show a still image when Low Power Mode, Low Data Mode or Reduce Motion is on, or Auto-Play Animated Images is off. Not every track has a video."];''')
    # SGNotedSection takes a footer; the final section is the artwork section.
    change(settings,'            SGFlagRow(@"Companion content", @"ios-feature-lockscreen.companion_content_enabled"),\n        ]),',
           '            SGFlagRow(@"Companion content", @"ios-feature-lockscreen.companion_content_enabled"),\n        ], @"Enables video artwork and Canvas together. Canvas may also appear inside the player."),')

    # Updates refer to this combination, never offer an incompatible upstream IPA.
    update=sgs/'App/About/Update.m'
    change(update,'https://spoti.pw/api/update','https://api.github.com/repos/MichelCaboEmu/PWvPWSpotify/releases?per_page=20')
    change(update,'https://api.github.com/repos/skopevoj/spoti.pw/releases?per_page=20',
           'https://api.github.com/repos/MichelCaboEmu/PWvPWSpotify/releases?per_page=20')
    change(update,'NSData *body = SGUsageBody();','NSData *body = nil; // No upstream usage report in this fork.')
    # Inject the complementary module in the same packaging pass as the glass UI.
    pipe=sg/'scripts/pipeline.sh'
    change(pipe,'FILES=("$TWEAK_DEB")','FILES=("$TWEAK_DEB")\nif [ -n "${PW_EEVEE_DEB:-}" ]; then FILES+=("$PW_EEVEE_DEB"); fi')
    # Preserve the upstream executable bit when applying copied overlays.
    print('Assembled pinned sources with complementary Eevee activation profile.')

if __name__=='__main__': main()
