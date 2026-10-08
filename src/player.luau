--!strict
-- YouTube Music: the player, as the host sees it.
--
-- One mpv per host, started when something first wants to play, kept alive by
-- the block and outliving it on purpose. This module owns everything between
-- the plugin and that process: the tools it needs, the files `mpv/bridge.lua`
-- writes, the commands queued for it, music-catalog search and cover art. The block
-- (`src/host.luau`) owns only what is on screen.

local process = require("./process")
local yt = require("./ytmusic")
local catalog = require("./catalog")

local TOOL_TIMEOUT_MS = 5000
local SPAWN_COOLDOWN_MS = 3000
local PLAYLIST_LIMIT = 40
local PLAYLIST_TRACK_LIMIT = 200
local AUTOPLAY_REMAINING = 3
local AUTOPLAY_ADD_LIMIT = 8
local AUTOPLAY_SEEN_LIMIT = 500
local PLAYLISTS_KEY = "playlists"
local AUTOPLAY_KEY = "autoplay"
local ART_MAX = 8

export type Track = {
	url: string,
	video: string,
	title: string,
	artist: string,
	duration: number?,
}
export type SearchCategory = catalog.Category
export type SearchItem = catalog.Item
export type Playlist = {
	name: string,
	tracks: { Track },
}

type Pending = { name: string, args: { string } }


local player = {}

local current: yt.Player? = nil
local changed: (() -> ())? = nil
local queue: { yt.Flat } = {}
local running = false
local spawned_at = -math.huge
local tool_problem: string? = nil
local tools_checked = false
local pending: { Pending } = {}
local art: { key: string?, bytes: string?, mime: string?, loading: string? } = {}
local art_cache: { [string]: { bytes: string, mime: string } } = {}
local art_order: { string } = {}
local preferences_loaded = false
local preferences_error: string? = nil
local autoplay_enabled = true
local autoplay_message = ""
local autoplay_generation = 0
local autoplay_seed: string? = nil
local autoplay_searching = false
local autoplay_seen: { [string]: boolean } = {}
local autoplay_seen_order: { string } = {}
local spawned_pid: number? = nil
local exited_pid: number? = nil
local spawn_generation = 0

local function invalidate_autoplay(): ()
	autoplay_generation += 1
	autoplay_searching = false
	autoplay_seed = nil
	autoplay_message = ""
end

local playlists: { Playlist } = {}
local tick_autoplay: (() -> ())? = nil

-- Called when something the views show changed outside a poll: the player
-- starting or exiting, a tool check failing, a cover arriving.
function player.watch(fn: () -> ()): ()
	changed = fn
end

local function notify(): ()
	if changed ~= nil then
		changed()
	end
end
local function track_from(value: any): Track?
	if type(value) ~= "table"
		or type(value.url) ~= "string"
		or type(value.video) ~= "string"
		or type(value.title) ~= "string"
		or type(value.artist) ~= "string"
	then
		return nil
	end
	return {
		url = value.url,
		video = value.video,
		title = value.title,
		artist = value.artist,
		duration = if type(value.duration) == "number" then value.duration else nil,
	}
end

local function load_preferences(): ()
	if preferences_loaded then
		return
	end
	preferences_loaded = true
	local auto_ok, saved_autoplay = pcall(tern.kv.get, AUTOPLAY_KEY)
	if auto_ok and type(saved_autoplay) == "boolean" then
		autoplay_enabled = saved_autoplay
	elseif not auto_ok then
		preferences_error = tostring(saved_autoplay)
	end
	local list_ok, saved_playlists = pcall(tern.kv.get, PLAYLISTS_KEY)
	if not list_ok then
		preferences_error = tostring(saved_playlists)
		return
	end
	if type(saved_playlists) ~= "table" then
		return
	end
	for _, saved in saved_playlists do
		if type(saved) == "table" and type(saved.name) == "string" and type(saved.tracks) == "table" then
			local tracks: { Track } = {}
			for _, value in saved.tracks do
				local track = track_from(value)
				if track ~= nil then
					table.insert(tracks, track)
				end
			end
			if #tracks > 0 and #playlists < PLAYLIST_LIMIT then
				table.insert(playlists, { name = saved.name, tracks = tracks })
			end
		end
	end
end

function player.preferences_problem(): string?
	load_preferences()
	return preferences_error
end

local function copy_tracks(tracks: { Track }): { Track }
	local copied: { Track } = {}
	for _, track in tracks do
		table.insert(copied, {
			url = track.url,
			video = track.video,
			title = track.title,
			artist = track.artist,
			duration = track.duration,
		})
	end
	return copied
end

