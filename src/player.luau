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
local soundcloud = require("./soundcloud")

local TOOL_TIMEOUT_MS = 5000
local SPAWN_COOLDOWN_MS = 3000
local PLAYLIST_LIMIT = 40
local PLAYLIST_TRACK_LIMIT = 200
local AUTOPLAY_REMAINING = 3
local AUTOPLAY_ADD_LIMIT = 8
local AUTOPLAY_SEEN_LIMIT = 500
local MERGE_TOLERANCE_S = 5
local RELATED_TOLERANCE_S = 20
local FALLBACK_ATTEMPT_LIMIT = 2
local FALLBACK_SEEN_LIMIT = 200
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

-- Artwork URLs reported by SoundCloud search, so the current track's cover
-- needs no extra round trip; keyed by the track URL.
local art_hints: { [string]: string } = {}
local art_hint_order: { string } = {}
local ART_HINT_LIMIT = 64

-- The failed-entry replacement: generation invalidates an in-flight search
-- when another failure takes over, `last_seq` (a counter the bridge raises
-- per captured failure) turns its persistent `failed=` field into one
-- action per failure, even when the field itself never changed.
local fallback_generation = 0
local fallback_last_seq: number? = nil
local fallback_message = ""
local fallback_searching = false
local fallback_attempts: { [string]: number } = {}
local fallback_attempt_order: { string } = {}
local tick_fallback: (() -> ())? = nil

-- Whether the bridge should hold the queue after a failure: true while this
-- module's poll loop runs (it is then able to supply a replacement).
local hold_desired = false
local hold_sent = false
local hold_pid: number? = nil
local sync_hold: (state: yt.Player?) -> ()

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
		sync_hold(current)
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
	if tick_fallback ~= nil then
		tick_fallback()
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

local function remember_art(url: string, art_url: string): ()
	if url == "" or art_url == "" or art_hints[url] ~= nil then
		return
	end
	art_hints[url] = art_url
	table.insert(art_hint_order, url)
	while #art_hint_order > ART_HINT_LIMIT do
		local oldest = table.remove(art_hint_order, 1)
		if oldest ~= nil then
			art_hints[oldest] = nil
		end
	end
end

local function normalized(text: string): string
	local lowered = string.lower(text)
	local stripped = string.gsub(lowered, "[%p%c]", " ")
	local collapsed = string.gsub(stripped, "%s+", " ")
	return (string.gsub(collapsed, "^%s*(.-)%s*$", "%1"))
end

-- The same track in two catalogs: equal normalized titles with agreeing
-- durations, or with either duration unknown. Artists are not compared — the
-- two sources format them differently (uploader vs. catalog artist), and a
-- same-title same-length collision between different songs is rarer than a
-- missed duplicate.
local function same_track(left: SearchItem, right: SearchItem): boolean
	local key = normalized(left.title)
	if key == "" or key ~= normalized(right.title) then
		return false
	end
	if left.duration ~= nil and right.duration ~= nil then
		return math.abs((left.duration :: number) - (right.duration :: number)) <= MERGE_TOLERANCE_S
	end
	return true
end

-- YouTube Music results first (their related-track API drives autoplay),
-- SoundCloud filling the gaps.
local function merge_results(youtube: { SearchItem }, others: { SearchItem }): { SearchItem }
	local merged: { SearchItem } = {}
	local function add(item: SearchItem)
		for _, taken in merged do
			if same_track(taken, item) then
				return
			end
		end
		table.insert(merged, item)
	end
	for _, item in youtube do
		add(item)
	end
	for _, item in others do
		add(item)
	end
	return merged
end

-- One search across both catalogs. The callback fires once per source that
-- answers (YouTube Music is usually first), so the block shows its results
-- while SoundCloud is still resolving; the merged list replaces it in place.
function player.search(query: string, category: SearchCategory, done: (items: { SearchItem }, err: string?) -> ()): ()
	if category ~= "tracks" then
		catalog.search(query, category, done)
		return
	end
	local youtube: { SearchItem } = {}
	local others: { SearchItem } = {}
	local youtube_err: string? = nil
	local others_err: string? = nil
	local youtube_done = false
	local others_done = false
	local function deliver(): ()
		local merged = merge_results(youtube, others)
		if #merged == 0 and youtube_done and others_done then
			done({}, if youtube_err ~= nil then youtube_err else others_err)
			return
		end
		done(merged, nil)
	end
	catalog.search(query, "tracks", function(items: { SearchItem }, err: string?)
		youtube = items
		youtube_err = err
		youtube_done = true
		deliver()
	end)
	soundcloud.search(query, function(items: { SearchItem }, err: string?)
		for _, item in items do
			if item.art ~= nil then
				remember_art(item.url, item.art :: string)
			end
		end
		others = items
		others_err = err
		others_done = true
		deliver()
	end)
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

