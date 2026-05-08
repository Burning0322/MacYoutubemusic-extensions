# YouTube Music Island

Local macOS Dynamic Island style visualizer for YouTube Music.

## Run the macOS visualizer

```bash
./build.sh
./run.sh
```

The visualizer listens only on:

```text
127.0.0.1:47833
```

## Load the Chrome extension

1. Open Chrome.
2. Go to `chrome://extensions`.
3. Enable `Developer mode`.
4. Click `Load unpacked`.
5. Select:

```text
/Users/renhonglow/Documents/MacYoutubemusic extensions/extension
```

Then open `https://music.youtube.com`, play a song, and the macOS island should appear near the top of the screen.

## Notes

- Lyrics are approximate. The extension reads visible YouTube Music lyric text and the app highlights a line based on playback progress.
- The waveform is playback-state driven, not exact audio FFT.
- No YouTube or Google account credentials are read or transmitted.