function player.autoplay(): boolean
	load_preferences()
	return autoplay_enabled
end

function player.autoplay_message(): string
	return autoplay_message
end

function player.set_autoplay(enabled: boolean): (boolean, string?)
	load_preferences()
	if preferences_error ~= nil then
		return false, preferences_error
	end
	local ok, failure = pcall(tern.kv.set, AUTOPLAY_KEY, enabled)
	if not ok then
		return false, tostring(failure)
	end
	autoplay_enabled = enabled
	invalidate_autoplay()
	autoplay_seed = nil
	autoplay_message = if enabled then "Autoplay is on" else "Autoplay is off"
	notify()
	return true, nil
end

function player.playlists(): { Playlist }
	load_preferences()
	return playlists
end

function player.save_playlist(name: string, tracks: { Track }): (boolean, string?)
	load_preferences()
	if preferences_error ~= nil then
		return false, preferences_error
	end
	if name == "" then
		return false, "Enter a playlist name first"
	end
	if #tracks == 0 then
		return false, "There are no tracks to save"
	end
	if #tracks > PLAYLIST_TRACK_LIMIT then
		return false, string.format("A playlist can contain at most %d tracks", PLAYLIST_TRACK_LIMIT)
	end
	local replacement = { name = name, tracks = copy_tracks(tracks) }
	local next_playlists: { Playlist } = {}
	local replaced = false
	for _, playlist in playlists do
		if string.lower(playlist.name) == string.lower(name) then
			table.insert(next_playlists, replacement)
			replaced = true
		else
			table.insert(next_playlists, playlist)
		end
	end
	if not replaced then
		if #playlists >= PLAYLIST_LIMIT then
			return false, string.format("The library is limited to %d playlists", PLAYLIST_LIMIT)
		end
		table.insert(next_playlists, replacement)
	end
	local ok, failure = pcall(tern.kv.set, PLAYLISTS_KEY, next_playlists)
	if not ok then
		return false, tostring(failure)
	end
	playlists = next_playlists
	notify()
	return true, nil
end

function player.delete_playlist(index: number): (boolean, string?)
	load_preferences()
	if preferences_error ~= nil then
		return false, preferences_error
	end
	if index < 1 or index > #playlists then
		return false, "Select a playlist first"
	end
	local next_playlists: { Playlist } = {}
	for position, playlist in playlists do
		if position ~= index then
			table.insert(next_playlists, playlist)
		end
	end
	local ok, failure = pcall(tern.kv.set, PLAYLISTS_KEY, next_playlists)
	if not ok then
		return false, tostring(failure)
	end
	playlists = next_playlists
	notify()
	return true, nil
end
local function first_line(text: string): string
	local line = string.match(text, "[^\r\n]+")
	return yt.cut(line or text, 120)
end

local function tool_missing(name: string, detail: string): string
	return string.format(
		"%s did not run: %s. Install it, or point TERN_YT_MPV / TERN_YT_YTDLP (or the mpv_path / ytdlp_path keys of the plugin's kv.json) at it.",
		name,
		yt.cut(first_line(detail), 140)
	)
end

function player.problem(): string?
	return tool_problem
end

function player.is_running(): boolean
	return running
end

-- The last fresh state, or nil when no player wrote one.
function player.state(): yt.Player?
	return current
end

function player.queue(): { yt.Flat }
	return queue
end

function player.art(): { key: string?, bytes: string?, mime: string? }
	return art
end

-- Tools ------------------------------------------------------------------

function player.check_tools(): ()
	if tools_checked then
		return
	end
	tools_checked = true
	local mpv = yt.mpv_bin()
	local started, failure = pcall(function(): string?
		process.run({ mpv, "--version" }, { timeout_ms = TOOL_TIMEOUT_MS }, function(result: ProcessResult)
			if result.status ~= 0 then
				tool_problem = tool_missing(mpv, first_line(result.stderr))
				notify()
			end
		end)
		return nil
	end)
	if not started then
		tool_problem = tool_missing(mpv, tostring(failure))
		notify()
		return
	end
	local ytdlp = yt.ytdlp_bin()
	local started_ytdlp, failure_ytdlp = pcall(function(): string?
		process.run({ ytdlp, "--version" }, { timeout_ms = TOOL_TIMEOUT_MS }, function(result: ProcessResult)
			if result.status ~= 0 then
				tool_problem = tool_missing(ytdlp, first_line(result.stderr))
				notify()
			end
		end)
		return nil
	end)
	if not started_ytdlp then
		tool_problem = tool_missing(ytdlp, tostring(failure_ytdlp))
		notify()
	end
end

-- The process ------------------------------------------------------------

