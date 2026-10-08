# tern-youtube-player

A YouTube Music player for [Tern](https://stencil.so/tern): a native block with
cover art, playback controls, a queue, YouTube Music catalog search for tracks,
artists, playlists and podcasts, related-track autoplay, saved playlists, plus
palette commands, a status-line segment and a route for clicked YouTube links.

Playback runs through `mpv --idle` in the background — no browser, no ads, no
video, nothing to keep on screen — and the block is a view of it: closing the
pane keeps the music playing, reopening finds it where it was.

## Requirements

- Tern (closed beta), desktop. Blocks and processes do not exist on iOS.
- [`mpv`](https://mpv.io) 0.33 or newer.
- [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) — mpv uses it to resolve YouTube
  URLs for playback.

On Windows, the plugin runs console dependencies through the built-in Windows
Script Host and Windows PowerShell with console creation disabled. No additional
launcher package is required.

```sh
winget install mpv yt-dlp          # Windows
brew install mpv yt-dlp            # macOS
sudo apt install mpv yt-dlp        # Debian/Ubuntu (or pipx install yt-dlp)
```

Both are found on `PATH` or in the usual install locations — winget, Chocolatey
and Scoop included — without extra setup; see
[Configuration](#configuration) to point at a copy somewhere else.

## Install

From the repository root, link the local checkout:

```sh
tern plugin link .
```

Then run **YouTube Music: Open player** from the command palette, click a
YouTube link in any pane, or open **New YouTube Player block** directly. A
palette command can also be bound with `tern.bind` or in `settings.json`
keybinds: every command is the action `plugin.ytmusic.<id>`.

## Using it

The Search area has four YouTube Music categories: **Tracks**, **Artists**,
**Playlists** and **Podcasts**. Tracks are filtered to YouTube Music songs;
ordinary YouTube video search results are never mixed into the catalog.

| Key                 | Does                                           |
| ------------------- | ---------------------------------------------- |
| type / paste        | search the selected category, debounced        |
| `↑` `↓`             | pick a visible result                          |
| `enter`             | play a track or open an artist/list/show        |
| double-click track  | add it to the queue                            |
| `tab`               | switch to queue keys                            |

Opening an artist shows its catalog tracks, opening a playlist loads its songs,
and opening a podcast shows its episodes. **Tracks** also has local duration and
artist filters; **Play all** and **Save results** use only visible matches.

**Queue** mode:

| Key            | Does                                        |
| -------------- | ------------------------------------------- |
| `space`        | play / pause                                |
| `←` `→`        | seek ∓10 s                                  |
| `n` `p`        | next / previous track                      |
| `↑` `↓`        | pick a queue row                           |
| `enter`        | jump to the row                            |
| `+` `-`        | volume ∓5                                  |
| `m` `s` `r`    | mute · shuffle · repeat (off → all → one)  |
| `d` `c`        | remove the row · clear the queue           |
| `l`            | open Playlists                              |
| `/`            | focus the search field                     |
| `tab`          | focus search                               |

**Playlists** mode:

| Key            | Does                        |
| -------------- | --------------------------- |
| `↑` `↓`        | pick a saved playlist       |
| `enter`        | play the playlist           |
| `+`            | append it to the queue      |
| `d`            | delete it                   |
| `tab`          | return to the queue         |

Enter a name in the Playlists field, then save the filtered search results or
the current queue. Saving an existing name (case-insensitive) replaces it.
Playlists persist in the plugin's key/value store; the library holds up to 40
playlists with 200 tracks each.

Similar-track autoplay is on by default. When three or fewer tracks remain, it
uses YouTube Music's track-related recommendations and adds up to eight music
results not already queued or recently added. It no longer uses a generic
YouTube text search. Toggle it from the **autoplay on/off** chip.

The public YouTube Music search/recommendation API is undocumented and can
change; the implementation follows the community-maintained
[ytmusicapi search reference](https://ytmusicapi.readthedocs.io/en/stable/reference/search.html).

Every control is also clickable; the icon rows need no focus. The playlist
name, artist filter and search query each accept typing and paste.

Palette commands while the player runs (with or without the block open):
`plugin.ytmusic.open`, `play-pause`, `next`, `previous`, `volume-up`,
`volume-down`, `mute`, `shuffle`, `loop`, `clear`, `stop`.

The queue lives in mpv, not in the pane or in Tern: it survives a plugin
reload, and it is why a track ends and the next one starts even with no window
open. **Stop the player** quits mpv and drops the queue; a fresh player starts
on the next play (or when a block is opened).

## Configuration

| Where               | Key             | For                                        |
| ------------------- | --------------- | ------------------------------------------ |
| environment         | `TERN_YT_MPV`   | the mpv binary, path included              |
| environment         | `TERN_YT_YTDLP` | the yt-dlp binary, path included           |
| environment         | `TERN_YT_FFMPEG` | the ffmpeg binary, for streams yt-dlp cannot hand over directly |
| environment         | `TERN_YT_MPV_ARGS` | extra mpv arguments, split on whitespace |
| `<data>/kv.json`    | `mpv_path`      | the same, for a plugin you cannot re-launch with new variables |
| `<data>/kv.json`    | `ytdlp_path`    | the same                                   |
| `<data>/kv.json`    | `ffmpeg_path`   | the same                                   |
| `<data>/kv.json`    | `volume`        | the volume a new player starts at          |
| `<data>/kv.json`    | `autoplay`     | similar-track autoplay, managed by the player UI |
| `<data>/kv.json`    | `playlists`    | saved playlists, managed by the player UI        |

The plugin does not need the variables: it looks for each tool in
`TERN_YT_*`, then the kv key, then `PATH`, then the places installers that do
not touch `PATH` use — `%ProgramFiles%\MPV Player`, `%ProgramFiles%\mpv`,
`%LOCALAPPDATA%\Programs\mpv`, winget's `Links` directory, Chocolatey's `bin`,
Scoop's `shims`, and the winget package folders (`yt-dlp.yt-dlp_…`,
`yt-dlp.FFmpeg_…`) — and puts the directories it found on the player's own
`PATH`, so mpv's ytdl hook and yt-dlp run the same binaries. A tool installed
after Tern started is found without restarting anything; a tool installed
while a block is open needs a plugin reload (the palette's **Reload plugins**)
or reopening the block.

`<data>` is the plugin's data directory — where the player's files live
(`state.txt`, `queue.txt`, `cmds/`, `mpv.log`); the block prints its path in
the problem card when a tool does not run. `TERN_YT_MPV_ARGS` takes things
like `--ytdl-raw-options=cookies-from-browser=firefox` for age-restricted or
members-only videos that need the browser's cookies. mpv is started with
`--no-config`, so a user `mpv.conf` never changes the player's behaviour;
pass what you need through `TERN_YT_MPV_ARGS`.

## How it works

```
block (Luau, host VM) ──poll──▶ state.txt, queue.txt ◀──writes── mpv/bridge.lua (in mpv)
        │                                                              ▲
        └──write──▶ cmds/<one file per command> ──polls───────────────┘
```

- `mpv/bridge.lua` runs inside mpv (mpv's own Lua, not Luau) and is the
  player's half: it consumes command files, applies them with the mpv API and
  writes the state and queue files. It is why pausing, seeking and volume work
  without a socket or a helper binary.
- The host block polls those files, renders them, and writes commands back; it
  also owns cover art (`i.ytimg.com` thumbnails, fetched and sent as blobs),
  yt-dlp search and the player's lifetime.
- `src/process.luau` keeps Tern's direct process runner on non-Windows hosts.
  On Windows, it uses the built-in hidden Script Host and PowerShell runner,
  then captures dependency output without opening console windows.
- The window half adds the palette commands (they write command files too — a
  window and its daemon are the same machine), the status segment and the
  `youtube.com` / `youtu.be` link route.

## Known limits

- **YouTube's bot check.** On some networks (VPNs, shared addresses, some
  countries) yt-dlp can search but cannot resolve a stream without cookies;
  the player then shows "playback failed; see mpv.log" and mpv.log holds
  `Sign in to confirm you're not a bot`. Pass your browser's cookies through
  mpv:

  ```sh
  TERN_YT_MPV_ARGS="--ytdl-raw-options=cookies-from-browser=firefox"
  ```

  (or `cookies=/path/to/cookies.txt` for an exported file). Search keeps
  working without them.
- One player per host. Two blocks show the same player and the same queue.
- The window half reads the player's files from the window's own machine, so
  with a **remote daemon** the palette commands and the status segment belong
  to the local machine; the block on the remote host works as usual.
- The queue lives in mpv: **Stop the player** quits it and the queue is gone.
  A player that exits on its own (a crash, `kill`) restarts on the next play
  with an empty queue.
- Search results come from `yt-dlp -J ytsearch…`; entries without a duration
  or uploader show as much as they have. A URL opened as an argument shows its
  title once mpv resolves it.
- Playback failures land in `mpv.log` (and as a toast); the block itself only
  knows that a file ended with an error.
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

## Documentation

- [Tern plugin development](https://docs.stencil.so/tern/)
- [Tern API reference](https://docs.stencil.so/tern/reference/api.html)
- [Tern views guide](https://docs.stencil.so/tern/guides/views.html)
- [Tern styles and CSS](https://docs.stencil.so/tern/styles/index.html)
- [mpv manual](https://mpv.io/manual/stable/)
- [yt-dlp documentation](https://github.com/yt-dlp/yt-dlp#readme)
