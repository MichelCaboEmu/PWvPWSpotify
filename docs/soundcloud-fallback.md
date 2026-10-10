# SoundCloud fallback (base eca148e8)

This change starts exclusively at `eca148e8c274def19caf5728a9635781e35d795d`.
It does not change the local library, playlists, player or offline interface.

## Provider order

For YouTube Music and YouTube jobs: confirmed YouTube publication → SoundCloud
public website → Audius creator-enabled free download. The two fallback switches
can disable their respective provider. SoundCloud is enabled by default. Choosing
Audius directly still uses Audius directly; official Spotify mode remains separate.
When Music finds no confirmed accessible recording, public YouTube video search
also checks the artist's channel before moving to SoundCloud. Cookie consent and
transport/extractor failures still keep their explicit pause behavior.

An HTTP 403 from an audio transfer gets exactly two logical attempts, separated by
three seconds, before switching provider. Consent, quotas, cancellation and an
extractor malfunction do not silently trigger another provider. Each search,
provenance rejection, transfer attempt and actual fallback source is logged. No
cookies, signed URLs, public web client IDs or track authorization values are logged.

## Why a new native adapter

Research project: [scdl](https://github.com/scdl-org/scdl), whose version 3 uses
[yt-dlp's SoundCloud extractor](https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/extractor/soundcloud.py).
The extractor blob inspected was `43bcadfb3ae5f28c1b1ca39ec6b0a5f098b91e0f`.
These projects require Python; scdl also lists ffmpeg. Neither runtime is embedded
in this iPhone app. This independently written Swift adapter implements the public
website protocol: discover the current client configuration in SoundCloud's own
JavaScript, search public tracks, resolve the announced transcoding and transfer
the public media. Its Foundation-only rules and native AVFoundation conversion
are tested separately. No upstream Python code is copied into the app.

“Without API registration” means no personal developer application, OAuth token,
Artist Pro subscription or bundled client secret. The public website itself uses
`api-v2.soundcloud.com`; this is web extraction, not a promise of zero API HTTP
requests. [API application registration](https://developers.soundcloud.com/docs/api/register-app)
currently requires Artist Pro, while [API terms](https://developers.soundcloud.com/docs/api/terms-of-use)
describe API usage as free and reserve the right to charge later.

## Recording selection and limits

YouTube candidates require a matching artist identity, title/version and duration,
plus an artist/verified channel badge or distributed audio metadata. Topic and
YouTube Music distributed-audio candidates additionally require the extractor's
description to contain the distribution and auto-generation markers. A title
saying “official” is insufficient. Unlabelled extra titles and named altered
versions (instrumental, cover, pitch, reverb, sped/slowed, etc.) are rejected.
An inaccessible confirmed publication or no compatible full stream can trigger
SoundCloud, rather than choosing an unofficial substitute.
A duration mismatch confirmed from the actual audio packets also triggers the
fallback. This covers a provider returning only a preview despite advertising
the full song's duration. Unrelated container/write failures retain their errors.

SoundCloud requires matching artist/title/version/duration and either matching
Spotify ISRC or the artist's verified profile. A conflicting ISRC is rejected.
Only public, streamable `ALLOW` tracks and standard-quality complete MP3
progressive/unencrypted HLS transcodings are used. Previews, `SNIP`/`BLOCK`, private
tracks, paid/high-quality-only streams, encryption, DRM, login walls and unsupported
HLS layouts fail clearly. No CAPTCHA or anti-bot evasion is implemented. An expired
website configuration is refreshed once on HTTP 401; HTTP 403 does not cause an
identity, account or fingerprint change.
Search/configuration HTTP errors identify their stage and are distinguished from
audio 403 errors; the three-second media retry does not retry a website challenge.

HLS manifests must be finite and match the requested duration. Segment URLs stay
on SoundCloud's HTTPS media CDN, with byte/segment/time limits and cancellation.
AVFoundation converts the joined MP3 into M4A and checks decoded duration and an
audio track before registration. Files keep the existing naming, tagging and
playlist destination pipeline. No temporary or incomplete file enters the library.

Metadata checks cannot prove acoustic authenticity or guarantee that a provider's
catalogue contains a specific PNL recording. If the free public catalogues lack a
reliable full recording, the track remains in error; no premium-only recording is
unlocked and no unrelated substitute is accepted.

## Validation

The verify workflow runs on `ajout-de-soundcloud`. It exercises provenance,
apostrophes, fake artist identities, mismatched ISRCs, previews, unsupported or
encrypted HLS, origin validation, fallback order and diagnostic redaction. A
synthetic MP3 fixture exercises the production native converter and complete PCM
decoding, plus preview/corrupt input rejection. Existing assembly, layer, transfer,
library, native identity and iOS UI checks remain in place. Public website extraction
still needs an iPhone test under the user's region/network; fixture tests do not
claim live provider coverage.