local function flush_pending(): ()
	if #pending == 0 then
		return
	end
	local queued = pending
	pending = {}
	for _, command in queued do
		yt.send(command.name, table.unpack(command.args))
	end
end

local function spawn(): ()
	if tern.now() - spawned_at < SPAWN_COOLDOWN_MS then
		return
	end
	spawned_at = tern.now()
	spawn_generation += 1
	local generation = spawn_generation
	yt.ensure_dirs()
	yt.wipe_commands()
	spawned_pid = nil
	local started, failure = pcall(function(): string?
		process.run(yt.mpv_argv(), { cwd = yt.data_dir, env = yt.tool_env() }, function(result: ProcessResult)
			if generation ~= spawn_generation then
				return
			end
			local last = yt.read()
			exited_pid = spawned_pid or if last == nil then nil else last.pid
			spawned_pid = nil
			running = false
			current = nil
			queue = {}
			if result.status ~= 0 then
				tool_problem = string.format(
					"mpv exited with status %d; see mpv.log in the plugin's data directory",
					result.status
				)
			end
			notify()
		end)
		return nil
	end)
	if not started then
		spawned_pid = nil
		tool_problem = tool_missing(yt.mpv_bin(), tostring(failure))
		running = false
		notify()
		return
	end
	running = true
	current = nil
	notify()
end

function player.ensure(): ()
	player.check_tools()
	if tool_problem ~= nil then
		return
	end
	-- Consult the file, not the in-memory state: after a plugin reload the
	-- memory is empty while the player keeps running, and spawning here would
	-- leave two players writing the same files.
	local latest = yt.read()
	if yt.fresh(latest) and (exited_pid == nil or latest.pid ~= exited_pid) then
		if exited_pid ~= nil then
			exited_pid = nil
		end
		current = latest
		return
	end
	if exited_pid ~= nil and latest ~= nil and latest.pid == exited_pid then
		current = nil
	end
	spawn()
end

-- Sends a command now, or remembers it for the moment a fresh player appears.
local function request(name: string, invalidate: boolean, ...: string): ()
	if invalidate then
		invalidate_autoplay()
	end
	if yt.fresh(current) then
		yt.send(name, ...)
		return
	end
	local args: { string } = { ... }
	table.insert(pending, { name = name, args = args })
	player.ensure()
end

function player.request(name: string, ...: string): ()
	request(
		name,
		name == "play" or name == "clear" or name == "jump" or name == "remove"
			or name == "enqueue" or name == "next" or name == "prev",
		...
	)
end

-- Reads the files the bridge wrote. Returns the fresh state, if any.
function player.poll(): yt.Player?
	local latest = yt.read()
	if yt.fresh(latest) and (exited_pid == nil or latest.pid ~= exited_pid) then
		if exited_pid ~= nil then
			exited_pid = nil
		end
		current = latest
		if running then
			spawned_pid = latest.pid
		end
		flush_pending()
	else
		current = nil
		if #pending > 0 then
			-- A command is waiting with no player to run it: start one.
			player.ensure()
		end
	end
	queue = if current == nil then {} else yt.queue()
	if tick_autoplay ~= nil then
		tick_autoplay()
	end
	return current
end

-- Search -----------------------------------------------------------------

-- YouTube Music catalog -------------------------------------------------

local function to_track(item: SearchItem): Track
	return {
		url = item.url,
		video = item.video,
		title = item.title,
		artist = item.artist,
		duration = item.duration,
	}
end

function player.search(query: string, category: SearchCategory, done: (items: { SearchItem }, err: string?) -> ()): ()
	catalog.search(query, category, done)
end

function player.open_search_result(item: SearchItem, done: (tracks: { Track }, err: string?) -> ()): ()
	if item.browse_id == "" then
		done({}, "This result cannot be opened")
		return
	end
	catalog.browse(item.browse_id, item.kind, function(items: { SearchItem }, err: string?)
		if err ~= nil then
			done({}, err)
			return
		end
		local tracks: { Track } = {}
		for _, result in items do
			if result.kind == "track" then
				table.insert(tracks, to_track(result))
			end
		end
		done(tracks, nil)
	end)
end

function player.related(video: string, done: (tracks: { Track }, err: string?) -> ()): ()
	catalog.related(video, function(items: { SearchItem }, err: string?)
		if err ~= nil then
			done({}, err)
			return
		end
		local tracks: { Track } = {}
		for _, result in items do
			if result.kind == "track" then
				table.insert(tracks, to_track(result))
			end
		end
		done(tracks, nil)
	end)
end