local function tracks_of(items: { SearchItem }): { Track }
	local tracks: { Track } = {}
	for _, result in items do
		if result.kind == "track" and result.url ~= "" then
			table.insert(tracks, to_track(result))
		end
	end
	return tracks
end

local function remember_autoplay(url: string): ()
	if url == "" or autoplay_seen[url] == true then
		return
	end
	autoplay_seen[url] = true
	table.insert(autoplay_seen_order, url)
	while #autoplay_seen_order > AUTOPLAY_SEEN_LIMIT do
		local oldest = table.remove(autoplay_seen_order, 1)
		if oldest ~= nil then
			autoplay_seen[oldest] = nil
		end
	end
end

-- Recommendations for whatever is playing. A YouTube track has the catalog's
-- related list directly; a SoundCloud track first looks for its YouTube twin
-- (that related list is far better) and, when there is none, adds SoundCloud
-- results for the same title and artist.
local function related_for(state: yt.Player, row: yt.Flat?, done: (tracks: { Track }, err: string?) -> ()): ()
	if state.video ~= "" then
		player.related(state.video, done)
		return
	end
	local title = if state.title ~= "" then state.title else if row == nil then "" else row.title
	local artist = if row == nil then "" else row.artist
	local query = string.match(title .. if artist ~= "" then " " .. artist else "", "^%s*(.-)%s*$") or ""
	if query == "" then
		done({}, nil)
		return
	end
	local function from_soundcloud(catalog_err: string?): ()
		soundcloud.search(query, function(items: { SearchItem }, err: string?)
			local tracks = tracks_of(items)
			if #tracks > 0 then
				done(tracks, nil)
			else
				done({}, if catalog_err ~= nil then catalog_err else err)
			end
		end)
	end
	catalog.search(query, "tracks", function(items: { SearchItem }, err: string?)
		if err ~= nil then
			from_soundcloud(err)
			return
		end
		for _, item in items do
			if item.video ~= ""
				and item.duration ~= nil
				and state.duration ~= nil
				and math.abs((item.duration :: number) - (state.duration :: number)) <= RELATED_TOLERANCE_S
			then
				player.related(item.video, done)
				return
			end
		end
		from_soundcloud(nil)
	end)
end

tick_autoplay = function(): ()
	load_preferences()
	local state = current
	if not autoplay_enabled
		or autoplay_searching
		or state == nil
		or state.state ~= "playing"
		or state.index < 0
		or state.count == 0
	then
		return
	end
	local seed_row = queue[state.index + 1]
	local seed_url = if seed_row == nil then state.url else seed_row.url
	local seed_key = if state.video ~= "" then state.video else seed_url
	if seed_key == "" then
		return
	end
	local remaining = state.count - state.index - 1
	if remaining > AUTOPLAY_REMAINING or autoplay_seed == seed_key then
		return
	end

	autoplay_seed = seed_key
	autoplay_searching = true
	local generation = autoplay_generation
	local seed_pid = state.pid
	local seed_queue: { yt.Flat } = {}
	for _, queued in queue do
		table.insert(seed_queue, queued)
	end
	local title = if state.title ~= "" then state.title else if seed_row == nil then "" else seed_row.title
	autoplay_message = "Finding related tracks to " .. yt.cut(title, 36)
	notify()

	related_for(state, seed_row, function(tracks: { Track }, err: string?)
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
			if row.url ~= "" then
				known[row.url] = true
			end
		end
		local added = 0
		for _, track in tracks do
			local seen = autoplay_seen[track.url] == true
			if track.url ~= "" and known[track.url] ~= true and not seen and added < AUTOPLAY_ADD_LIMIT then
				request("enqueue", false, track.url, track.video, track.title, track.artist)
				known[track.url] = true
				added += 1
				remember_autoplay(track.url)
			end
		end
		if added > 0 then
			autoplay_message = string.format("Added %d related tracks", added)
		else
			autoplay_message = "No new related tracks found"
		end
		remember_autoplay(seed_key)
		notify()
	end)
