--!strict
-- YouTube Music: what the two halves share.
--
-- The player is one long-lived `mpv --idle` per machine. `mpv/bridge.lua` runs
-- inside it and keeps three files under the plugin's data directory:
--
--   state.txt  one `key=value` line per field, rewritten by the bridge ~2x/s
--   queue.txt  one `index<TAB>url<TAB>video<TAB>title<TAB>artist` per entry
--   cmds/      one file per command: first line the name, the rest its args
--
-- This module is the only place that knows those paths and how to read and
-- write them, and both halves require it: the block in the host VM and the
-- palette commands in each window. `mpv.log` next to them is mpv's own log, the
-- first place to look when a URL stops resolving.

local ytmusic = {}

local DATA = tern.plugin.data
local SEP = if string.find(DATA, "\\", 1, true) then "\\" else "/"

local CMDS = DATA .. SEP .. "cmds"
local STATE = DATA .. SEP .. "state.txt"
local QUEUE = DATA .. SEP .. "queue.txt"
local LOG = DATA .. SEP .. "mpv.log"

-- How long a state file counts as the player being alive after its last write.
local STALE_S = 6

local DEFAULT_VOLUME = 70
local VOLUME_MAX = 130

export type PlayerState = "idle" | "playing" | "paused" | "starting"
export type Loop = "off" | "all" | "one"

-- One state.txt read: the fields the block and the status line show.
export type Player = {
	beat: number,
	pid: number,
	state: PlayerState,
	pos: number,
	duration: number?,
	volume: number,
	mute: boolean,
	shuffle: boolean,
	loop: Loop,
	index: number,
	count: number,
	seq: number,
	title: string,
	artist: string,
	video: string,
	url: string,
	failed: number?,
	fail_seq: number,
	err: string,
}

-- One line of queue.txt: a playlist entry and the hints the plugin gave it.
export type Flat = {
	index: number,
	url: string,
	video: string,
	title: string,
	artist: string,
}

ytmusic.data_dir = DATA
ytmusic.volume_max = VOLUME_MAX

local function join(...: string): string
	local parts = { ... }
	return table.concat(parts, SEP)
end

local function bridge_path(): string
	return join(tern.plugin.dir, "mpv", "bridge.lua")
end

-- Drops the command directory: called right before mpv starts, so commands
-- written while nothing ran cannot reach the new player out of order.
function ytmusic.wipe_commands(): ()
	pcall(function()
		tern.fs.remove(CMDS)
	end)
	pcall(function()
		tern.fs.mkdir(CMDS)
	end)
end

function ytmusic.ensure_dirs(): ()
	pcall(function()
		tern.fs.mkdir(CMDS)
	end)
end

local function number_of(fields: { [string]: string }, key: string): number?
	local raw = fields[key]
	if raw == nil or raw == "" then
		return nil
	end
	return tonumber(raw)
end

local function flag_of(fields: { [string]: string }, key: string): boolean
	return fields[key] == "1"
end

local function state_of(raw: string?): PlayerState
	if raw == "playing" then
		return "playing"
	elseif raw == "paused" then
		return "paused"
	elseif raw == "starting" then
		return "starting"
	end
	return "idle"
end

local function loop_of(raw: string?): Loop
	if raw == "all" then
		return "all"
	elseif raw == "one" then
		return "one"
	end
	return "off"
end

local function parse_state(text: string): Player?
	local fields: { [string]: string } = {}
	for line in string.gmatch(text, "[^\n]+") do
		local key, value = string.match(line, "^([%w_]+)=(.*)$")
		if key ~= nil and value ~= nil then
			fields[key] = (string.gsub(value, "\r$", ""))
		end
	end
	if fields.v ~= "1" then
		return nil
	end
	return {
		beat = number_of(fields, "beat") or 0,
		pid = number_of(fields, "pid") or 0,
		state = state_of(fields.state),
		pos = number_of(fields, "pos") or 0,
		duration = number_of(fields, "duration"),
		volume = number_of(fields, "volume") or 0,
		mute = flag_of(fields, "mute"),
		shuffle = flag_of(fields, "shuffle"),
		loop = loop_of(fields.loop),
		index = number_of(fields, "index") or -1,
		count = number_of(fields, "count") or 0,
		seq = number_of(fields, "seq") or 0,
		title = fields.title or "",
		artist = fields.artist or "",
		video = fields.video or "",
		url = fields.url or "",
		failed = number_of(fields, "failed"),
		fail_seq = number_of(fields, "fail_seq") or 0,
		err = fields.err or "",
	}
