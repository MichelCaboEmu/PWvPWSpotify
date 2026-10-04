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

## Official behavior and remaining integration boundary (2026-10-04)

Sources inspected:
- https://support.spotify.com/us/article/listen-offline/
- https://support.spotify.com/us/article/local-files/

| Behavior | Official Spotify | This integration |
| --- | --- | --- |
| Loss of internet | Downloaded content remains playable in the usual app | No automatic custom modal or replacement library; Spotify owns network/offline UI |
| Explicit Offline mode | Native setting restricts playback to available content | Native setting remains untouched; local-file playback uses the native engine |
| Player and queue | Native transports, shuffle, repeat, queue | Same engine and screens, using local URIs |
| Library Downloaded filter / gray unavailable songs | Availability in Spotify's internal offline cache | External exports are NOT registered in that cache; no fake offline flags |
| External audio | iOS Local audio files setting, Documents import, Local Files screen | Import copies into Documents; settings shortcut opens the native screen |
| Playlist membership | Spotify playlist metadata and offline availability are separate | Export folders retain playlist names/membership; this does NOT yet map original catalog playlist entries to local URIs |
| Unavailable local-track actions | Native restrictions for local tracks | Native restrictions retained; the extra PW lyrics button is disabled |

The earlier automatic PWOfflineStartup modal was not official behavior and is
removed, including its switch. This does not claim that all downloaded external
files now behave as native catalog downloads. Bridging the original playlist's
playability, selected row, local URI mapping and availability observers remains
unimplemented. Setting OfflineManager's availability alone would make promises
that its playback/cache cannot honor, so no such spoofing is installed.

## Embedded artwork

The executable provides SPTLocalAVAssetImageLoaderRequest. Its loadLocalFileImage
(0x1066d1b60) calls NSURL(BetamaxSDK).spt_localFileImagePath (0x1011b3f6c), which
decodes URI component 2 with stringByRemovingPercentEncoding. The accepted URL
is `spotify:localfileimage:<percent-encoded absolute audio path>`; the predicate
spt_isLocalFileImageURL (0x1003a5d34) verifies the three-component form.

Imported descriptors now include that native artwork reference. SPTPlayerTrack
metadata/imageURL getters also restore it for manifest-owned local URIs rebuilt
by the scanner. The native image loader, cells and player still render it. Paths
come only from safe filenames in our private manifest and the current Documents
directory, so reinstall/container changes do not retain stale absolute paths.
Unmanaged local files and online tracks are unchanged.

PW's redesigned artwork bridge accepted only Spotify CDN/HTTP images. It now
reads the same embedded artwork for registered local URIs, checking both URI and
image identity before publishing an asynchronous result. Native art loading and
physical-device behavior still require verification in Spotify, not just UIKit.

## Context-menu spacing: revised strategy

The user still observed the gap after 841cf484. The previous test modeled a table
with an arbitrary top constraint; it did not model Spotify's actual sizing graph.
That old constraint replacement is removed.

Binary inspection verifies mainView > headerView + divider + bottomLayout +
bottomSpacer; bottomLayout > contentContainer > native table (0x10282320c and
0x101fbeb80). viewDidLayoutSubviews (0x102e7e7f0) updates content height and computes
preferredContentSize using systemLayoutSizeFitting (0x10669e148).

The action header is installed before this measurement and puts Download first,
with stable sizing independent of incidental prior-header stretching. The fix
uses the verified `context-menu-header-view` and `context-menu-bottom-layout`
identifiers, measures the native header's compressed height, and lets the native
bottom spacer absorb unused sheet height. The spacer is identified by its anchor
relationships, not a guessed screen position. Native top anchors and row index
paths stay intact. Unknown hierarchies are not repositioned.

The revised UIKit fixture reproduces the nested containers, a stretched title
header, fixed content height, bottom spacer, repeated sizing and top insets. Logs
capture native header/container/table/first-row geometry at 0, 1 and 5 seconds so
device differences can be diagnosed without another blind offset adjustment.
This is a candidate fix until the real menu on the user's iPhone confirms it.
