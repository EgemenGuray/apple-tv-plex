# Plex HDR for Apple TV

A Plex client for Apple TV 4K, built the way Infuse works: it plays the original file with its own FFmpeg-based
player, so MKV remuxes open as they are, nothing is converted on the server, and every audio track (TrueHD, DTS-HD MA,
DD+, AC3…) is decoded on the Apple TV into multichannel PCM. tvOS turns that into **Spatial Audio on AirPods**.

It is the tvOS sibling of [tizen-plex](https://github.com/EgemenGuray/tizen-plex) and has the same screens and
features (Apple TV-style UI, top shelf, chapters, Skip Intro, Up Next, scrub thumbnails, online subtitles, ratings,
TMDB artwork, per-title memory, cast & crew).

The player is [KSPlayer](https://github.com/kingslay/KSPlayer) (GPL build, FFmpeg + Metal). It is pinned to one
commit in `project.yml` because its core ships as a binary framework.

## What the Apple TV allows

| Goal | Here | Why |
|---|---|---|
| **MKV direct play** | **Yes** | The app demuxes MKV itself (FFmpeg). The server is never asked to convert anything. |
| **HDR10 / HLG** | **Yes** | Sent to the TV as they are, with "Match Dynamic Range" on. |
| **HDR10+** | **Yes** (Apple TV 4K 2022, tvOS 16+) | KSPlayer passes HDR10+ dynamic metadata; the TV must support HDR10+ (the QN900B does). |
| **Dolby Vision** | **Partly** | Profile 8 files that also carry HDR10+ (common in recent releases) play as HDR10+, and the app labels them that way. Profile 8 without HDR10+ plays its HDR10 base layer; profile 5 is converted to HDR10 by the player. Real Dolby Vision output is only in KSPlayer's paid build, and Samsung TVs can't show Dolby Vision anyway. |
| **8K** | **No (4K output)** | Apple TV 4K outputs at most 4K, so 8K files are scaled down. The app shows an 8K badge and says so; play 8K with the TV's own app. |
| **Spatial Audio on AirPods** | **Yes, for every surround track** | Every track is decoded to 5.1/7.1 PCM and the audio session runs in movie mode with multichannel content allowed, so tvOS spatializes it with head tracking. This includes TrueHD, DTS, DTS-HD MA, DD+ and AC3, exactly as Infuse does. |
| **Dolby Atmos with height** | **DD+ Atmos only, through Apple's decoder** | Apple's own decoder keeps Atmos objects for Dolby Digital Plus (E-AC3 JOC): to a soundbar as Dolby Atmos, and on AirPods as Spatial Audio with height. The app uses it automatically for DD+ Atmos tracks: MP4/MOV files play directly, and MKV files are repackaged by the server as HLS (video and audio copied, nothing re-encoded) because Apple's player can't open MKV. Without this, DD+ Atmos arrives at the soundbar as multichannel PCM. Set the Apple TV's **Settings → Video and Audio → Audio Format** to Dolby Atmos. If Apple's player can't open the stream, the app retries once and then falls back to its own player (multichannel PCM). TrueHD Atmos is decoded to 7.1 PCM: the height objects are folded into the 7.1 mix. That's the Apple TV's limit, and Infuse has the same one. |
| **Lossless audio to a receiver** | **Yes, as multichannel PCM** | Apple TV can't bitstream TrueHD or DTS. It sends decoded 7.1 PCM over HDMI, which is lossless. |
| DTS / DTS:X | **Yes, decoded** | DTS:X objects are folded into 7.1. |
| Image subtitles (PGS, VobSub) | **Yes** | Drawn by the player. Samsung's AVPlay couldn't do this. |
| Audio delay / lip sync | Not added yet | KSPlayer has a video delay option; it isn't exposed in the panel. |
| Playback speed | **Yes** | 0.75× to 2×, pitch kept. |

### Spatial Audio checklist
1. Connect the AirPods to the Apple TV.
2. Open Control Center on the Apple TV (hold the TV button), select the AirPods tile, and set **Spatial Audio** to
   **Fixed** or **Head Tracked**.
3. Play a 5.1/7.1/Atmos title. The player's **Audio** tab (swipe down → Audio) shows the output, e.g.
   `AirPods Pro · 8 ch · Spatial Audio`.

## What the app does

### Screens
- **Tab bar** at the top: Home, each movie and TV library, Search, Settings.
- **Home** opens on a full-screen **top shelf**: big artwork, title logo, year, rating, runtime, genres, ratings and
  summary, with Play/Resume and More Info. It moves to the next title every 9 s while you rest on it; ◀ on Play and ▶
  on More Info flip between titles. Below it: Continue Watching (wide cards with progress) and Recently Added for every
  library. The background cross-fades to whatever card has focus.
- **Sign-in**: scan the QR code with a phone that's signed in to Plex, or enter the code at plex.tv/link.
- **Libraries**: poster grid that loads more as you scroll (films newest release first by default), with Sort (title, date added, release date, rating,
  recently watched), Unwatched only, Genre and Collections.
- **Show page**: backdrop and logo, Play/Resume the next episode, Mark watched, season pills (moving onto a season
  loads it), episode row with stills, Cast & Crew, More Like This.
- **Details** (movie or episode): logo or title, metadata, badges (4K, HDR10+, Dolby Vision, Dolby Atmos, 5.1/7.1,
  Spatial Audio, CC/SDH), ratings, summary, and one line that says how it will play (which player, which track, PCM or
  Atmos). Buttons: Resume / Play, Start Over, Trailer, Audio & Subtitles, Version, Mark Watched, Info (technical sheet).
  Rows: Chapters (press one to start there), the rest of the season, Cast & Crew, Extras, More Like This.
- **Cast & Crew**: actors with their roles, then directors, writers and producers (one card per person, all their jobs).
  Press a person to see everything they're credited on in your libraries.
- **Ratings** with each site's logo, in this order: IMDb, Letterboxd, Tomatometer (fresh, Certified Fresh or rotten logo by score), RT Audience (upright or tipped popcorn), Metacritic user score, Metascore.
- **Search** with the tvOS keyboard (and dictation / iPhone keyboard).
- **Settings**: Plex Home user switching (with PIN pad), server, audio track preference and language, Atmos options,
  subtitle mode/language/size/colour/style/position, autoplay next, auto-skip intro/credits, skip intervals, match frame
  rate, online service keys, and a remote-control cheat sheet.

### The player
| Siri Remote | Action |
|---|---|
| Click / Play-Pause | Play / pause. When **Skip Intro** or **Up Next** is on screen, click presses it |
| ◀ / ▶ (click or swipe) | Back 10 s / forward 30 s (configurable). **While paused**: scrub with preview thumbnails (holding speeds up), click jumps there, Back cancels |
| Swipe down | Panel: **Info**, **Chapters**, **Audio**, **Subtitles**, **Picture** |
| Swipe up | Show the timeline |
| Back / Menu | Close the panel, or stop |

- The overlay shows the title, badges, chapter name, a timeline with chapter ticks and intro/credits segments, elapsed
  and remaining time, and "Ends at".
- **Skip Intro** appears during Plex intro markers (or skips by itself). **Up Next** appears at the credits marker (or
  30 s before the end) with a 10 s countdown and keeps your audio and subtitle language for the next episode.
- **Preview thumbnails** come from the server's BIF files ("Generate video preview thumbnails" in Plex server settings).
- **Subtitles**: embedded text and image subtitles, external SRT/ASS/SSA/VTT files from Plex, delay in 0.1 s steps.
  **Search Online…** searches OpenSubtitles directly (with the file hash, so results cut for your exact file come first,
  like Infuse) and your server's own subtitle search. A downloaded subtitle shows straight away and is kept on the Apple
  TV, so replaying doesn't use your download quota.
- **Audio**: every track in the file; switching is instant. Speed 0.75–2×. Output route and channel count.
- **Picture**: original, zoom to fill, stretch.
- Reports progress to Plex and also **remembers each title on the Apple TV**: position, version, audio track,
  subtitle and downloaded subtitle. Resume uses whichever is newer, the Apple TV's record or the server's.

## Online services (optional, all free)
Enter keys in **Settings → Online services** (the Apple TV Remote on an iPhone makes typing easy), or put them in
`PlexHDR/Services/Keys.swift` before building.

| Key | Get it at | Used for |
|---|---|---|
| TMDB | themoviedb.org → Settings → API (v3 key or v4 read token) | Logos, backdrops and posters missing from Plex |
| OMDb | omdbapi.com → API Key | IMDb, Metascore and Rotten Tomatoes when Plex doesn't have them |
| OpenSubtitles | opensubtitles.com → Profile → API consumers | Online subtitle search and download. Add username and password for a higher daily limit |

Metacritic user score and Letterboxd have no public API; their public pages are read and may stop working if those
sites change their layout.

## Infuse feature parity

| Infuse feature | Here | Notes |
|---|---|---|
| Plays any file (MKV, MP4, TS, AVI…) without server conversion | Yes | FFmpeg player |
| Spatial Audio for all surround formats | Yes | Multichannel PCM up to 7.1 |
| Dolby Atmos (DD+) with height | Yes | Apple's decoder; MKV through a server remux |
| TrueHD / DTS-HD MA decoding | Yes | Lossless PCM over HDMI |
| HDR10 / HDR10+ / HLG, match frame rate and range | Yes | Needs "Match Content" on in tvOS settings |
| Dolby Vision output | No (P8 → HDR10 base, P5 → HDR10) | Paid KSPlayer feature; Samsung TVs can't show DV anyway |
| Artwork-first browsing, top shelf, details, cast, extras, related | Yes | |
| Continue watching, Up Next, Skip Intro / credits | Yes | Plex markers |
| Library sort, filters, genres, collections, search | Yes | |
| Chapters, scrubbing with thumbnails | Yes | |
| Text and image subtitles, styling, delay, forced, languages | Yes | |
| OpenSubtitles download with hash matching | Yes | |
| Ratings and TMDB artwork | Yes | |
| Per-title memory, versions, Plex Home users, watched sync | Yes | |
| Playback speed | Yes | |
| Audio delay | Not yet | |
| Picture in picture, downloads, Trakt, music, photos, Live TV | Not added | |
| SMB/NFS/WebDAV shares | Out of scope | This is a Plex client |

## Install on your Apple TV

You need a Mac with **Xcode 26** or newer and an Apple ID.

1. On the Mac: `./scripts/setup.sh` (installs [XcodeGen](https://github.com/yonaskolb/XcodeGen) with Homebrew if
   needed, generates `PlexHDR.xcodeproj` and opens it). Xcode then downloads KSPlayer and FFmpegKit, which takes a few
   minutes the first time.
2. In Xcode: select the **PlexHDR** target → **Signing & Capabilities** → choose your Team (your Apple ID works).
   If the bundle id is taken, change `com.egemenguray.plexhdr` to something unique.
3. Pair the Apple TV: on the Apple TV open **Settings → Remotes and Devices → Remote App and Devices**. In Xcode open
   **Window → Devices and Simulators**, pick the Apple TV and enter the code it shows. Mac and Apple TV must be on the
   same network.
4. Pick the Apple TV as the run destination and press **Run** (⌘R). The app installs and starts.

With a free Apple ID the app stops opening after 7 days and needs another Run from Xcode. A paid Apple Developer
account ($99/year) makes it last a year, or lets you install it through TestFlight.

The app needs a real Apple TV: KSPlayer's binary framework has no tvOS Simulator slice.

On the Apple TV, turn on **Settings → Video and Audio → Match Content → Match Dynamic Range** and **Match Frame Rate**.
For a soundbar or receiver, set **Audio Format → Change Format** to Dolby Atmos if it supports it.

## How the code is laid out
| File | Role |
|---|---|
| `project.yml` | XcodeGen project: tvOS 17+, KSPlayer package, Info.plist |
| `PlexHDR/App/PlexHDRApp.swift` | App entry, audio session (movie mode, multichannel, Spatial Audio), player defaults, routes |
| `PlexHDR/Plex/PlexClient.swift` | plex.tv PIN sign-in, Plex Home users, server discovery, library API, playback URLs, progress |
| `PlexHDR/Plex/PlexModels.swift` | Lenient wrappers for Plex JSON (items, media, parts, streams, markers, chapters, people) |
| `PlexHDR/Plex/Decide.swift` | Which audio and subtitle track, which player (FFmpeg or Apple's for DD+ Atmos), badges |
| `PlexHDR/Services/Online.swift` | TMDB artwork, ratings (Plex, OMDb, Metacritic, Letterboxd), OpenSubtitles hash, search, download |
| `PlexHDR/Services/TitleMemory.swift` | Per-title memory on the Apple TV |
| `PlexHDR/Services/BIF.swift` | Plex preview thumbnails |
| `PlexHDR/Services/AppSettings.swift`, `Keys.swift` | Settings and optional build-time keys |
| `PlexHDR/Views/Screens/` | Home + top shelf, libraries, show, details, person, collection, search, settings, sign-in |
| `PlexHDR/Views/Player/` | Player controller (KSPlayer), overlay, timeline, scrubbing, panel tabs, Skip Intro, Up Next |
| `.github/workflows/build.yml` | Builds the app on a GitHub macOS runner on every push |

## What has and hasn't been checked
- Builds cleanly for tvOS with Xcode 26.3 (GitHub Actions, unsigned device build, on every push).
- **Not yet run on an Apple TV.** Things to check on the first run:
  1. That KSPlayer's audio track ids match Plex's stream indexes (the app also falls back to track order).
  2. That embedded subtitle tracks map the same way.
  3. Spatial Audio on AirPods with a TrueHD 7.1 and a DD+ Atmos title (the Audio tab shows the route).
  4. The DD+ Atmos path through Apple's decoder for MP4 files, and the experimental MKV remux.
  5. HDR10+ and Dolby Vision profile 5/8 output on the QN900B.
  6. The real TMDB, OMDb and OpenSubtitles services, and the Metacritic/Letterboxd page readers.