local function remember_autoplay(video: string): ()
	if video == "" or autoplay_seen[video] == true then
		return
	end
	autoplay_seen[video] = true
	table.insert(autoplay_seen_order, video)
	while #autoplay_seen_order > AUTOPLAY_SEEN_LIMIT do
		local oldest = table.remove(autoplay_seen_order, 1)
		if oldest ~= nil then
			autoplay_seen[oldest] = nil
		end
	end
end

tick_autoplay = function(): ()
	load_preferences()
	local state = current
	if not autoplay_enabled
		or autoplay_searching
		or state == nil
		or state.state ~= "playing"
		or state.video == ""
		or state.index < 0
		or state.count == 0
	then
		return
	end
	local remaining = state.count - state.index - 1
	if remaining > AUTOPLAY_REMAINING or autoplay_seed == state.video then
		return
	end

	autoplay_seed = state.video
	autoplay_searching = true
	local generation = autoplay_generation
	local seed_video = state.video
	local seed_pid = state.pid
	local seed_queue: { yt.Flat } = {}
	for _, row in queue do
		table.insert(seed_queue, row)
	end
	local seed = queue[state.index + 1]
	local title = if state.title ~= "" then state.title else if seed == nil then "" else seed.title
	autoplay_message = "Finding related tracks to " .. yt.cut(title, 36)
	notify()

	player.related(seed_video, function(tracks: { Track }, err: string?)
		if generation ~= autoplay_generation then
			return
		end
		local latest_state = current
		local context_changed = latest_state == nil
			or latest_state.pid ~= seed_pid
			or #queue ~= #seed_queue
		if not context_changed then
			for index, row in queue do
				local original = seed_queue[index]
				if original == nil
					or row.index ~= original.index
					or row.url ~= original.url
					or row.video ~= original.video
					or row.title ~= original.title
					or row.artist ~= original.artist
				then
					context_changed = true
					break
				end
			end
		end
		if context_changed then
			invalidate_autoplay()
			return
		end
		autoplay_searching = false
		if err ~= nil then
			autoplay_message = "Related-track lookup failed: " .. first_line(err)
			notify()
			return
		end

		local known: { [string]: boolean } = {}
		for _, row in queue do
			if row.video ~= "" then
				known[row.video] = true
			end
		end
		local added = 0
		for _, track in tracks do
			local seen = autoplay_seen[track.video] == true
			if track.video ~= "" and known[track.video] ~= true and not seen and added < AUTOPLAY_ADD_LIMIT then
				request("enqueue", false, track.url, track.video, track.title, track.artist)
				known[track.video] = true
				added += 1
				remember_autoplay(track.video)
			end
		end
		if added > 0 then
			autoplay_message = string.format("Added %d related tracks", added)
		else
			autoplay_message = "No new related tracks found"
		end
		remember_autoplay(seed_video)
		notify()
	end)
end

-- Cover art --------------------------------------------------------------

local function mime_of(bytes: string, header: string?): string
	if header ~= nil and string.find(header, "^image/") then
		return (string.match(header, "^[^;%s]+") :: string)
	end
	if string.sub(bytes, 1, 2) == "\255\216" then
		return "image/jpeg"
	end
	if string.sub(bytes, 1, 4) == "RIFF" and string.sub(bytes, 9, 12) == "WEBP" then
		return "image/webp"
	end
	return "image/jpeg"
end

-- Fetches the thumbnail of `video` once and calls `arrived` when the module's
-- current art changed, so the blocks can re-send it as a blob.
function player.load_cover(video: string, arrived: () -> ()): ()
	local cached = art_cache[video]
	if cached ~= nil then
		if cached.bytes == "" then
			-- A thumbnail that failed before: do not ask for it every poll.
			art.key = video
			return
		end
		if art.key ~= video then
			art = { key = video, bytes = cached.bytes, mime = cached.mime }
			arrived()
		end
		return
	end
	if art.key == video or art.loading == video then
		return
	end
	art.key = video
	art.loading = video
	tern.fetch(yt.thumb(video), { timeout_ms = 15000 }, function(response: FetchResult, _cx)
		if art.loading ~= video then
			return
		end
		art.loading = nil
		if response.error ~= nil or response.status ~= 200 or response.body == "" then
			art_cache[video] = { bytes = "", mime = "" }
			return
		end
		local mime = mime_of(response.body, response.headers["content-type"])
		art_cache[video] = { bytes = response.body, mime = mime }
		table.insert(art_order, video)
		while #art_order > ART_MAX do
			local evicted = table.remove(art_order, 1)
			if evicted ~= nil then
				art_cache[evicted] = nil
			end
		end
		art = { key = video, bytes = response.body, mime = mime }
		arrived()
	end)
end

return player
