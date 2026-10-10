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

## Playlist bridge — next device validation

The user confirmed that native playback works, but requested playback directly
from the original playlist and Liked Songs instead of the combined Local Files
view. The following addition does not mutate server-side playlists:

- Verified `FTPEstimatedHeightTableDelegate` selection methods for UICollectionView
  and UITableView dispatch a finite queue of available files for the displayed
  playlist. Unknown or unavailable selected music rows are blocked, never replaced
  by the first available song. Exact title/artist resolution must be unambiguous.
- Verified `FTPViewModelImplementation.play` supplies the same playlist-scoped
  queue for its native Play button. Pause/resume use the existing player only
  when the actual native context matches that playlist.
- Native context URI remains the original playlist or `spotify:collection:tracks`;
  supplied pages contain only local URIs, with no network continuation. Original
  selection is remapped after unavailable files are removed from the queue.
- A complete displayed model supersedes cached membership. Incomplete models use
  only that playlist's saved members plus newly verified rows, never all files.
  Cached unloaded membership may still be stale until Spotify refreshes it.
- `NWPathMonitor` observes disconnection. Native `SPTConnectivityManagerImplementation`
  initialization and both `setAllowNetwork:` variants observe manual Offline
  mode; the tweak does not change that mode or introduce an offline popup.
- Existing native rows are dimmed when unavailable. Online selection goes through
  unchanged. Menu actions stay available; blocking concerns starting playback.

New selectors/signatures were checked against the complete 9.1.78 executable:
collection selection 0x107ed91f8 (`v32@0:8@16@24`), view model play
0x1019ca844 (`v16@0:8`), native allowNetwork initializer
0x109784a38 (`@44@0:8@16B24@28@36`), both setters
0x1097857fc and 0x109785890. SPTPlayerState.contextURI is verified at
0x101a270cc. Native pause:/resume: return the engine's command objects.

The remaining menu alignment was measured in cell-local coordinates even though
the injected header spans the whole table. The fix converts label/icon positions
into the header's coordinates, preserving native cell insets. A UIKit fixture
with a 24-point cell inset guards this regression.

The native Documents import remains the known-working scanner input. New imports
and playlist exports use hard links when supported: both paths remain visible,
but share physical audio storage. External providers/volumes fall back to copies.
Previously imported manifest-owned files are consolidated on reuse only when
their bytes match; differently tagged files are retained. Metadata writers must
replace files, never mutate shared audio in place. No assumption is made about
recursive indexing. Physical iPhone validation is still required for the new
playlist entry points and context URI.

## Device regression 2026-10-10: root import and wrong tap entry point

The user reports 65beae3 still uses Local Files, grays downloaded songs and shows
an action gap. The prior delegate fixture was insufficient: disassembly of
collection selection 0x107ed91f8 -> 0x1074ad228 shows only deselection, not the
original playback command. Offline row taps now use a cell-owned gesture which
cancels the native row tap, excluding the menu/save controls and allowing scroll.
Only original playlist/Liked Songs URIs qualify; Local Files shares the same FTP
cell classes but is expressly excluded. Available rows lift native remote-track
dimming; unavailable rows are dimmed and blocked. Online behavior passes through.
Native Library navigation now targets the verified `spotify:collection` route.
No custom Library or player replaces Spotify's screens. The Library and playlist
contents still depend on Spotify's own previously loaded cache; this cannot make
an unseen cloud playlist available while disconnected.

The binary exposes a native folder service: EsperantoServiceImpl's
provideEsperantoTransport (0x10104495c) returns a bridge supporting
callSingle:method:payload:onResponse: (0x1097d48d8, @48@0:8@16@24@32@?40).
Its callback wraps response bytes as one NSData argument (0x1097d5038).
Embedded es_local_files.proto (file offset 0xa1043cc) declares service
spotify.local_files_esperanto.proto.LocalFiles, method AddFolder, Folder.path=1.
MutateSourceResponse.result=1 enum: UNKNOWN=0, SUCCESS=1, NOT_FOUND=2,
NOT_CHANGED=3. This confirms an API exists, not that iOS accepts every directory.
The implementation requires an explicit accepted reply and keeps the command
lifetime until callback/timeout. Every canonical playlist directory is registered;
no new Documents-root import is made. External chosen roots remain security scoped.
Existing manifest-owned root imports are moved to a private reversible backup
only if their bytes equal the canonical file and folder registration succeeded.
The backup is discarded only after native playback reports local_file_path equal
to the canonical source. Nonidentical/user-created files are preserved and logged.
Artwork now references the canonical playlist path, not a synthesized Documents
filename. Indexing refusal or unconfirmed playback remains an explicit error;
there is no silent fallback to creating another root file or another player.

Download is now an actual UITableView action row. It no longer wraps
 tableHeaderView. Index paths are translated for native actions; other sections,
headers and footers remain native. An empty leading table spacer is discarded,
real native controls are retained. UIKit tests exercise real rows in tall sheets,
adjacency, icon coordinates, asynchronous action counts and selection mapping.
The new protocol fixture tests UTF-8 varints and rejects ambiguous replies.
Device logs include response result and action_gap between actual first rows.

This remains a device-validation candidate: the native folder API, cache behavior,
row recognizer ordering and playlist context resolution cannot be proven using
standalone UIKit fixtures or compilation. Validate on Spotify 9.1.78/iOS 26.4.1.


## Connectivity and Library filter candidate — 2026-10-10

The supplied screenshot shows airplane mode and Spotify's own offline banner.
The folder failure is separate from streaming connectivity. Read the captured
SPTConnectivityManagerImplementation.allowNetwork getter (0x103497b58) at each
selection, combined with NWPathMonitor, rather than trusting an old dispatched
setter argument. Cancel playlist preparation on return online and suppress a
late offline-only failure. Native streaming selection remains untouched online.

LocalFilesSettingsModelImpl.setEnabled: (0x1050a9174) sets its preference and
notifies the native observer, without calling the MediaLibrary authorization
path in enable:. Enable the embedded LocalFiles MutateDefaultSource with
DefaultSource.id=IOS_DOCUMENTS(6), enabled=true. AddFolder remains preferred;
when refused, query GetTracks and require the expected local content_uri in its
actual successful response. Embedded proto declares Query.range=3,
Range.length=2, Response.item=1 and Item.content_uri=5. Well-formed unknown
protobuf fields are allowed; duplicate result fields and truncated fields fail.
No Documents-root copy is introduced. Folder activation and scanning behavior
still require validation in the signed iPhone app, including external roots.

The Library filter is attached to YourLibraryView.layoutSubviews (0x100f881d0).
Native YourLibraryContentViewBinder.model.content.sections and each window's
items/range resolve original playlist URIs, including Liked Songs. Layout
attributes are reflowed while the native data source, index paths and actions
remain unchanged. YourLibraryCollectionViewFlowLayout overrides prepareLayout
(0x10663f8c0), elements (0x1021953cc) and item attributes (0x103ebe3d0);
UIKit compositional layouts are also covered. The chip qualifies catalog
playlists with at least one existing, verified audio file belonging to them.
Unknown native schemas disable filtering instead of guessing row identities.
Tests cover window offsets, canonical playlist identities, network transitions,
list/grid reflow, hidden items, empty results and unchanged native item counts.
The full native header hierarchy and indexer acceptance remain device checks.
