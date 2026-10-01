# Audio fixture

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