end

-- Failed-entry replacement -----------------------------------------------

function player.fallback_message(): string
	return fallback_message
end

-- The bridge only holds the queue after a failure while this module is
-- ready to supply a replacement; the host turns it on and off with each poll.
function player.set_fallback_hold(enabled: boolean): ()
	hold_desired = enabled
	sync_hold(current)
end

sync_hold = function(state: yt.Player?): ()
	if state == nil then
		return
	end
	if hold_desired then
		if not hold_sent or hold_pid ~= state.pid then
			yt.send("hold", "on")
			hold_sent = true
			hold_pid = state.pid
		end
	elseif hold_sent then
		yt.send("hold", "off")
		hold_sent = false
		hold_pid = nil
	end
end

local function release_hold(reason: string): ()
	fallback_message = reason
	request("resume", false)
	notify()
end

-- One failure: search the other source for the same title and artist and
-- swap it into the failed queue position. Two attempts per URL keep a
-- permanently broken link from cycling between sources.
local function begin_replace(index: number): ()
	local row: yt.Flat? = queue[index + 1]
	local failed_url = if row == nil then "" else row.url
	if failed_url ~= "" then
		local attempts = (fallback_attempts[failed_url] or 0) + 1
		fallback_attempts[failed_url] = attempts
		table.insert(fallback_attempt_order, failed_url)
		while #fallback_attempt_order > FALLBACK_SEEN_LIMIT do
			local oldest = table.remove(fallback_attempt_order, 1)
			if oldest ~= nil then
				fallback_attempts[oldest] = nil
			end
		end
		if attempts > FALLBACK_ATTEMPT_LIMIT then
			release_hold(yt.cut(if row == nil then failed_url else row.title, 36) .. " keeps failing; skipped")
			return
		end
	end
	if row == nil or row.title == "" then
		release_hold("A track failed and has no title to search for")
		return
	end
	local title = row.title
	local artist = row.artist
	local query = string.match(title .. if artist ~= "" then " " .. artist else "", "^%s*(.-)%s*$") or ""
	fallback_generation += 1
	local generation = fallback_generation
	fallback_searching = true
	fallback_message = "Finding another source for " .. yt.cut(title, 36)
	notify()

	local function settle(candidate: Track?, err: string?): ()
		if generation ~= fallback_generation then
			return
		end
		fallback_searching = false
		local latest = current
		if latest == nil or latest.failed ~= index then
			-- The hold ended without this search (a timeout, or the user
			-- took over): the queue has moved on, swapping would misfire.
			return
		end
		if candidate ~= nil then
			request("replace", false, tostring(index), candidate.url, candidate.video, candidate.title, candidate.artist)
			fallback_message = "Playing " .. yt.cut(title, 30) .. " from the other source"
		else
			release_hold(if err ~= nil then "No other source: " .. first_line(err) else "No other source found for " .. yt.cut(title, 30))
		end
		notify()
	end

	local function pick(items: { SearchItem }): Track?
		for _, item in items do
			if item.kind == "track" and item.url ~= "" and item.url ~= failed_url then
				return to_track(item)
			end
		end
		return nil
	end
	local function on_soundcloud(catalog_err: string?): ()
		soundcloud.search(query, function(items: { SearchItem }, err: string?)
			local candidate = pick(items)
			settle(candidate, if candidate ~= nil then nil else if catalog_err ~= nil then catalog_err else err)
		end)
	end
	if yt.source_of(failed_url) == "soundcloud" then
		catalog.search(query, "tracks", function(items: { SearchItem }, err: string?)
			local candidate = pick(items)
			if candidate ~= nil then
				settle(candidate, nil)
			else
				on_soundcloud(err)
			end
		end)
	else
		on_soundcloud(nil)
	end
end

