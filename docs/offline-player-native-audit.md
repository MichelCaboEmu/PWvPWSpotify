# Native player visual audit — Spotify 9.1.78 (917802214)

Inspected the complete IPA from build run 37099394943 (commit e4f32dc),
not the expired initial Catbox upload. Executable size: 227,428,064 bytes.

## Verified resources and components

- `SpotifyShared.framework/Fonts.bundle`: SpotifyMixUI-Regular, SpotifyMixUI-Bold,
  SpotifyMixUITitleVariable and spoticon. Resources are loaded from the installed
  application; no third-party font binaries are copied into this repository.
- spoticon cmap: downloaded16 f32c, download24 f399, play24 f1c8, pause24 f1d3,
  skip-back24 f1d6, skip-forward24 f1d7, shuffle24 f1d5, repeat24 f1d4,
  repeat-once24 f201, queue24 f3a3, chevron-down24 f394, more24 f1cc.
- `NowPlaying_ScrollImpl.NPVScrollViewController`: viewDidAppear: and
  viewDidLayoutSubviews verified in executable metadata and existing PlayerScroll.x.
- HeaderElementsUnit, PlaybackControlsElementsUnit and identifiers in
  Native/Player/PlayerDeclutter.x, Redesigned/Player/PlayerHeader.x,
  PlayerFooter.x and PlayerLyrics.x describe the actual hierarchy and row order.

PWNativePlayerAppearance measures the displayed online player read-only. It stores
rectangles and font names/sizes, keyed by window dimensions, safe area, text size
and redesign setting. It does not store track text, images or screenshots.
Open the online full-screen player once in the desired appearance to populate the
profile. Missing/invalid measurements retain the fallback layout; a different
orientation, text size or appearance needs its own measurement.

## Scope and remaining limits

The offline screen uses the bundled fonts/glyphs and measured frames where present.
It still uses the local AVPlayer and local queue. It does not instantiate Spotify's
private player dependency graph or fake its playback state. The queue and options
panel remain local UIKit implementations. Background colors are derived locally
from artwork. This is not a claim of pixel-perfect identity or a full native-engine
adapter; on-device visual verification remains necessary.

| Capability | Offline behavior |
| --- | --- |
| Play, pause, seek, previous/next | Local audio |
| Shuffle, repeat/repeat-one | Local queue |
| Open, reorder, remove from queue | Local queue |
| Lock-screen/system playback controls | Existing local integration |
| Audio output selection | System route picker; available routes depend on device |
| Share downloaded file | Available |
| Lyrics, artist, album, radio navigation | Disabled in local player |

## Menu and row regressions

PWTrackMenuHeader disables wrapper subview autoresizing and measures real prior
header content rather than recursively counting its growing frame. Empty large
spacers collapse. Download row height, icon origin and label font/spacing are read
from a visible native action row.

The playlist indicator is an attributed-text prefix on the artist subtitle, with
an explicit marker removed on cell reuse or loss of downloaded state. The iOS
simulator test checks repeated resizing and indicator reuse with real UIKit.
