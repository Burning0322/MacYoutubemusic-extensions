const ENDPOINT = "http://127.0.0.1:47833/state";

let lastPayload = "";

function textFrom(selector) {
  const node = document.querySelector(selector);
  return node?.textContent?.trim() || "";
}

function playerBar() {
  return document.querySelector("ytmusic-player-bar");
}

function getTitle() {
  const bar = playerBar();
  return (
    bar?.querySelector(".title")?.textContent?.trim() ||
    textFrom("ytmusic-player-bar .title") ||
    textFrom("yt-formatted-string.title") ||
    document.title.replace(" - YouTube Music", "").trim()
  );
}

function getArtist() {
  const bar = playerBar();
  const byline = bar?.querySelector(".byline")?.textContent?.trim() || "";
  if (byline) return byline.replace(/\s+/g, " ");

  const subtitle = bar?.querySelector(".subtitle")?.textContent?.trim() || "";
  if (subtitle) return subtitle.replace(/\s+/g, " ");

  return "";
}

function getAlbumArtUrl() {
  const bar = playerBar();
  const image =
    bar?.querySelector("img.image") ||
    bar?.querySelector("yt-img-shadow img") ||
    document.querySelector("ytmusic-player-page img");
  return image?.src || "";
}

function getMedia() {
  return document.querySelector("video") || document.querySelector("audio");
}

function getLyricsLines() {
  const candidates = [
    "ytmusic-tab-renderer[page-type='MUSIC_PAGE_TYPE_TRACK_LYRICS']",
    "ytmusic-player-page ytmusic-tab-renderer[page-type='MUSIC_PAGE_TYPE_TRACK_LYRICS']",
    "ytmusic-player-page tp-yt-paper-tab[aria-selected='true'] ~ *",
    "ytmusic-description-shelf-renderer",
    "ytmusic-player-page ytmusic-tab-renderer"
  ];

  for (const selector of candidates) {
    const node = document.querySelector(selector);
    const text = node?.innerText || node?.textContent || "";
    const lines = normalizeLyrics(text);
    if (lines.length >= 2) return lines;
  }

  return [];
}

function getLyricsStatus(lines) {
  if (lines.length > 0) return "available";
  const pageText = document.body?.innerText || "";
  if (/Lyrics/i.test(pageText) || /歌词/.test(pageText)) return "lyrics-tab-not-open";
  return "unavailable";
}

function normalizeLyrics(text) {
  const reject = new Set([
    "UP NEXT",
    "RELATED",
    "LYRICS",
    "SIGN IN",
    "START RADIO",
    "SHUFFLE",
    "SAVE"
  ]);

  return text
    .split(/\n+/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .filter((line) => line.length < 160)
    .filter((line) => !reject.has(line.toUpperCase()))
    .slice(0, 80);
}

async function sendState() {
  const media = getMedia();
  const duration = Number.isFinite(media?.duration) ? media.duration : 0;
  const position = Number.isFinite(media?.currentTime) ? media.currentTime : 0;
  const title = getTitle();

  if (!title && !media) return;

  const lyricsLines = getLyricsLines();
  const payload = {
    source: "youtube-music",
    title,
    artist: getArtist(),
    albumArtUrl: getAlbumArtUrl(),
    isPlaying: Boolean(media && !media.paused && !media.ended),
    position,
    duration,
    lyricsLines,
    lyricsStatus: getLyricsStatus(lyricsLines),
    updatedAt: Date.now() / 1000
  };

  const serialized = JSON.stringify(payload);
  if (serialized === lastPayload && !payload.isPlaying) return;
  lastPayload = serialized;

  try {
    await fetch(ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: serialized
    });
  } catch (_) {
    // The macOS visualizer is not running. Keep polling silently.
  }
}

setInterval(sendState, 500);
sendState();