-- Turns the bridge's persistent `failed=` field into one replacement per
-- failure (`fail_seq` rises with every captured failure, so a user
-- abandoning a hold and the same track failing again still counts); runs
-- from the poll, after the queue has been refreshed.
tick_fallback = function(): ()
	local state = current
	if state == nil then
		return
	end
	local seq_changed = state.fail_seq ~= fallback_last_seq
	fallback_last_seq = state.fail_seq
	if seq_changed and state.failed ~= nil and state.failed >= 0 then
		begin_replace(state.failed)
	elseif fallback_searching and (state.failed == nil or state.failed < 0) then
		-- The hold ended without this search: a timeout or the user took
		-- over, so the "finding another source" line no longer applies.
		fallback_searching = false
		fallback_message = ""
		notify()
	end
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

local function store_cover(url: string, body: string, header: string?): ()
	if body == "" then
		art_cache[url] = { bytes = "", mime = "" }
		return
	end
	local mime = mime_of(body, header)
	art_cache[url] = { bytes = body, mime = mime }
	table.insert(art_order, url)
	while #art_order > ART_MAX do
		local evicted = table.remove(art_order, 1)
		if evicted ~= nil then
			art_cache[evicted] = nil
		end
	end
	art = { key = url, bytes = body, mime = mime }
end

local function fetch_cover(url: string, image: string, arrived: () -> ()): ()
	tern.fetch(image, { timeout_ms = 15000 }, function(response: FetchResult, _cx)
		if art.loading ~= url then
			return
		end
		art.loading = nil
		if response.error ~= nil or response.status ~= 200 then
			art_cache[url] = { bytes = "", mime = "" }
			return
		end
		store_cover(url, response.body, response.headers["content-type"])
		arrived()
	end)
end

local function urlencode(text: string): string
	return (string.gsub(text, "[^%w%-%._~]", function(char: string)
		return string.format("%%%02X", string.byte(char))
	end))
end

-- SoundCloud tracks have no video id to build a thumbnail from, so ask its
-- oEmbed endpoint for the artwork of the track URL — no client id, and it
-- works after a plugin reload — unless search already reported the artwork.
local function fetch_soundcloud_cover(url: string, arrived: () -> ()): ()
	local hint = art_hints[url]
	if hint ~= nil then
		fetch_cover(url, hint, arrived)
		return
	end
	local endpoint = "https://soundcloud.com/oembed?format=json&url=" .. urlencode(url)
	tern.fetch(endpoint, { timeout_ms = 15000 }, function(response: FetchResult, _cx)
		if art.loading ~= url then
			return
		end
		if response.error ~= nil or response.status ~= 200 or response.body == "" then
			art.loading = nil
			art_cache[url] = { bytes = "", mime = "" }
			return
		end
		local ok, document = pcall(tern.json.decode, response.body)
		local thumbnail = ""
		if ok and type(document) == "table" and type(document.thumbnail_url) == "string" then
			thumbnail = document.thumbnail_url :: string
		end
		if thumbnail == "" then
			art.loading = nil
			art_cache[url] = { bytes = "", mime = "" }
			return
		end
		remember_art(url, thumbnail)
		fetch_cover(url, thumbnail, arrived)
	end)
end

-- Fetches the artwork of the track at `url` once and calls `arrived` when
-- the module's current art changed, so the blocks can re-send it as a blob.
function player.load_cover(url: string, arrived: () -> ()): ()
	if url == "" then
		return
	end
	local cached = art_cache[url]
	if cached ~= nil then
		if cached.bytes == "" then
			-- Artwork that failed before: do not ask for it every poll.
			art.key = url
			return
		end
		if art.key ~= url then
			art = { key = url, bytes = cached.bytes, mime = cached.mime }
			arrived()
		end
		return
	end
	if art.key == url or art.loading == url then
		return
	end
	art.key = url
	art.loading = url
	local source = yt.source_of(url)
	if source == "soundcloud" then
		fetch_soundcloud_cover(url, arrived)
		return
	end
	if source == "youtube" then
		local video = yt.youtube_id(url)
		if video ~= nil then
			fetch_cover(url, yt.thumb(video), arrived)
			return
		end
	end
	-- A pasted link from a service without artwork here: fail once.
	art.loading = nil
	art_cache[url] = { bytes = "", mime = "" }
end

return player