end

-- The last good state, or nil when no player wrote one (or the file is unreadable).
-- The file is a few hundred bytes; the bound keeps the read cheap on the window's
-- UI thread, where every call has a 50 ms budget.
function ytmusic.read(): Player?
	local ok, text = pcall(tern.fs.read, STATE, 8 * 1024)
	if not ok then
		return nil
	end
	return parse_state(text)
end

function ytmusic.fresh(player: Player?): boolean
	return player ~= nil and os.time() - player.beat <= STALE_S
end

function ytmusic.queue(): { Flat }
	local ok, text = pcall(tern.fs.read, QUEUE, 256 * 1024)
	if not ok then
		return {}
	end
	local rows: { Flat } = {}
	for line in string.gmatch(text, "[^\n]+") do
		local index, url, video, title, artist = string.match(line, "^(%-?%d+)\t(.*)\t(.*)\t(.*)\t(.*)$")
		if index ~= nil and url ~= nil and video ~= nil and title ~= nil and artist ~= nil then
			table.insert(rows, {
				index = tonumber(index) or 0,
				url = url,
				video = video,
				title = title,
				artist = artist,
			})
		end
	end
	return rows
end

local cmd_seq = 0
local cmd_token = string.format("%x", math.floor(tern.now() * 7919) % 0xFFFFFF)

-- Replaces every control character with a space: a command is one line per
-- field, so a title with a newline or tab must not add or split fields.
local function one_line(text: string): string
	local clean = string.gsub(text, "[%c]+", " ")
	return (string.gsub(clean, "^%s*(.-)%s*$", "%1"))
end

-- Queues one command for the bridge and returns whether it was written.
-- The name sorts by time within this VM, so commands from one handler arrive
-- in the order they were sent; the token keeps two VMs' files apart.
function ytmusic.send(name: string, ...: string): boolean
	cmd_seq += 1
	local stamp = string.format("%013d", os.time() * 1000 + math.floor(tern.now() % 1000))
	local file = string.format("%s-%04d-%s.cmd", stamp, cmd_seq % 10000, cmd_token)
	local lines: { string } = { name }
	for _, arg in { ... } do
		table.insert(lines, one_line(arg))
	end
	local ok = pcall(function()
		tern.fs.mkdir(CMDS)
		tern.fs.write(CMDS .. SEP .. file, table.concat(lines, "\n") .. "\n")
	end)
	if not ok then
		tern.log.warn("ytmusic: could not write the command", name)
	end
	return ok
end

function ytmusic.clock(seconds: number?): string
	if seconds == nil or seconds < 0 or seconds ~= seconds then
		return "--:--"
	end
	local total = math.floor(seconds)
	local hours = total // 3600
	local minutes = (total // 60) % 60
	local secs = total % 60
	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, minutes, secs)
	end
	return string.format("%d:%02d", minutes, secs)
end

function ytmusic.cut(text: string, limit: number): string
	if #text <= limit then
		return text
	end
	return string.sub(text, 1, math.max(1, limit - 1)) .. "…"
end

function ytmusic.thumb(video: string): string
	return "https://i.ytimg.com/vi/" .. video .. "/mqdefault.jpg"
end

-- The video id in a YouTube URL, when it is one (watch, short, live, embed).
function ytmusic.youtube_id(url: string): string?
	local id = string.match(url, "[?&]v=([%w%-_]+)")
	if id ~= nil then
		return id
	end
	id = string.match(url, "youtu%.be/([%w%-_]+)")
	if id ~= nil then
		return id
	end
	id = string.match(url, "/shorts/([%w%-_]+)")
		or string.match(url, "/live/([%w%-_]+)")
		or string.match(url, "/embed/([%w%-_]+)")
	return id
