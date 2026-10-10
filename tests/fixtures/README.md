# Audio fixture

`soundcloud-au-dd-public.json` contains selected public metadata observed on
2026-10-10 at `https://soundcloud.com/pnl_music/au-dd` and in its public search
results. The verified PNL recording advertises `MONETIZE`, not `ALLOW`, and an
unsnipped MP3 progressive stream. The stream resolver and media probe returned
HTTP 200 and 206 without an account. Resolver URLs have been replaced with a
nonfunctional fixture endpoint; no audio, client ID, authorization value, signed
URL or user data is included. This case tests metadata selection, not iPhone
playback or permanent catalogue availability.

`dash-aac.m4a.b64` is an original synthetic 440 Hz sine wave (12 seconds),
encoded as fragmented DASH AAC. It contains no downloaded music or user data.
Generated with the following command; FFmpeg is used only to create this test
fixture, never embedded in the app:

```sh
ffmpeg -f lavfi -i 'sine=frequency=440:sample_rate=44100:duration=12' \
  -ac 1 -c:a aac -b:a 32k -movflags dash -frag_duration 1000000 fragmented.m4a
```

The macOS integration test copies compressed AAC packets into a standard M4A,
checks its duration, and decodes every output audio frame. A second fixture
variant declares 12 seconds in the initial movie/track/media headers too. A
24-second requested song and a corrupt input must remain rejected.

`soundcloud-mp3.b64` is another original 12-second 440 Hz sine wave, encoded
as mono MP3 without Xing/ID3 headers, like a contiguous public MP3 HLS recording.
Generated with FFmpeg (test fixture creation only):

```sh
ffmpeg -f lavfi -i 'sine=frequency=440:sample_rate=44100:duration=12' \
  -ac 1 -c:a libmp3lame -b:a 32k -write_xing 0 -id3v2_version 0 soundcloud.mp3
```
