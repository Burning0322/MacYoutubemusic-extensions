const ENDPOINT = "http://127.0.0.1:47833/state";
const COMMAND_ENDPOINT = "http://127.0.0.1:47833/commands";

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

function clickFirst(selectors) {
  for (const selector of selectors) {
    const node = document.querySelector(selector);
    if (node) {
      node.click();
      return true;
    }
  }
  return false;
}

function applyCommand(command) {
  const media = getMedia();
  switch (command.action) {
    case "playPause":
      if (!clickFirst([
        "ytmusic-player-bar .play-pause-button",
        "ytmusic-player-bar tp-yt-paper-icon-button.play-pause-button",
        "ytmusic-player-bar #play-pause-button"
      ])) {
        if (media?.paused) media.play();
        else media?.pause();
      }
      break;
    case "previous":
      clickFirst([
        "ytmusic-player-bar .previous-button",
        "ytmusic-player-bar tp-yt-paper-icon-button.previous-button",
        "ytmusic-player-bar #left-controls tp-yt-paper-icon-button:first-child"
      ]);
      break;
    case "next":
      clickFirst([
        "ytmusic-player-bar .next-button",
        "ytmusic-player-bar tp-yt-paper-icon-button.next-button",
        "ytmusic-player-bar #left-controls tp-yt-paper-icon-button:last-child"
      ]);
      break;
    case "seek":
      if (media && Number.isFinite(command.value)) {
        const duration = Number.isFinite(media.duration) ? media.duration : Infinity;
        media.currentTime = Math.max(0, Math.min(duration, media.currentTime + command.value));
      }
      break;
  }
}

async function pollCommands() {
  try {
    const response = await fetch(COMMAND_ENDPOINT);
    if (!response.ok) return;
    const commands = await response.json();
    if (!Array.isArray(commands)) return;
    for (const command of commands) applyCommand(command);
  } catch (_) {
    // The macOS visualizer is not running. Keep polling silently.
  }
}

setInterval(sendState, 500);
setInterval(pollCommands, 250);
sendState();
pollCommands();