end

-- Where a URL plays: "youtube", "soundcloud", or "" for anything the player
-- does not search itself (yt-dlp may still play it as a pasted link).
function ytmusic.source_of(url: string): string
	local host = string.match(url, "^https?://([^/]+)")
	if host == nil then
		return ""
	end
	host = string.lower(host)
	if host == "youtu.be"
		or string.find(host, "youtube.com", 1, true) ~= nil
		or string.find(host, "youtube-nocookie.com", 1, true) ~= nil
	then
		return "youtube"
	end
	if host == "soundcloud.com"
		or host == "snd.sc"
		or string.sub(host, -14) == ".soundcloud.com"
	then
		return "soundcloud"
	end
	return ""
end

function ytmusic.is_playable_url(url: string): boolean
	return ytmusic.source_of(url) ~= ""
end

local function char_width(code: number): number
	if code < 0x80 then
		return 1
	elseif code < 0x800 then
		return 2
	elseif code < 0x10000 then
		return 3
	end
	return 4
end

-- UTF-16 code units before byte offset `bytes`: what an `input` node's `cursor`
-- prop counts, unlike a Luau byte index.
function ytmusic.units_for_bytes(text: string, bytes: number): number
	local units = 0
	local index = 1
	local stop = math.min(bytes, #text)
	while index <= stop do
		local code = utf8.codepoint(text, index)
		units += if code > 0xFFFF then 2 else 1
		index += char_width(code)
	end
	return units
end

-- Byte offsets of the character before and after `index`, for editing a query.
function ytmusic.prev_at(text: string, index: number): number
	local boundary = 0
	local position = 1
	while position <= #text do
		local next_boundary = position + char_width(utf8.codepoint(text, position)) - 1
		if next_boundary >= index then
			return boundary
		end
		boundary = next_boundary
		position = next_boundary + 1
	end
	return boundary
end

function ytmusic.next_at(text: string, index: number): number
	if index >= #text then
		return #text
	end
	return index + char_width(utf8.codepoint(text, index + 1))
end

local function stored(key: string): any
	local ok, value = pcall(tern.kv.get, key)
	if ok then
		return value
	end
	return nil
end

local function exists(path: string): boolean
	local ok, present = pcall(tern.fs.exists, path)
	return ok and present == true
end

local function path_separator(): string
	return if tern.runtime.os == "windows" then ";" else ":"
end

local function file_names(stem: string): { string }
	if tern.runtime.os == "windows" then
		return { stem .. ".exe", stem .. ".com" }
	end
	return { stem }
end

-- Every directory `PATH` names, so a tool installed the ordinary way is found
-- even when this VM's environment is older than the install.
local function path_dirs(): { string }
	local raw = tern.getenv("PATH")
	local dirs: { string } = {}
	if raw == nil or raw == "" then
		return dirs
	end
	for dir in string.gmatch(raw, "[^" .. path_separator() .. "]+") do
		table.insert(dirs, dir)
	end
	return dirs
end

-- Where a Windows or Unix installer puts these tools when it does not touch
-- PATH: winget's links and packages, Chocolatey, Scoop, the program
-- directories. `tern.fs` does not expand `~`, so everything comes from the
-- environment.
local function known_dirs(): { string }
	local dirs: { string } = {}
	local function add(base: string?, ...: string)
		if base == nil or base == "" then
			return
		end
		local parts = { ... }
		table.insert(dirs, base .. SEP .. table.concat(parts, SEP))
	end
	local local_appdata = tern.getenv("LOCALAPPDATA")
	local program_files = tern.getenv("ProgramFiles")
	local program_files_x86 = tern.getenv("ProgramFiles(x86)")
	local program_data = tern.getenv("ProgramData")
	local profile = tern.getenv("USERPROFILE")
	local home = tern.getenv("HOME")
	if tern.runtime.os == "windows" then
		add(program_files, "MPV Player")
		add(program_files, "mpv")
		add(program_files_x86, "mpv")
		add(local_appdata, "Programs", "mpv")
		add(local_appdata, "Programs", "MPV Player")
		add(local_appdata, "Microsoft", "WinGet", "Links")
		add(program_data, "chocolatey", "bin")
		add(profile, "scoop", "shims")
		add(profile, "scoop", "apps", "mpv", "current")
		add(profile, "scoop", "apps", "yt-dlp", "current")
		add(profile, "scoop", "apps", "ffmpeg", "current", "bin")
	else
		add("/usr/local/bin")
		add("/usr/bin")
		add("/bin")
		add("/snap/bin")
		add("/opt/homebrew/bin")
		add("/usr/local/opt/mpv/bin")
		add(home, ".local", "bin")
	end
	return dirs
end

-- `dir` itself, then `dir/bin`, then a couple of levels below: how archive and
-- package layouts put their binaries.
local function scan(dir: string, names: { string }, depth: number): string?
	for _, name in names do
		if exists(dir .. SEP .. name) then
			return dir .. SEP .. name
		end
		if exists(dir .. SEP .. "bin" .. SEP .. name) then
			return dir .. SEP .. "bin" .. SEP .. name
		end
	end
	if depth <= 0 then
		return nil
	end
	local ok, entries = pcall(tern.fs.list, dir)
	if not ok then
		return nil
	end
	for _, entry in entries do
		local found = scan(dir .. SEP .. entry, names, depth - 1)
		if found ~= nil then
			return found
		end
	end
	return nil
end

-- winget's portable packages live under one directory, each in its own folder
-- (`yt-dlp.yt-dlp_…`, `yt-dlp.FFmpeg_…`); only the folders that look like the
-- tool are scanned, so this stays a handful of directory reads.
local function scan_packages(names: { string }, patterns: { string }): string?
	local local_appdata = tern.getenv("LOCALAPPDATA")
	if tern.runtime.os ~= "windows" or local_appdata == nil then
		return nil
	end
	local root = local_appdata .. SEP .. "Microsoft" .. SEP .. "WinGet" .. SEP .. "Packages"
	local ok, entries = pcall(tern.fs.list, root)
	if not ok then
		return nil
	end
	for _, entry in entries do
		local lower = string.lower(entry)
		for _, pattern in patterns do
			if string.find(lower, pattern, 1, true) ~= nil then
				local found = scan(root .. SEP .. entry, names, 2)
				if found ~= nil then
					return found
				end
				break
			end
		end
	end
	return nil
end

local resolved: { [string]: string } = {}

-- The tool's absolute path, or its bare name when nothing was found (the
-- runtime's own PATH lookup then has the last word). Order: `TERN_YT_*`, the
-- `*_path` key in kv, PATH, the usual install directories, winget's packages.
local function resolve(stem: string, env: string, key: string, patterns: { string }): string
	local cached = resolved[stem]
	if cached ~= nil then
		return cached
	end
	local from_env = tern.getenv(env)
	if from_env ~= nil and from_env ~= "" then
		resolved[stem] = from_env
		return from_env
	end
	local from_kv = stored(key)
	if type(from_kv) == "string" and from_kv ~= "" then
		resolved[stem] = from_kv
		return from_kv
	end
	local names = file_names(stem)
	for _, dir in path_dirs() do
		for _, name in names do
			if exists(dir .. SEP .. name) then
				resolved[stem] = dir .. SEP .. name
				return resolved[stem]
			end
		end
	end
	for _, dir in known_dirs() do
		for _, name in names do
			if exists(dir .. SEP .. name) then
				resolved[stem] = dir .. SEP .. name
				return resolved[stem]
			end
		end
	end
	local from_packages = scan_packages(names, patterns)
	if from_packages ~= nil then
		resolved[stem] = from_packages
		return from_packages
	end
	resolved[stem] = stem
	return stem
end

-- The mpv binary: `TERN_YT_MPV`, then `mpv_path` in kv, then PATH, the usual
-- install directories and winget's packages.
function ytmusic.mpv_bin(): string
	return resolve("mpv", "TERN_YT_MPV", "mpv_path", { "mpv" })
end

-- The yt-dlp binary: `TERN_YT_YTDLP`, then `ytdlp_path`, then the same search.
function ytmusic.ytdlp_bin(): string
	return resolve("yt-dlp", "TERN_YT_YTDLP", "ytdlp_path", { "yt-dlp" })
end

-- ffmpeg, when it can be found: yt-dlp uses it for some streams, and it is not
-- always on PATH (winget ships it as `yt-dlp.FFmpeg`).
local function ffmpeg_bin(): string?
	local path = resolve("ffmpeg", "TERN_YT_FFMPEG", "ffmpeg_path", { "ffmpeg" })
	if path == "ffmpeg" then
		return nil
	end
	return path
end

local function stored_volume(): number
	local value = stored("volume")
	if type(value) == "number" and value >= 0 then
		return math.min(VOLUME_MAX, math.floor(value + 0.5))
	end
	return DEFAULT_VOLUME
end

function ytmusic.remember_volume(value: number): ()
	pcall(tern.kv.set, "volume", math.clamp(math.floor(value + 0.5), 0, VOLUME_MAX))
end

-- The directory part of a path, or `nil` for a bare program name.
local function dirname(path: string): string?
	local index = #path
	while index > 0 do
		local char = string.sub(path, index, index)
		if char == "/" or char == "\\" then
			return string.sub(path, 1, index - 1)
		end
		index -= 1
	end
	return nil
end

-- The environment the mpv process needs: the data directory under
-- TERN_YT_DATA for `mpv/bridge.lua`, and the directories of the tools we found
-- on PATH, because mpv's own ytdl hook and yt-dlp itself look programs up by
-- name and must run the same binaries the plugin resolved.
function ytmusic.tool_env(): { [string]: string }
	local extra: { [string]: string } = { TERN_YT_DATA = ytmusic.data_dir }
	local dirs: { string } = {}
	local seen: { [string]: boolean } = {}
	local function add(path: string?)
		local dir = if path == nil then nil else dirname(path)
		if dir == nil or dir == "" or seen[dir] == true then
			return
		end
		seen[dir] = true
		table.insert(dirs, dir)
	end
	add(ytmusic.ytdlp_bin())
	add(ytmusic.mpv_bin())
	add(ffmpeg_bin())
	if #dirs == 0 then
		return extra
	end
	local separator = path_separator()
	local path = tern.getenv("PATH")
	local prefix = table.concat(dirs, separator)
	if path == nil or path == "" then
		extra.PATH = prefix
	else
		extra.PATH = prefix .. separator .. path
	end
	return extra
end

-- Extra mpv arguments from `TERN_YT_MPV_ARGS`, split on whitespace; for things
-- like `--ytdl-raw-options=cookies-from-browser=firefox` on a strict network.
local function extra_args(): { string }
	local raw = tern.getenv("TERN_YT_MPV_ARGS")
	local args: { string } = {}
	if raw == nil then
		return args
	end
	for word in string.gmatch(raw, "%S+") do
		table.insert(args, word)
	end
	return args
end

-- The one mpv invocation: audio only, no window, no user config (so a broken
-- mpv.conf cannot take the plugin down), our bridge script, and a log.
function ytmusic.mpv_argv(): { string }
	local argv: { string } = {
		ytmusic.mpv_bin(),
		"--no-config",
		"--idle=yes",
		"--no-video",
		"--audio-display=no",
		"--force-window=no",
		"--no-terminal",
		"--ytdl=yes",
		"--ytdl-format=bestaudio/best",
		"--volume=" .. tostring(stored_volume()),
		"--script=" .. bridge_path(),
		"--log-file=" .. LOG,
	}
	for _, arg in extra_args() do
		table.insert(argv, arg)
	end
	return argv
end

return ytmusic
