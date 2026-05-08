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

If the island does not appear, reload the YouTube Music tab after loading the extension. Chrome only injects this extension into pages opened or refreshed after the extension is loaded.

Drag the island with the mouse to move it. The app remembers the last position.

Island buttons support previous, back 10 seconds, play/pause, forward 10 seconds, and next. The Chrome extension polls local commands from `127.0.0.1:47833` and applies them to the YouTube Music page.

For lyrics, open the YouTube Music player page and switch to the `Lyrics` tab. YouTube Music only exposes lyrics to the extension when they are present in the page.

## Notes

- Lyrics are approximate. The extension reads visible YouTube Music lyric text and the app highlights a line based on playback progress.
- The waveform is playback-state driven, not exact audio FFT.
- No YouTube or Google account credentials are read or transmitted.
