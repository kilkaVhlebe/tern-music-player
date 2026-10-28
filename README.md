# Music Player for Tern

A YouTube Music and SoundCloud player for [Tern](https://stencil.so/tern): a
native block with a now-playing panel, four tabs — **Home**, **Search**,
**Queue**, **Library** — merged search across both catalogs, recommendations
built from your listening history, related-track autoplay that crosses
sources, automatic replacement of failed tracks from the other source, saved
playlists, palette commands, a status-line segment and a route for clicked
track links.

Playback runs through `mpv --idle` in the background — no browser, no ads, no
video, nothing to keep on screen — and the block is a view of it: closing the
pane keeps the music playing, reopening finds it where it was.

## Requirements

- Tern (closed beta), desktop. Blocks and processes do not exist on iOS.
- [`mpv`](https://mpv.io) 0.33 or newer.
- [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) — mpv uses it to resolve stream
  URLs for playback.

```sh
winget install mpv yt-dlp          # Windows
brew install mpv yt-dlp            # macOS
sudo apt install mpv yt-dlp        # Debian/Ubuntu (or pipx install yt-dlp)
```

Both are found on `PATH` or in the usual install locations — winget, Chocolatey
and Scoop included — without extra setup; see
[Configuration](#configuration) to point at a copy somewhere else.

On Windows, console programs started from Tern would open console windows. The
plugin therefore builds a tiny windowless launcher (`tern-runner-<hash>.exe`,
C# compiled once with the `csc.exe` that ships with the .NET Framework in every
Windows 10/11) in its data directory and starts mpv and yt-dlp through it.
Until the launcher exists — the first seconds after install — or if it cannot
be built, the plugin falls back to a hidden Windows Script Host + PowerShell
runner. Nothing needs installing for either.

## Install

From the repository root, link the local checkout:

```sh
tern plugin link .
```

YouTube Music search needs the public `WEB_REMIX` client key in a
repository-root `.secrets.json` (Git ignores it):

```json
{ "youtube_music_api_key": "AIza…" }
```

The plugin fails closed if the file or value is missing. This is the shared
public YouTube Music web client key, not a project credential; keeping it in a
local file does not make it private.

Then run **Music Player: Open** from the command palette (`cmd+shift+y`),
click a YouTube or SoundCloud link in any pane, or open **New Music Player
block** directly. Every palette command is the action
`plugin.ytmusic.<id>`, so it can be bound with `tern.bind` or in
`settings.json` keybinds.

## Using it

The **now-playing panel** is always on top: cover, title, artist and source,
the position (the clock ticks in the window, so the block does not re-render
every second), transport, volume and the autoplay switch. Every control has a
tooltip naming its key. In a narrow or short pane — the picture-in-picture
float — the panel compacts.

Under it, four tabs. `tab` / `shift+tab` cycle them, `1`–`4` jump to one
(outside text fields), `/` opens Search.

| Tab     | Shows                                                                     |
| ------- | ------------------------------------------------------------------------- |
| Home    | **Recommended for you** (cover cards) and **Recently played**             |
| Search  | Tracks · Artists · Playlists · Podcasts, length and artist filters        |
| Queue   | The mpv playlist, the current track marked; save it as a playlist, clear |
| Library | Saved playlists: play, append to the queue, delete                        |

Lists work like a music app's: **click** selects, **double-click** plays (or
opens an artist/playlist/podcast), **right-click** offers *Play*, *Play next*,
*Add to queue* (queue rows: *Play*, *Remove*; playlists: *Play*, *Add to
queue*, *Delete*). Clicking a recommendation card plays it. Destructive
actions — **Clear** the queue, **Delete** a playlist — ask for a second press.

Keys outside text fields:

| Key            | Does                                   |
| -------------- | -------------------------------------- |
| `space`        | play / pause                           |
| `n` `p`        | next / previous track                  |
| `[` `]`        | seek ∓10 s (also `←` `→` in Queue)     |
| `+` `-`        | volume ∓5                              |
| `m` `s` `r`    | mute · shuffle · repeat (off → all → one) |
| `a`            | autoplay on/off                        |

Per tab:

| Tab     | Keys                                                                          |
| ------- | ----------------------------------------------------------------------------- |
| Home    | `←` `→` pick a card, `↑` `↓` pick a recent track, `enter` play, `e` add to queue |
| Search  | type to search (debounced), `↑` `↓` pick, `enter` play/open, `shift+enter` add to queue, `esc` back / clear / leave |
| Queue   | `↑` `↓` pick, `enter` jump, `d` remove, `c` clear (twice)                     |
| Library | `↑` `↓` pick, `enter` play, `e` add to queue, `d` delete (twice)              |

Track search queries YouTube Music and SoundCloud at once and merges both
lists — YouTube Music first, SoundCloud results deduplicated against them by
title and duration and labelled *SoundCloud*. Results appear as soon as the
first source answers. Artists, playlists and podcasts are YouTube Music only;
opening one lists its tracks, and **‹ Back** returns to the results.

**Play all** replaces the queue with the visible results, **Add all**
appends them. In Library, name a playlist and **Save queue** (or **Save
results** while search results exist); saving an existing name
(case-insensitive) replaces it. The library holds up to 40 playlists of 200
tracks each, in the plugin's key/value store.

### Autoplay and failed tracks

Autoplay is on by default. When three or fewer tracks remain, it adds up to
eight related tracks not already queued or recently added: YouTube Music's
related list for YouTube tracks; for a SoundCloud track it first looks for the
same title and artist on YouTube Music and continues from that track's list,
falling back to SoundCloud search. The batch is a mini-feed: at most three
tracks per performer, pools interleaved, and if the current track's list runs
short the related list of the most recent history track by another performer
is mixed in.

If a queued track fails to load, the player holds the queue, looks up the same
title and artist on the other source and swaps the replacement into the failed
position. Two attempts per URL keep a broken link from cycling; after that (or
if nothing turns up) the queue continues. Any user command abandons a pending
replacement.

### Recommendations

A track enters the history after ten seconds of actual playing — skips never
count — and a replay moves it to the front; the last twenty persist in the
key/value store (`history`). The **Recommended** row takes up to five recent
tracks as seeds (one per performer), asks for each seed's related list plus a
`<artist> radio` playlist probe for the first two, interleaves the pools and
caps every artist at two cards, skipping anything heard or queued.

The row rebuilds itself after three new history entries, or after ten minutes
when the history changed at all — not after every song — and the related lists
behind it are cached, so most rebuilds cost no requests. **Refresh** draws a
different set of seeds and shuffles the pools for new cards immediately.

## Palette commands

`plugin.ytmusic.open`, `play-pause`, `next`, `previous`, `volume-up`,
`volume-down`, `mute`, `shuffle`, `loop`, `clear`, `stop` — they work while the
player runs, with or without the block open. **Stop the player** quits mpv and
drops the queue; a fresh player starts on the next play.

## Configuration

| Where            | Key                | For                                                          |
| ---------------- | ------------------ | ------------------------------------------------------------ |
| environment      | `TERN_YT_MPV`      | the mpv binary, path included                                |
| environment      | `TERN_YT_YTDLP`    | the yt-dlp binary, path included                             |
| environment      | `TERN_YT_FFMPEG`   | ffmpeg, for streams yt-dlp cannot hand over directly         |
| environment      | `TERN_YT_MPV_ARGS` | extra mpv arguments, split on whitespace                     |
| `<data>/kv.json` | `mpv_path`         | the same, for a plugin you cannot re-launch with new variables |
| `<data>/kv.json` | `ytdlp_path`       | the same                                                     |
| `<data>/kv.json` | `ffmpeg_path`      | the same                                                     |
| `<data>/kv.json` | `volume`           | the volume a new player starts at                            |
| `<data>/kv.json` | `autoplay`         | similar-track autoplay, managed by the player UI             |
| `<data>/kv.json` | `playlists`        | saved playlists, managed by the player UI                    |
| `<data>/kv.json` | `history`          | listening history, managed by the player UI                  |
| `<data>/kv.json` | `soundcloud_client_id` | SoundCloud's web client id, found and refreshed automatically |

Each tool is looked up in `TERN_YT_*`, then the kv key, then `PATH`, then the
places installers that do not touch `PATH` use — `%ProgramFiles%\MPV Player`,
`%ProgramFiles%\mpv`, `%LOCALAPPDATA%\Programs\mpv`, winget's `Links`
directory, Chocolatey's `bin`, Scoop's `shims`, and the winget package folders
(`yt-dlp.yt-dlp_…`, `yt-dlp.FFmpeg_…`) — and the directories found go on the
player's own `PATH`, so mpv's ytdl hook and yt-dlp run the same binaries.

`<data>` is the plugin's data directory, where the player's files live
(`state.txt`, `queue.txt`, `cmds/`, `mpv.log`, the Windows launcher); the
block prints its path when a tool does not run. `TERN_YT_MPV_ARGS` takes things
like `--ytdl-raw-options=cookies-from-browser=firefox` for age-restricted or
members-only videos. mpv starts with `--no-config`, so a user `mpv.conf` never
changes the player's behaviour.

## How it works

```
block (Luau, host VM) ──poll──▶ state.txt, queue.txt ◀──writes── mpv/bridge.lua (in mpv)
        │                                                              ▲
        └──write──▶ cmds/<one file per command> ──polls───────────────┘
```

- `mpv/bridge.lua` runs inside mpv (mpv's own Lua, not Luau) and is the
  player's half: it consumes command files, applies them with the mpv API and
  writes the state and queue files. `state.txt` ends with `ok=1`, so a read
  that races a write is recognised and skipped instead of being taken for a
  dead or empty player. `queue.txt` is rewritten only when the playlist
  changes and carries a version (`qv`) that `state.txt` echoes, so the block
  reads it only when it changed. A whole playlist is one command
  (`setqueue`, `enqueuemany`), not one file per track, and every command
  file ends with a `.` line so a half-written one is never run; files run
  strictly in order. The bridge reports its protocol (`proto=`); a player
  started by an older version of the plugin gets per-track commands and is
  restarted on the current bridge as soon as it is idle with an empty queue.
  The next entry is prefetched (`--prefetch-playlist`), so track changes
  skip most of the yt-dlp lookup.
- `src/host.luau` is the block; `src/player.luau` owns the player's lifetime,
  the queue, history, recommendations, autoplay, failed-track replacement and
  cover art. Its poll doubles as the plugin's daemon while mpv runs, even with
  no block open.
- `src/net.luau` sits under every request: at most six in flight, one retry
  with backoff for transient failures, and a TTL cache with in-flight
  de-duplication — search results for 10 minutes, related lists and catalog
  pages for 30. Covers that fail are retried after 10 minutes, not never.
- `src/catalog.luau` speaks the undocumented YouTube Music API (following the
  community-maintained
  [ytmusicapi reference](https://ytmusicapi.readthedocs.io/en/stable/reference/search.html));
  `src/soundcloud.luau` searches SoundCloud's own `api-v2` with the client id
  its web app uses, found on soundcloud.com and cached, and falls back to
  yt-dlp's `scsearch:` (one process at a time) if that fails.
- `src/process.luau` runs processes: directly on macOS and Linux, through the
  windowless launcher on Windows.
- `src/sched.luau` keeps the poll loops alive. Tern disables a hook for the
  rest of the session when one call runs past its budget (2 s on the host,
  50 ms in a window) — a sleeping or stalled machine trips that by itself — so
  every beat is scheduled through both `tern.timer` and `tern.sleep`; if one
  hook is disabled, the other keeps the player and the status line updating.
- The window half (`src/window.luau`) adds the palette commands, the status
  segment and the link route for `youtube.com`, `youtu.be` and
  `soundcloud.com` URLs. It reads the same files — a window and its daemon are
  the same machine.

## Known limits

- **YouTube's bot check.** On some networks (VPNs, shared addresses) yt-dlp
  can search but cannot resolve a stream without cookies; the player then
  shows "playback failed; see mpv.log" and mpv.log holds `Sign in to confirm
  you're not a bot`. Pass your browser's cookies:

  ```sh
  TERN_YT_MPV_ARGS="--ytdl-raw-options=cookies-from-browser=firefox"
  ```

  (or `cookies=/path/to/cookies.txt`). Search keeps working without them.
- One player per host. Two blocks show the same player and the same queue.
- With a **remote daemon** the palette commands and the status segment belong
  to the window's own machine; the block on the remote host works as usual.
- The queue lives in mpv: **Stop the player** quits it and the queue is gone.
  A player that exits on its own restarts on the next play with an empty
  queue; the block says why it stopped.
- The YouTube Music and SoundCloud web APIs are undocumented and can change.
  SoundCloud falls back to yt-dlp; YouTube Music has no fallback.
- mpv is started with `--no-config` and `--ytdl-format=bestaudio/best`: audio
  only, no video, no user config.

## Development

```sh
tern plugin types .          # writes tern.d.luau for luau-lsp
luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau src/*.luau
luau-compile --null mpv/bridge.lua   # bridge.lua is plain Lua, for mpv
```

VS Code settings for type checking:

```json
{
	"luau-lsp.platform.type": "standard",
	"luau-lsp.sourcemap.enabled": false,
	"luau-lsp.types.definitionFiles": { "@tern": "tern.d.luau" }
}
```

A linked plugin reloads whenever a file in its directory changes, so keep
build output and screenshots (`tern ctl shot`) outside the checkout.

## Documentation

- [Tern plugin development](https://docs.stencil.so/tern/)
- [Tern API reference](https://docs.stencil.so/tern/reference/api.html)
- [Runtime, budgets and JIT](https://docs.stencil.so/tern/concepts/runtime.html)
- [Tern views guide](https://docs.stencil.so/tern/guides/views.html)
- [mpv manual](https://mpv.io/manual/stable/)
- [yt-dlp documentation](https://github.com/yt-dlp/yt-dlp#readme)
