# Native offline playback — Spotify 9.1.78 (917802214)

The reconstructed player, AVPlayer queue and captured-layout approximation have
been removed. The tweak hands a finite list of local tracks to Spotify's own
SPTEsperantoPlayer. Its native now-playing screen, queue, transport commands,
shuffle/repeat, remote controls and playback lifetime remain Spotify-owned.

## Verified integration

The complete executable from IPA build run 37099394943 was inspected (227,428,064
bytes). Objective-C method encodings and relevant dictionary keys were verified:

- LocalFiles_CoreImpl.LocalFilesAPIService: provideLocalFilesSettingsModel and
  _injectDependenciesWithProvider:. Use the app-created model after injection.
- LocalFilesSettingsModelImpl: enableDocumentsFolderAccess (`v16@0:8`). This calls
  the Documents source mutation; it does not fake media-library permission.
- SPTEsperantoPlayer: playContext:options: (`@32@0:8@16@24`).
- SPTPlayerContext initWithDictionary: reads uri, pages, metadata (0x1097c3458).
- SPTPlayerContextPage initWithDictionary: reads tracks and next_page_url
  (0x1097c3d68). The request provides one complete page and no continuation.
- SPTPlayerTrack initWithDictionary: reads uri, uid, provider, metadata (0x1097c7134).
- SPTPlayOptions initWithDictionary: reads skip_to, always_play_something,
  initially_paused (0x1097c1fc8). SPTSkipToTrack reads track_index (0x1097c7c7c).
- spotify:local-files and spotify:now-playing are bundled navigation routes,
  dispatched by the existing SGOpenSpotifyURI integration.

Local URI format is documented by Spotify:
https://developer.spotify.com/documentation/web-api/concepts/playlists

Documents import is the standard iOS local-files path:
https://support.spotify.com/be-fr/article/local-files/

The importer copies into the Spotify Documents root, retaining the original
playlist exports and chosen external directories. It reads the copied file's tags
and actual audio duration. Missing title tags are written on the import copy.
Copies have readable filenames and a persistent private manifest prevents repeated
imports. Imports are serialized to avoid filename and metadata-write races.

A request returning an object is not treated as completed playback: the native
state observer must report the selected local URI playing. On timeout the error
remains visible. There is no AVPlayer or reconstructed player fallback. Native
indexing timing and actual playback still require validation on a physical iPhone;
a compile/simulator test cannot prove the Spotify scanner has indexed a file.

The app's native local-track restrictions govern unsupported menu actions (local
tracks carry no online artist/album URI). Spoti.PW's additional lyrics footer
button is explicitly disabled for native local playback. Existing native controls
and queue are not replaced or relaid out.

## Context-menu spacing

The prior header-only test missed two independent sources of blank space: the
outer table positioning and scroll insets. PWTrackMenuLayout is restricted to a
track menu containing our download header. It aligns the native content region
below the actual visible title/artwork, replacing only its top-position constraint,
clears the top scroll inset and keeps the native data source and index paths.
Empty UIControls no longer count as meaningful prior-header content. Native row
font/icon alignment and the green subtitle indicator are retained.

UIKit regression tests exercise a 500-point outer gap, a 300-point scroll inset,
empty controls, repeated layout and subtitle reuse. On-device appearance remains
a required practical confirmation.
