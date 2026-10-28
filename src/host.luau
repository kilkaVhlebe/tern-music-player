--!strict
-- Music Player: the host half, the `ytmusic.player` block.
--
-- A block is a picture of state that lives elsewhere: mpv owns the playlist,
-- `mpv/bridge.lua` writes it to files, `src/player.luau` reads and commands it,
-- and everything here turns that into a view and into commands.
--
-- Layout: a "now playing" panel that is always visible, then four tabs —
-- Home (recommendations and recently played), Search, Queue and Library.
-- Only the active tab is built, so a render stays cheap however long the
-- queue or the result list grows.
--
-- The player outlives the block on purpose: closing the pane keeps the music
-- playing, the window half's status line shows the track and its palette
-- commands keep controlling it. Blocks have no close hook, so the poll loop
-- drops panes it no longer sees in `tern.pane.list()`.

local yt = require("./ytmusic")
local player = require("./player")
local process = require("./process")
local sched = require("./sched")

local ui = tern.ui

local SEARCH_DEBOUNCE_MS = 350
local POLL_MS = 500
local OPTIMISTIC_MS = 2500
local FLASH_MS = 4000
local CONFIRM_MS = 3000
local SEEK_STEP_S = 10
local VOLUME_STEP = 5
local FOCUS_DELAY_MS = 250
local COVER_RESEND_MS = 1500
local RECENT_LIMIT = 20
-- Below this width the now-playing panel compacts and the hints shorten;
-- below SHORT_ROWS the panel compacts too.
local NARROW_COLS = 70
local SHORT_ROWS = 36

local QUERY_ID = "main.search.field.query"
local ARTIST_ID = "main.search.filters.artist"
local NAME_ID = "main.library.form.name"
local TABS_ID = "main.tabs"

type SearchCategory = player.SearchCategory
type SearchItem = player.SearchItem
type Track = player.Track
type Tab = "home" | "search" | "queue" | "library"
type Mode = "home" | "search" | "artist-filter" | "queue" | "library" | "playlist-name"
type DurationFilter = "all" | "short" | "medium" | "long"
type HomeFocus = "recs" | "recent"

local SEARCH_CATEGORIES: { { id: SearchCategory, label: string } } = {
	{ id = "tracks", label = "Tracks" },
	{ id = "artists", label = "Artists" },
	{ id = "playlists", label = "Playlists" },
	{ id = "podcasts", label = "Podcasts" },
}

local TAB_ORDER: { Tab } = { "home", "search", "queue", "library" }

local function category_label(category: SearchCategory): string
	for _, entry in SEARCH_CATEGORIES do
		if entry.id == category then
			return entry.label
		end
	end
	return "Tracks"
end

local function tab_of(mode: Mode): Tab
	if mode == "search" or mode == "artist-filter" then
		return "search"
	elseif mode == "queue" then
		return "queue"
	elseif mode == "library" or mode == "playlist-name" then
		return "library"
	end
	return "home"
end

type State = {
	mode: Mode,
	category: SearchCategory,
	detail_title: string,
	query: string,
	cursor: number,
	results: { SearchItem },
	sel_search: number,
	artist_filter: string,
	artist_cursor: number,
	duration_filter: DurationFilter,
	playlist_name: string,
	playlist_cursor: number,
	sel_playlist: number,
	sel_queue: number,
	sel_rec: number,
	sel_recent: number,
	home_focus: HomeFocus,
	flash: string,
	flash_until: number,
}

type Block = {
	context: BlockCx,
	state: State,
	blob: string?,
	blob_key: string?,
	resend_at: number?,
	-- Covers of the recommendation cards, one blob per track url; the
	-- now-playing cover keeps using blob/blob_key above.
	covers: { [string]: string },
	covers_seq: number,
	rendered: string,
	searching: boolean,
	search_seq: number,
	search_at: number?,
	focus_at: number?,
	focus_id: string?,
	origin_category: SearchCategory?,
	origin_query: string?,
	optimistic: { [string]: { value: any, expires: number } },
	-- A destructive action waiting for its second press.
	confirm: string?,
	confirm_until: number,
}

local blocks: { [number]: Block } = {}
local queue: { yt.Flat } = {}
local shown_err: string? = nil
local beat: sched.Beat? = nil

-- Leftover runner files from processes whose callbacks a reload dropped;
-- deferred so loading the plugin stays quick.
tern.timer(5000, function()
	pcall(process.cleanup)
end)

local function with(node: Node, props: { [string]: any }): Node
	local merged: { [string]: any } = node.p or {}
	for key, value in props do
		merged[key] = value
	end
	node.p = merged
	return node
end

local function clickable(node: Node, click: string, role: string?, tip: string?): Node
	local name = if role == nil then "ytm-act" else "ytm-act " .. role
	return with(node, { role = name, actions = { click = click }, title = tip })
end

local function button(label: string, click: string, tone: string?, tip: string?): Node
	return clickable(ui.badge(label, tone or "muted"), click, "ytm-button", tip)
end

local function icon_button(icon: string, click: string, role: string, tip: string, tone: string?): Node
	return clickable(ui.node("icon", { name = icon, tone = tone }), click, "ytm-icon " .. role, tip)
end

local function say(block: Block, message: string): ()
	block.state.flash = message
	block.state.flash_until = tern.now() + FLASH_MS
	block.rendered = ""
end

local function source_tag(url: string): string?
	local source = yt.source_of(url)
	if source == "soundcloud" then
		return "SoundCloud"
	elseif source == "youtube" then
		return "YouTube"
	end
	return nil
end

local function with_source(detail: string?, url: string): string?
	if yt.source_of(url) ~= "soundcloud" then
		return detail
	end
	return if detail == nil or detail == "" then "SoundCloud" else detail .. " · SoundCloud"
end

local function alive_panes(): { [number]: boolean }
	local live: { [number]: boolean } = {}
	for _, pane in tern.pane.list() do
		live[pane.pane] = true
	end
	return live
end

local function expect(block: Block, field: string, value: any): ()
	block.optimistic[field] = { value = value, expires = tern.now() + OPTIMISTIC_MS }
end

local function value(block: Block, field: string, actual: any): any
	local pending = block.optimistic[field]
	if pending == nil then
		return actual
	end
	if tern.now() > pending.expires or pending.value == actual then
		block.optimistic[field] = nil
		return actual
	end
	return pending.value
end

-- The player as this block should see it: the file's fields with anything the
-- block just commanded still showing until the player catches up.
local function shown(block: Block): yt.Player?
	local p = player.state()
	if p == nil then
		return nil
	end
	return {
		beat = p.beat,
		pid = p.pid,
		state = value(block, "state", p.state) :: yt.PlayerState,
		pos = p.pos,
		duration = p.duration,
		volume = value(block, "volume", p.volume) :: number,
		mute = value(block, "mute", p.mute) == true,
		shuffle = value(block, "shuffle", p.shuffle) == true,
		loop = value(block, "loop", p.loop) :: yt.Loop,
		index = p.index,
		count = p.count,
		seq = p.seq,
		qv = p.qv,
		proto = p.proto,
		title = p.title,
		artist = p.artist,
		video = p.video,
		url = p.url,
		failed = p.failed,
		fail_seq = p.fail_seq,
		err = p.err,
	}
end

local function render_all(): ()
	for _, block in blocks do
		block.rendered = ""
		block.context:render()
	end
end

-- Cover art -------------------------------------------------------------

local function share_art(): ()
	local art = player.art()
	if art.key == nil or art.bytes == nil then
		return
	end
	local now = tern.now()
	for _, block in blocks do
		if block.blob_key ~= art.key or (block.resend_at ~= nil and now >= block.resend_at) then
			block.resend_at = if block.blob_key ~= art.key then now + COVER_RESEND_MS else nil
			block.blob = block.context:blob(art.bytes :: string, art.mime or "image/jpeg")
			block.blob_key = art.key
			block.rendered = ""
		end
	end
end

-- Sends the covers of the recommendation cards as blobs, one per track url,
-- and forgets the ones no card shows any more; missing covers start fetching.
local function share_covers(block: Block, wanted: { [string]: boolean }): ()
	local changed = false
	for url in block.covers do
		if not wanted[url] then
			block.covers[url] = nil
			changed = true
		end
	end
	for url in wanted do
		if block.covers[url] == nil then
			local bytes, mime = player.cover_of(url)
			if bytes ~= nil then
				block.covers[url] = block.context:blob(bytes, mime or "image/jpeg")
				changed = true
			else
				player.prefetch_cover(url)
			end
		end
	end
	if changed then
		block.covers_seq += 1
		block.rendered = ""
	end
end

player.watch(render_all)

-- Commands --------------------------------------------------------------

local function playing(block: Block): boolean
	local p = shown(block)
	return p ~= nil and p.state == "playing"
end

local function toggle_play(block: Block): ()
	local p = player.state()
	if p == nil then
		-- The command is queued and runs as soon as the fresh player is up.
		say(block, "Starting the player…")
		player.request("toggle")
		return
	end
	if p.count == 0 then
		say(block, "The queue is empty — search for something to play")
		return
	end
	player.request("toggle")
	expect(block, "state", if playing(block) then "paused" else "playing")
end

local function next_track(block: Block): ()
	if player.state() == nil then
		say(block, "Starting the player…")
	end
	player.request("next")
end

local function previous_track(block: Block): ()
	if player.state() == nil then
		say(block, "Starting the player…")
	end
	player.request("prev")
end

local function seek_by(_block: Block, seconds: number): ()
	local p = player.state()
	if p == nil then
		return
	end
	local target = math.max(0, p.pos + seconds)
	if p.duration ~= nil then
		target = math.min(target, p.duration)
	end
	player.request("seek", tostring(target))
end

local function bump_volume(block: Block, delta: number): ()
	local p = shown(block)
	local level = math.clamp(math.floor((if p == nil then 0 else p.volume) + delta + 0.5), 0, yt.volume_max)
	player.request("volume", tostring(level))
	expect(block, "volume", level)
	yt.remember_volume(level)
end

local function toggle_mute(block: Block): ()
	local p = shown(block)
	local on = p ~= nil and not p.mute
	player.request("mute", if on then "on" else "off")
	expect(block, "mute", on)
end

local function toggle_shuffle(block: Block): ()
	local p = shown(block)
	local on = p ~= nil and not p.shuffle
	player.request("shuffle", if on then "on" else "off")
	expect(block, "shuffle", on)
end

local NEXT_LOOP: { [string]: yt.Loop } = { off = "all", all = "one", one = "off" }

local function cycle_loop(block: Block): ()
	local p = shown(block)
	local mode = NEXT_LOOP[if p == nil then "off" else p.loop] or "off"
	player.request("loop", mode)
	expect(block, "loop", mode)
end

local function toggle_autoplay(block: Block): ()
	local enabled = not player.autoplay()
	local ok, failure = player.set_autoplay(enabled)
	if ok then
		say(block, if enabled then "Autoplay on: related tracks follow the queue" else "Autoplay off")
	else
		say(block, "Could not update autoplay: " .. (failure or "unknown error"))
	end
end

local function play_track(block: Block, track: Track): ()
	player.request("play", track.url, track.video, track.title, track.artist)
	expect(block, "state", "starting")
	say(block, "Playing " .. yt.cut(track.title, 60))
end

local function enqueue_track(block: Block, track: Track): ()
	player.request("enqueue", track.url, track.video, track.title, track.artist)
	say(block, "Added to queue: " .. yt.cut(track.title, 60))
end

local function play_next(block: Block, track: Track): ()
	player.play_next(track)
	say(block, "Playing next: " .. yt.cut(track.title, 60))
end

local function to_track(item: SearchItem): Track?
	if item.kind ~= "track" or item.url == "" then
		return nil
	end
	return {
		url = item.url,
		video = item.video,
		title = item.title,
		artist = item.artist,
		duration = item.duration,
	}
end

local function to_search_item(track: Track): SearchItem
	return {
		kind = "track",
		title = track.title,
		artist = track.artist,
		detail = track.artist,
		url = track.url,
		video = track.video,
		duration = track.duration,
		browse_id = "",
	}
end

local function row_track(row: yt.Flat): Track
	return { url = row.url, video = row.video, title = row.title, artist = row.artist, duration = nil }
end

local function filtered_results(state: State): { SearchItem }
	if state.category ~= "tracks" then
		return state.results
	end
	local needle = string.lower(string.match(state.artist_filter, "^%s*(.-)%s*$") or "")
	if needle == "" and state.duration_filter == "all" then
		return state.results
	end
	local visible: { SearchItem } = {}
	for _, item in state.results do
		local duration = item.duration
		local duration_matches = if state.duration_filter == "short"
			then duration ~= nil and duration < 300
			elseif state.duration_filter == "medium"
			then duration ~= nil and duration >= 300 and duration < 1200
			elseif state.duration_filter == "long"
			then duration ~= nil and duration >= 1200
			else true
		local artist_matches = needle == "" or string.find(string.lower(item.artist), needle, 1, true) ~= nil
		if duration_matches and artist_matches then
			table.insert(visible, item)
		end
	end
	return visible
end

local function filtered_tracks(state: State): { Track }
	local tracks: { Track } = {}
	for _, item in filtered_results(state) do
		local track = to_track(item)
		if track ~= nil then
			table.insert(tracks, track)
		end
	end
	return tracks
end

local function play_tracks(block: Block, tracks: { Track }, from: number, message: string): ()
	if #tracks == 0 then
		say(block, "No tracks to play")
		return
	end
	local start = math.clamp(from, 1, #tracks)
	player.set_queue(tracks, start)
	expect(block, "state", "starting")
	block.state.sel_queue = start
	say(block, message)
end

local function queue_tracks(block: Block, tracks: { Track }, message: string): ()
	if #tracks == 0 then
		say(block, "No tracks to add")
		return
	end
	player.enqueue_many(tracks)
	say(block, message)
end

-- Asks for a second press within CONFIRM_MS; true when this press confirms.
local function confirmed(block: Block, what: string, prompt: string): boolean
	local now = tern.now()
	if block.confirm == what and now <= block.confirm_until then
		block.confirm = nil
		return true
	end
	block.confirm = what
	block.confirm_until = now + CONFIRM_MS
	say(block, prompt)
	return false
end

local function confirming(block: Block, what: string): boolean
	return block.confirm == what and tern.now() <= block.confirm_until
end

local function save_playlist(block: Block, source: "results" | "queue"): ()
	local name = string.match(block.state.playlist_name, "^%s*(.-)%s*$") or ""
	local tracks: { Track } = {}
	if source == "results" then
		tracks = filtered_tracks(block.state)
		if #tracks == 0 then
			say(block, "No search results to save")
			return
		end
	else
		for _, row in queue do
			table.insert(tracks, row_track(row))
		end
	end
	local ok, failure = player.save_playlist(name, tracks)
	if not ok then
		say(block, failure or "Could not save the playlist")
		return
	end
	for index, playlist in player.playlists() do
		if string.lower(playlist.name) == string.lower(name) then
			block.state.sel_playlist = index
			break
		end
	end
	say(block, string.format("Saved %d tracks to “%s”", #tracks, name))
end

local function delete_playlist(block: Block, index: number): ()
	local saved = player.playlists()[index]
	if saved == nil then
		say(block, "Select a playlist first")
		return
	end
	if not confirmed(block, "delete:" .. saved.name, "Press Delete again to delete “" .. yt.cut(saved.name, 40) .. "”") then
		return
	end
	local ok, failure = player.delete_playlist(index)
	if not ok then
		say(block, failure or "Could not delete the playlist")
		return
	end
	block.state.sel_playlist = math.max(1, math.min(block.state.sel_playlist, #player.playlists()))
	say(block, "Deleted “" .. yt.cut(saved.name, 40) .. "”")
end

local function play_playlist(block: Block, index: number): ()
	local saved = player.playlists()[index]
	if saved == nil then
		say(block, "Select a playlist first")
		return
	end
	play_tracks(block, saved.tracks, 1, "Playing “" .. yt.cut(saved.name, 48) .. "”")
end

local function enqueue_playlist(block: Block, index: number): ()
	local saved = player.playlists()[index]
	if saved == nil then
		say(block, "Select a playlist first")
		return
	end
	queue_tracks(block, saved.tracks, string.format("Added %d tracks from “%s”", #saved.tracks, yt.cut(saved.name, 36)))
end

local function jump_to(block: Block, index: number): ()
	if index < 0 or index >= #queue then
		return
	end
	player.request("jump", tostring(index))
	expect(block, "state", "starting")
	block.state.sel_queue = index + 1
end

local function remove_at(block: Block, index: number): ()
	if index < 0 or index >= #queue then
		return
	end
	player.request("remove", tostring(index))
	block.state.sel_queue = math.max(1, math.min(index + 1, #queue - 1))
end

local function clear_queue(block: Block): ()
	if #queue == 0 then
		return
	end
	if not confirmed(block, "clear", "Press Clear again to empty the queue") then
		return
	end
	player.request("clear")
	say(block, "Queue cleared")
end

local function focus_later(block: Block, id: string): ()
	block.focus_id = id
	block.focus_at = tern.now() + FOCUS_DELAY_MS
end

local function show_tab(block: Block, tab: Tab): ()
	local state = block.state
	if tab == "search" then
		state.mode = "search"
		focus_later(block, QUERY_ID)
	elseif tab == "queue" then
		state.mode = "queue"
	elseif tab == "library" then
		state.mode = "library"
	else
		state.mode = "home"
	end
	block.rendered = ""
end

local function cycle_tab(block: Block, step: number): ()
	local current = tab_of(block.state.mode)
	for index, tab in TAB_ORDER do
		if tab == current then
			show_tab(block, TAB_ORDER[(index - 1 + step) % #TAB_ORDER + 1])
			return
		end
	end
	show_tab(block, "home")
end

-- Search ----------------------------------------------------------------

local function start_search(block: Block): ()
	local query = block.state.query
	block.search_seq += 1
	local seq = block.search_seq
	if query == "" then
		block.state.results = {}
		block.searching = false
		block.rendered = ""
		return
	end
	block.searching = true
	block.state.results = {}
	block.state.sel_search = 1
	block.rendered = ""
	player.search(query, block.state.category, function(items: { SearchItem }, err: string?, pending: boolean?)
		local live = blocks[block.context.pane]
		if live ~= block or block.search_seq ~= seq then
			return
		end
		block.searching = pending == true
		if err ~= nil then
			say(block, "Search failed: " .. yt.cut(err, 120))
		else
			block.state.results = items
			block.state.sel_search = math.clamp(block.state.sel_search, 1, math.max(#items, 1))
		end
		block.rendered = ""
		block.context:render()
	end)
end

local function open_result(block: Block, item: SearchItem): ()
	if item.kind == "track" then
		local track = to_track(item)
		if track ~= nil then
			play_track(block, track)
		end
		return
	end
	local state = block.state
	block.origin_category = state.category
	block.origin_query = state.query
	block.search_seq += 1
	local seq = block.search_seq
	block.search_at = nil
	block.searching = true
	state.category = "tracks"
	state.detail_title = item.title
	state.query = item.title
	state.cursor = #state.query
	state.results = {}
	state.sel_search = 1
	state.artist_filter = ""
	state.artist_cursor = 0
	state.duration_filter = "all"
	state.mode = "search"
	block.rendered = ""
	player.open_search_result(item, function(tracks: { Track }, err: string?)
		local live = blocks[block.context.pane]
		if live ~= block or block.search_seq ~= seq then
			return
		end
		block.searching = false
		if err ~= nil then
			say(block, "Could not open " .. yt.cut(item.title, 40) .. ": " .. yt.cut(err, 100))
		else
			for _, track in tracks do
				table.insert(state.results, to_search_item(track))
			end
			if #state.results == 0 then
				say(block, "No playable tracks in " .. yt.cut(item.title, 60))
			end
		end
		block.rendered = ""
		block.context:render()
	end)
end

local function back_to_results(block: Block): ()
	local category = block.origin_category
	if category == nil then
		return
	end
	local state = block.state
	block.origin_category = nil
	state.detail_title = ""
	state.category = category :: SearchCategory
	state.query = block.origin_query or ""
	state.cursor = #state.query
	block.origin_query = nil
	state.results = {}
	state.sel_search = 1
	block.searching = false
	block.search_seq += 1
	block.search_at = if state.query ~= "" then tern.now() + SEARCH_DEBOUNCE_MS else nil
	block.rendered = ""
end

local function set_category(block: Block, category: SearchCategory): ()
	local state = block.state
	if state.category == category and state.detail_title == "" then
		return
	end
	block.origin_category = nil
	block.origin_query = nil
	state.detail_title = ""
	state.category = category
	state.results = {}
	state.sel_search = 1
	state.artist_filter = ""
	state.artist_cursor = 0
	state.duration_filter = "all"
	state.mode = "search"
	block.search_seq += 1
	block.searching = false
	block.search_at = if state.query ~= "" then tern.now() + SEARCH_DEBOUNCE_MS else nil
	block.rendered = ""
end

local function edit_text(text: string, cursor: number, k: Key): (string, number, boolean)
	if k.name == "paste" and k.text ~= nil then
		local pasted = string.gsub(k.text, "[%c]+", " ")
		text = text:sub(1, cursor) .. pasted .. text:sub(cursor + 1)
		cursor += #pasted
	elseif k.name == "backspace" then
		if cursor == 0 then
			return text, cursor, false
		end
		local before = yt.prev_at(text, cursor)
		text = text:sub(1, before) .. text:sub(cursor + 1)
		cursor = before
	elseif k.name == "delete" then
		if cursor >= #text then
			return text, cursor, false
		end
		text = text:sub(1, cursor) .. text:sub(yt.next_at(text, cursor) + 1)
	elseif k.name == "left" then
		cursor = yt.prev_at(text, cursor)
	elseif k.name == "right" then
		cursor = yt.next_at(text, cursor)
	elseif k.name == "home" then
		cursor = 0
	elseif k.name == "end" then
		cursor = #text
	elseif k.text ~= nil and not (k.ctrl or k.meta or k.alt) then
		text = text:sub(1, cursor) .. k.text .. text:sub(cursor + 1)
		cursor += #k.text
	else
		return text, cursor, false
	end
	return text, cursor, true
end

local function edit_query(block: Block, k: Key): boolean
	local state = block.state
	local query, cursor, handled = edit_text(state.query, state.cursor, k)
	if not handled then
		return false
	end
	state.cursor = cursor
	if query ~= state.query then
		block.origin_category = nil
		block.origin_query = nil
		state.detail_title = ""
		block.search_seq += 1
		block.searching = false
		state.query = query
		state.sel_search = 1
		block.search_at = tern.now() + SEARCH_DEBOUNCE_MS
	end
	return true
end

local function edit_artist_filter(state: State, k: Key): boolean
	local filter, cursor, handled = edit_text(state.artist_filter, state.artist_cursor, k)
	if not handled then
		return false
	end
	state.artist_filter = filter
	state.artist_cursor = cursor
	state.sel_search = 1
	return true
end

local function edit_playlist_name(state: State, k: Key): boolean
	local name, cursor, handled = edit_text(state.playlist_name, state.playlist_cursor, k)
	if not handled then
		return false
	end
	state.playlist_name = name
	state.playlist_cursor = cursor
	return true
end

-- View: now playing -----------------------------------------------------

local function current_row(p: yt.Player?): yt.Flat?
	if p ~= nil and p.index >= 0 and p.index < #queue then
		return queue[p.index + 1]
	end
	return nil
end

-- The current track's cover; the placeholder when nothing is loaded.
local function cover_node(block: Block, p: yt.Player?, size: number): Node
	local art = player.art()
	local loaded = p ~= nil and p.url ~= "" and art.key == p.url
	if loaded and block.blob ~= nil and block.blob_key == art.key then
		return with(ui.node("image", { blob = block.blob, alt = "Cover", w = size, h = size }), {
			key = "art",
			role = "ytm-cover",
		})
	end
	return with(ui.node("icon", { name = "wave" }), { key = "art", role = "ytm-cover ytm-cover-empty" })
end

local function progress_row(p: yt.Player?): Node
	local has_track = p ~= nil and p.url ~= ""
	local position = if p == nil then 0 else p.pos
	local total = if p == nil then nil else p.duration
	local fill: number? = 0
	if total ~= nil and total > 0 then
		-- Whole percent: the bar moves in steps the view sends anyway.
		fill = math.floor(math.clamp(position / total, 0, 1) * 100) / 100
	elseif has_track and p ~= nil and p.state == "starting" then
		fill = nil -- indeterminate while the stream resolves
	end
	-- The clock ticks on its own in the window, so the block re-renders for
	-- the bar's percent steps, not every second.
	local clock: Node
	if not has_track then
		clock = ui.text({ ui.span("--:--", "muted") })
	elseif p ~= nil and p.state == "playing" then
		clock = ui.node("elapsed", { age = math.floor(position * 1000), format = "clock" })
	else
		clock = ui.node("elapsed", { stopped = math.floor(position * 1000), format = "clock" })
	end
	return with(ui.row({
		with(clock, { key = "at", role = "ytm-time", min = { w = "5ch" } }),
		with(ui.progress(fill, ""), { key = "bar", role = "ytm-bar", grow = 1 }),
		with(ui.text({ ui.span(if has_track then yt.clock(total) else "--:--", "muted") }), {
			key = "len",
			role = "ytm-time ytm-time-total",
			min = { w = "5ch" },
		}),
	}), { key = "progress", role = "ytm-progress" })
end

local function control_row(p: yt.Player?, narrow: boolean): Node
	local shuffle_on = p ~= nil and p.shuffle
	local playing_now = p ~= nil and p.state == "playing"
	local muted = p ~= nil and p.mute
	local loop_mode = if p == nil then "off" else p.loop
	local loop_tip = if loop_mode == "one" then "Repeat one (r)" elseif loop_mode == "all" then "Repeat all (r)" else "Repeat off (r)"
	local transport_items: { Node } = {
		icon_button("swap", "shuffle", "ytm-shuffle", if shuffle_on then "Shuffle on (s)" else "Shuffle off (s)", if shuffle_on then "accent" else nil),
		icon_button("frame-prev", "prev", "ytm-prev", "Previous (p)"),
		icon_button(if playing_now then "pause" else "play", "play-pause", "ytm-play", if playing_now then "Pause (space)" else "Play (space)"),
		icon_button("frame-next", "next", "ytm-next", "Next (n)"),
		icon_button("repeat", "loop", "ytm-repeat", loop_tip, if loop_mode ~= "off" then "accent" else nil),
	}
	if loop_mode == "one" then
		table.insert(transport_items, with(ui.text({ ui.span("1") }), { key = "one", role = "ytm-repeat-badge" }))
	end
	local transport = with(ui.row(transport_items), { key = "transport", role = "ytm-transport" })
	local level = if p == nil then "–" else tostring(math.floor(p.volume + 0.5)) .. "%"
	local mixer = with(ui.row({
		icon_button(if muted then "slash-circle" else "wave", "mute", "ytm-mute", if muted then "Unmute (m)" else "Mute (m)", if muted then "warning" else nil),
		icon_button("minus", "volume-down", "ytm-volume", "Volume down (-)"),
		with(ui.text({ ui.span(level, if muted or p == nil then "muted" else nil) }), {
			key = "level",
			role = "ytm-level",
			min = { w = "4ch" },
		}),
		icon_button("plus", "volume-up", "ytm-volume", "Volume up (+)"),
	}), { key = "mixer", role = "ytm-mixer" })
	local autoplay = player.autoplay()
	local auto = clickable(
		ui.badge(if autoplay then "Autoplay on" else "Autoplay off", if autoplay then "accent" else "muted"),
		"toggle-autoplay",
		"ytm-autoplay",
		"Add related tracks when the queue runs low (a)"
	)
	local children = { transport, mixer, with(auto, { key = "autoplay" }) }
	return with(ui.row(children), {
		key = "controls",
		role = if narrow then "ytm-controls ytm-controls-narrow" else "ytm-controls",
	})
end

local function now_playing(block: Block, p: yt.Player?, cx: BlockCx): Node
	-- Narrow or short panes (the picture-in-picture float) get the compact
	-- panel, so the tab content keeps some room.
	local narrow = cx.cols < NARROW_COLS or cx.rows < SHORT_ROWS
	local row = current_row(p)
	local title = ""
	local artist = ""
	local url = ""
	if p ~= nil then
		title = p.title
		artist = p.artist
		url = p.url
	end
	if row ~= nil then
		if title == "" or title == row.url then
			title = row.title
		end
		if artist == "" then
			artist = row.artist
		end
	end
	local status: Span? = nil
	if player.problem() ~= nil then
		status = ui.span("The player cannot run — see above", "error")
	elseif p == nil then
		status = ui.span(if player.is_running() then "Starting the player…" else "Player stopped — press play to start it", "muted")
	elseif p.err ~= "" then
		status = ui.span(yt.cut(p.err, 120), "error")
	elseif p.state == "starting" and url ~= "" then
		status = ui.span("Loading…", "muted")
	end
	if title == "" then
		title = if url ~= "" then url else "Nothing playing"
	end

	local meta: { Node } = {
		with(ui.text({ ui.span(yt.cut(title, 90), "strong") }), { key = "title", role = "ytm-title" }),
	}
	local line: { Span } = {}
	if artist ~= "" then
		table.insert(line, ui.span(yt.cut(artist, 60), "muted"))
	end
	local tag = if url ~= "" then source_tag(url) else nil
	if tag ~= nil then
		if #line > 0 then
			table.insert(line, ui.span("  ·  ", "dim"))
		end
		table.insert(line, ui.span(tag, "dim"))
	end
	if p ~= nil and p.count > 0 and p.index >= 0 then
		table.insert(line, ui.span(string.format("  ·  %d of %d", p.index + 1, p.count), "dim"))
	end
	if #line > 0 then
		table.insert(meta, with(ui.text(line), { key = "artist", role = "ytm-artist" }))
	end
	if status ~= nil then
		table.insert(meta, with(ui.text({ status :: Span }), { key = "status", role = "ytm-now-status" }))
	end
	table.insert(meta, progress_row(p))

	local top = with(ui.row({
		cover_node(block, p, if narrow then 64 else 96),
		with(ui.col(meta), { key = "meta", grow = 1, role = "ytm-meta" }),
	}), { key = "top", role = "ytm-now-top" })
	return with(ui.col({ top, control_row(p, narrow) }), {
		key = "now",
		role = if narrow then "ytm-now ytm-now-narrow" else "ytm-now",
	})
end

-- View: pages -----------------------------------------------------------

-- How many list rows fit under the now-playing panel, the tab strip and the
-- page's own controls (`reserved`, in terminal rows). A list row is a line
-- plus padding, a bit taller than a terminal row, hence the factor. With a
-- height cap the list scrolls itself and keeps the selection in view.
local function list_lines(cx: BlockCx, reserved: number): number
	return math.max(5, math.floor((cx.rows - reserved) * 0.68))
end

local function tabs_node(state: State): Node
	local playlists = #player.playlists()
	return ui.node("tabs", {
		key = "tabs",
		role = "ytm-tabs",
		active = tab_of(state.mode),
		items = {
			{ id = "home", label = { ui.span("Home") } },
			{ id = "search", label = { ui.span("Search") } },
			{ id = "queue", label = { ui.span("Queue"), ui.span(if #queue > 0 then "  " .. tostring(#queue) else "", "muted") } },
			{ id = "library", label = { ui.span("Library"), ui.span(if playlists > 0 then "  " .. tostring(playlists) else "", "muted") } },
		},
	})
end

local function heading(text: string, extra: { Node }?, key: string): Node
	local kids: { Node } = { with(ui.text({ ui.span(text, "strong") }), { key = "label", role = "ytm-heading-label", grow = 1 }) }
	if extra ~= nil then
		for _, node in extra do
			table.insert(kids, node)
		end
	end
	return with(ui.row(kids), { key = key, role = "ytm-heading" })
end

local function rec_card(block: Block, index: number, track: Track, selected: boolean): Node
	local cover: Node
	local blob = block.covers[track.url]
	if blob ~= nil then
		cover = with(ui.node("image", { blob = blob, alt = "", w = 112, h = 112 }), {
			key = "c",
			role = "ytm-rec-cover",
		})
	else
		cover = with(ui.node("icon", { name = "wave" }), { key = "c", role = "ytm-rec-cover ytm-rec-cover-empty" })
	end
	local lines: { Node } = {
		cover,
		with(ui.text({ ui.span(yt.cut(if track.title ~= "" then track.title else track.url, 48), "strong") }), {
			key = "t",
			role = "ytm-rec-title",
		}),
	}
	local detail = with_source(track.artist, track.url)
	if detail ~= nil and detail ~= "" then
		table.insert(lines, with(ui.text({ ui.span(yt.cut(detail, 40), "muted") }), {
			key = "a",
			role = "ytm-rec-artist",
		}))
	end
	return with(ui.col(lines), {
		key = "c" .. tostring(index),
		role = "ytm-rec" .. if selected then " ytm-rec-selected" else "",
		title = track.title .. if track.artist ~= "" then " — " .. track.artist else "",
		actions = { click = "rec=" .. tostring(index), menu = { "Play", "Play next", "Add to queue" } },
	})
end

local function track_items(tracks: { Track }, prefix: string, menu: { string }): { Node }
	local items: { Item } = {}
	for index, track in tracks do
		items[index] = {
			label = if track.title ~= "" then track.title else track.url,
			detail = with_source(if track.artist ~= "" then track.artist else nil, track.url),
			value = if track.duration == nil then nil else yt.clock(track.duration),
		}
	end
	local children: { Node } = ui.list(items).c or {}
	for index, child in children do
		with(child, { key = prefix .. tostring(index), actions = { menu = menu } })
	end
	return children
end

local function home_page(block: Block, state: State, cx: BlockCx): Node
	local recs = player.recommendations()
	local loading, recs_message = player.recommendations_status()
	local body: { Node } = {}
	local tools: { Node } = {}
	if loading then
		table.insert(tools, with(ui.node("spinner", { style = "dots" }), { key = "spin" }))
	end
	table.insert(tools, with(button("Refresh", "refresh-recs", "muted", "Pick a new set from your history"), { key = "refresh" }))
	table.insert(body, heading("Recommended for you", tools, "recs-head"))
	if #recs > 0 then
		local selected = math.clamp(state.sel_rec, 1, #recs)
		local cards: { Node } = {}
		for index, track in recs do
			table.insert(cards, rec_card(block, index, track, state.home_focus == "recs" and index == selected))
		end
		table.insert(body, with(ui.row(cards), { key = "cards", role = "ytm-rec-cards" }))
	else
		local note = if recs_message ~= ""
			then recs_message
			elseif loading then "Picking tracks from your listening history…"
			else "Play a few tracks — recommendations built from what you listen to appear here."
		table.insert(body, with(ui.text({ ui.span(note, "muted") }), { key = "recs-empty", role = "ytm-empty" }))
	end

	local history = player.history()
	local recent: { Track } = {}
	for index, track in history do
		if index > RECENT_LIMIT then
			break
		end
		table.insert(recent, track)
	end
	table.insert(body, heading("Recently played", nil, "recent-head"))
	local selected: string? = nil
	if #recent > 0 and state.home_focus == "recent" then
		selected = "main.home.recent.h" .. tostring(math.clamp(state.sel_recent, 1, #recent))
	end
	table.insert(body, ui.node("list", {
		key = "recent",
		role = "ytm-list",
		selected = selected,
		max = { lines = 8 },
		empty = { ui.span("Nothing yet — tracks appear here after ten seconds of listening.", "muted") },
	}, track_items(recent, "h", { "Play", "Play next", "Add to queue" })))
	return with(ui.col(body), { key = "home", role = "ytm-page ytm-home" })
end

local function search_page(block: Block, state: State, cx: BlockCx): Node
	local visible = filtered_results(state)
	local body: { Node } = {}

	local categories: { Node } = {}
	for _, entry in SEARCH_CATEGORIES do
		table.insert(
			categories,
			with(clickable(
				ui.badge(entry.label, if state.category == entry.id and state.detail_title == "" then "accent" else "muted"),
				"category=" .. entry.id,
				"ytm-chip"
			), { key = entry.id })
		)
	end
	if block.origin_category ~= nil then
		table.insert(categories, with(clickable(ui.badge("‹ Back", "muted"), "back-results", "ytm-chip", "Back to the results (esc)"), { key = "back" }))
	end
	table.insert(body, with(ui.row(categories), { key = "categories", role = "ytm-chips" }))

	local field: { Node } = {
		with(ui.node("input", {
			key = "query",
			text = state.query,
			cursor = yt.units_for_bytes(state.query, state.cursor),
			placeholder = "Search YouTube Music and SoundCloud",
		}), { grow = 1 }),
	}
	if block.searching then
		table.insert(field, with(ui.node("spinner", { style = "dots" }), { key = "spin" }))
	end
	table.insert(body, with(ui.row(field), { key = "field", role = "ytm-field" }))

	if state.category == "tracks" then
		local duration_filter = state.duration_filter
		local function duration_chip(id: DurationFilter, label: string): Node
			return with(clickable(ui.badge(label, if duration_filter == id then "accent" else "muted"), "duration=" .. id, "ytm-chip"), { key = id })
		end
		table.insert(body, with(ui.row({
			with(ui.row({
				duration_chip("all", "Any length"),
				duration_chip("short", "< 5 min"),
				duration_chip("medium", "5–20 min"),
				duration_chip("long", "20+ min"),
			}), { key = "durations", role = "ytm-chips" }),
			with(ui.node("input", {
				key = "artist",
				text = state.artist_filter,
				cursor = yt.units_for_bytes(state.artist_filter, state.artist_cursor),
				placeholder = "Filter by artist",
			}), { grow = 1, role = "ytm-filter-input" }),
		}), { key = "filters", role = "ytm-filters" }))
	end

	local title = if state.detail_title ~= "" then state.detail_title else category_label(state.category)
	local count = if #state.results == 0
		then ""
		elseif #visible == #state.results then tostring(#visible)
		else string.format("%d of %d", #visible, #state.results)
	local tools: { Node } = {}
	if count ~= "" then
		table.insert(tools, with(ui.text({ ui.span(count, "muted") }), { key = "count" }))
	end
	if state.category == "tracks" and #visible > 0 then
		table.insert(tools, with(button("Play all", "play-all", "accent", "Replace the queue with these results"), { key = "play-all" }))
		table.insert(tools, with(button("Add all", "queue-all", "muted", "Append these results to the queue"), { key = "queue-all" }))
	end
	table.insert(body, heading(title, tools, "head"))

	local items: { Item } = {}
	for index, result in visible do
		local detail: string? = if result.detail ~= "" then result.detail elseif result.artist ~= "" then result.artist else nil
		items[index] = {
			label = if result.title ~= "" then result.title else result.url,
			detail = with_source(detail, result.url),
			value = if result.duration == nil then nil else yt.clock(result.duration),
			icon = if result.kind == "artist" then "user" elseif result.kind == "playlist" or result.kind == "podcast" then "list" else nil,
		}
	end
	local children: { Node } = ui.list(items).c or {}
	for index, child in children do
		local result = visible[index]
		local menu = if result ~= nil and result.kind == "track" then { "Play", "Play next", "Add to queue" } else { "Open" }
		with(child, { key = "r" .. tostring(index), actions = { menu = menu } })
	end
	local selected: string? = nil
	if #visible > 0 then
		selected = "main.search.results.r" .. tostring(math.clamp(state.sel_search, 1, #visible))
	end
	local empty = if block.searching
		then "Searching…"
		elseif #state.results > 0 then "No results match these filters"
		elseif state.query == "" then "Type to search " .. string.lower(category_label(state.category))
		else "No results"
	table.insert(body, ui.node("list", {
		key = "results",
		role = "ytm-list",
		selected = selected,
		filter = if state.detail_title == "" then state.query else nil,
		max = { lines = list_lines(cx, if state.category == "tracks" then 26 else 22) },
		empty = { ui.span(empty, "muted") },
	}, children))
	return with(ui.col(body), { key = "search", role = "ytm-page ytm-search" })
end

local function queue_page(block: Block, state: State, p: yt.Player?, cx: BlockCx): Node
	local items: { Item } = {}
	for index, row in queue do
		local playing_row = p ~= nil and p.index == row.index
		items[index] = {
			label = if row.title ~= "" then row.title else row.url,
			detail = with_source(if row.artist ~= "" then row.artist else nil, row.url),
			icon = if playing_row then (if p ~= nil and p.state == "playing" then "play" else "pause") else nil,
			tone = if playing_row then "accent" else nil,
			value = tostring(index),
		}
	end
	local children: { Node } = ui.list(items).c or {}
	for index, child in children do
		with(child, { key = "q" .. tostring(index), actions = { menu = { "Play", "Remove" } } })
	end
	local selected: string? = nil
	if #queue > 0 then
		selected = "main.queue.list.q" .. tostring(math.clamp(state.sel_queue, 1, #queue))
	end
	local tools: { Node } = {}
	if #queue > 0 then
		table.insert(tools, with(button("Save as playlist", "save-queue-as", "muted", "Name it in Library"), { key = "save" }))
		local armed = confirming(block, "clear")
		table.insert(tools, with(button(if armed then "Confirm clear" else "Clear", "clear", if armed then "warning" else "muted", "Empty the queue (c)"), { key = "clear" }))
	end
	local label = if #queue == 0 then "Queue" else string.format("Queue · %d tracks", #queue)
	return with(ui.col({
		heading(label, tools, "head"),
		ui.node("list", {
			key = "list",
			role = "ytm-list",
			selected = selected,
			max = { lines = list_lines(cx, 19) },
			empty = { ui.span("The queue is empty — find something in Search, or play a recommendation.", "muted") },
		}, children),
	}), { key = "queue", role = "ytm-page ytm-queue" })
end

local function library_page(block: Block, state: State, cx: BlockCx): Node
	local saved = player.playlists()
	local items: { Item } = {}
	for index, playlist in saved do
		items[index] = {
			label = playlist.name,
			value = tostring(#playlist.tracks) .. " tracks",
			icon = "list",
		}
	end
	local children: { Node } = ui.list(items).c or {}
	for index, child in children do
		with(child, { key = "p" .. tostring(index), actions = { menu = { "Play", "Add to queue", "Delete" } } })
	end
	local selected: string? = nil
	if #saved > 0 then
		selected = "main.library.list.p" .. tostring(math.clamp(state.sel_playlist, 1, #saved))
	end

	local form: { Node } = {
		with(ui.node("input", {
			key = "name",
			text = state.playlist_name,
			cursor = yt.units_for_bytes(state.playlist_name, state.playlist_cursor),
			placeholder = "New playlist name",
		}), { grow = 1 }),
		with(button("Save queue", "save-queue", "accent", "Save the current queue under this name"), { key = "save-queue" }),
	}
	if state.category == "tracks" and #state.results > 0 then
		table.insert(form, with(button("Save results", "save-results", "muted", "Save the visible search results under this name"), { key = "save-results" }))
	end

	local tools: { Node } = {}
	if #saved > 0 then
		local target = saved[math.clamp(state.sel_playlist, 1, #saved)]
		local armed = target ~= nil and confirming(block, "delete:" .. target.name)
		table.insert(tools, with(button("Play", "play-playlist", "accent"), { key = "play" }))
		table.insert(tools, with(button("Add to queue", "queue-playlist", "muted"), { key = "add" }))
		table.insert(tools, with(button(if armed then "Confirm delete" else "Delete", "delete-playlist", if armed then "warning" else "muted"), { key = "delete" }))
	end

	local body: { Node } = {
		with(ui.row(form), { key = "form", role = "ytm-field" }),
		heading(if #saved == 0 then "Playlists" else string.format("Playlists · %d", #saved), tools, "head"),
		ui.node("list", {
			key = "list",
			role = "ytm-list",
			selected = selected,
			max = { lines = list_lines(cx, 22) },
			empty = { ui.span("No playlists yet — name one above and save the queue.", "muted") },
		}, children),
	}
	local problem = player.preferences_problem()
	if problem ~= nil then
		table.insert(body, with(ui.text({ ui.span("Playlist storage unavailable: " .. yt.cut(problem, 100), "error") }), { key = "problem" }))
	end
	return with(ui.col(body), { key = "library", role = "ytm-page ytm-library" })
end

local function problem_card(): Node?
	local problem = player.problem()
	if problem == nil then
		return nil
	end
	return with(ui.card({ ui.span("The player cannot run", "strong error") }, {
		ui.text({ ui.span(problem, "error") }),
		ui.text({
			ui.span("Install:  winget install mpv yt-dlp   ·   brew install mpv yt-dlp   ·   sudo apt install mpv yt-dlp", "muted"),
		}),
		ui.text({ ui.span("Logs: " .. yt.data_dir, "muted") }),
	}), { key = "problem", tone = "error" })
end

local function hints(state: State, cx: BlockCx): Node
	local narrow = cx.cols < NARROW_COLS
	local spans: { Span } = {}
	local function key(label: string, description: string): ()
		if #spans > 0 then
			table.insert(spans, ui.span("   ", "dim"))
		end
		table.insert(spans, ui.span(label, "key"))
		table.insert(spans, ui.span(" " .. description, "dim"))
	end
	local mode = state.mode
	if mode == "search" or mode == "artist-filter" then
		key("↑↓", "pick")
		key("enter", if state.category == "tracks" then "play" else "open")
		if state.category == "tracks" then
			key("shift+enter", "add to queue")
		end
		key("esc", if state.query ~= "" then "clear" else "back")
		key("tab", "next tab")
	elseif mode == "playlist-name" then
		key("enter", "save queue")
		key("esc", "done")
	else
		if mode == "home" then
			key("←→", "pick")
			key("↑↓", "recent")
			key("enter", "play")
			key("e", "add")
		elseif mode == "queue" then
			key("↑↓", "pick")
			key("enter", "play")
			key("d", "remove")
			if not narrow then
				key("c", "clear")
			end
		elseif mode == "library" then
			key("↑↓", "pick")
			key("enter", "play")
			key("e", "add")
			key("d", "delete")
		end
		key("space", "play/pause")
		if not narrow then
			key("n p", "next/prev")
			key("+ -", "volume")
			key("/", "search")
		end
		key("tab", "next tab")
	end
	return with(ui.text(spans), { key = "hints", role = "ytm-hints" })
end

local function dock(state: State, cx: BlockCx): Node
	local lines: { Node } = {}
	local notice: Span? = nil
	if state.flash ~= "" then
		notice = ui.span(state.flash, "accent")
	else
		local fallback_message = player.fallback_message()
		local autoplay_message = player.autoplay_message()
		if fallback_message ~= "" then
			notice = ui.span(fallback_message, "warning")
		elseif autoplay_message ~= "" then
			notice = ui.span(autoplay_message, "muted")
		end
	end
	if notice ~= nil then
		table.insert(lines, with(ui.text({ notice :: Span }), { key = "notice", role = "ytm-flash" }))
	end
	table.insert(lines, hints(state, cx))
	return with(ui.col(lines), { role = "ytm-dock" })
end

-- What a render depends on beyond the state table: when this string is the
-- same as last time, the poll skips the render. Position counts in percent
-- steps only — the clock ticks by itself in the window.
local function signature(block: Block): string
	local p = shown(block)
	local recs_loading, recs_message = player.recommendations_status()
	local step = "-"
	if p ~= nil then
		local total = p.duration
		step = if total ~= nil and total > 0 then tostring(math.floor(p.pos / total * 100)) else tostring(p.pos // 5)
	end
	local parts: { string } = {
		if p == nil then "none" else p.state,
		step,
		tostring(if p == nil then nil else p.duration),
		tostring(if p == nil then -1 else p.index),
		tostring(if p == nil then 0 else p.count),
		if p == nil then "" else p.title,
		if p == nil then "" else p.artist,
		if p == nil then "" else p.url,
		if p == nil then "" else p.err,
		if p == nil then "" else tostring(p.volume),
		if p == nil then "" else tostring(p.mute),
		if p == nil then "" else p.loop,
		if p == nil then "" else tostring(p.shuffle),
		tostring(player.queue_epoch()),
		block.state.mode,
		block.state.flash,
		tostring(block.searching),
		tostring(block.blob_key),
		tostring(block.covers_seq),
		tostring(block.confirm),
		tostring(player.recommendations_version()),
		tostring(recs_loading),
		recs_message,
		tostring(player.history_version()),
		tostring(#player.playlists()),
		tostring(player.autoplay()),
		player.autoplay_message(),
		player.fallback_message(),
		tostring(player.problem()),
		tostring(player.is_running()),
	}
	return table.concat(parts, "|")
end

-- The poll loop ---------------------------------------------------------

-- One poll. With no visible blocks the loop still doubles as the plugin's
-- daemon while mpv runs: it records listening history, refreshes the
-- recommendations and drives autoplay; it stops once the player is gone.
local function poll_once(): boolean
	local live = alive_panes()
	for pane in blocks do
		if not live[pane] then
			blocks[pane] = nil
		end
	end
	local shown_blocks = next(blocks) ~= nil
	if not shown_blocks and not player.is_running() and player.state() == nil and not yt.fresh((yt.read())) then
		beat = nil
		return false
	end
	player.check_tools()
	local latest = player.poll(shown_blocks)
	-- While this poll runs it can act on a failed track, so the bridge
	-- should hold the queue after a failure; it releases on stop.
	player.set_fallback_hold(latest ~= nil)
	if latest ~= nil then
		if latest.url ~= "" then
			player.load_cover(latest.url, share_art)
		end
		if latest.err ~= "" and latest.err ~= shown_err then
			shown_err = latest.err
			for _, block in blocks do
				block.context:toast("error", "Music Player", latest.err)
			end
		end
	end
	local note = player.take_exit_note()
	if note ~= nil then
		for _, block in blocks do
			block.context:toast("info", "Music Player", note)
		end
	end
	queue = player.queue()
	if next(blocks) == nil then
		return true
	end
	-- Covers of the recommendation cards: missing ones start fetching, the
	-- ready ones are sent as blobs, the ones no card shows are dropped.
	local wanted: { [string]: boolean } = {}
	for _, track in player.recommendations() do
		wanted[track.url] = true
	end
	for _, block in blocks do
		share_covers(block, wanted)
	end
	local now = tern.now()
	for _, block in blocks do
		if block.state.flash_until > 0 and now > block.state.flash_until then
			block.state.flash = ""
			block.state.flash_until = 0
		end
		if block.confirm ~= nil and now > block.confirm_until then
			block.confirm = nil
		end
		if block.focus_at ~= nil and now >= block.focus_at then
			block.focus_at = nil
			local focus_id = block.focus_id
			block.focus_id = nil
			if focus_id ~= nil then
				block.context:frame({ { "focus", focus_id } })
			end
		end
		if block.search_at ~= nil and now >= block.search_at then
			block.search_at = nil
			start_search(block)
		end
		local mark = signature(block)
		if mark ~= block.rendered then
			block.rendered = mark
			block.context:render()
		end
	end
	return true
end

local function start_loop(): ()
	if beat == nil then
		beat = sched.every(POLL_MS, function(_cx: any): boolean?
			return poll_once()
		end)
	end
end

-- Keys and events -------------------------------------------------------

-- Keys that work wherever no text field has the focus.
local function key_global(block: Block, k: Key): boolean
	local name = k.name
	if name == "space" or name == "k" then
		toggle_play(block)
	elseif name == "n" then
		next_track(block)
	elseif name == "p" then
		previous_track(block)
	elseif name == "[" then
		seek_by(block, -SEEK_STEP_S)
	elseif name == "]" then
		seek_by(block, SEEK_STEP_S)
	elseif name == "+" or name == "=" or name == "equal" or name == "plus" then
		bump_volume(block, VOLUME_STEP)
	elseif name == "-" or name == "_" or name == "minus" then
		bump_volume(block, -VOLUME_STEP)
	elseif name == "m" then
		toggle_mute(block)
	elseif name == "s" then
		toggle_shuffle(block)
	elseif name == "r" then
		cycle_loop(block)
	elseif name == "a" then
		toggle_autoplay(block)
	elseif name == "/" then
		show_tab(block, "search")
	elseif name == "1" then
		show_tab(block, "home")
	elseif name == "2" then
		show_tab(block, "search")
	elseif name == "3" then
		show_tab(block, "queue")
	elseif name == "4" then
		show_tab(block, "library")
	else
		return false
	end
	return true
end

local function key_home(block: Block, k: Key): boolean
	local state = block.state
	local recs = player.recommendations()
	local history = player.history()
	local recent_count = math.min(#history, RECENT_LIMIT)
	if k.name == "left" or k.name == "right" then
		if #recs == 0 then
			return false
		end
		state.home_focus = "recs"
		local step = if k.name == "left" then -1 else 1
		state.sel_rec = math.clamp(state.sel_rec + step, 1, #recs)
	elseif k.name == "up" or k.name == "down" then
		if recent_count == 0 then
			return false
		end
		if state.home_focus ~= "recent" then
			state.home_focus = "recent"
		else
			local step = if k.name == "up" then -1 else 1
			state.sel_recent = math.clamp(state.sel_recent + step, 1, recent_count)
		end
	elseif k.name == "enter" or k.name == "e" then
		local track: Track? = if state.home_focus == "recent"
			then history[math.clamp(state.sel_recent, 1, math.max(recent_count, 1))]
			else recs[math.clamp(state.sel_rec, 1, math.max(#recs, 1))]
		if track == nil then
			return false
		end
		if k.name == "e" or k.shift then
			enqueue_track(block, track)
		else
			play_track(block, track)
		end
	else
		return key_global(block, k)
	end
	return true
end

local function key_queue(block: Block, k: Key): boolean
	local state = block.state
	local count = #queue
	if k.name == "left" then
		seek_by(block, -SEEK_STEP_S)
	elseif k.name == "right" then
		seek_by(block, SEEK_STEP_S)
	elseif k.name == "up" then
		state.sel_queue = math.max(1, state.sel_queue - 1)
	elseif k.name == "down" then
		state.sel_queue = math.min(math.max(count, 1), state.sel_queue + 1)
	elseif k.name == "home" then
		state.sel_queue = 1
	elseif k.name == "end" then
		state.sel_queue = math.max(count, 1)
	elseif k.name == "enter" then
		jump_to(block, state.sel_queue - 1)
	elseif k.name == "d" or k.name == "delete" or k.name == "backspace" then
		remove_at(block, state.sel_queue - 1)
	elseif k.name == "c" then
		clear_queue(block)
	else
		return key_global(block, k)
	end
	return true
end

local function selected_result(state: State): SearchItem?
	local visible = filtered_results(state)
	if #visible == 0 then
		return nil
	end
	return visible[math.clamp(state.sel_search, 1, #visible)]
end

local function key_results(block: Block, k: Key): boolean?
	local state = block.state
	local visible = filtered_results(state)
	if k.name == "up" then
		state.sel_search = math.max(1, state.sel_search - 1)
	elseif k.name == "down" then
		state.sel_search = math.min(math.max(#visible, 1), state.sel_search + 1)
	elseif k.name == "pageup" or k.name == "pgup" then
		state.sel_search = math.max(1, state.sel_search - 10)
	elseif k.name == "pagedown" or k.name == "pgdn" then
		state.sel_search = math.min(math.max(#visible, 1), state.sel_search + 10)
	elseif k.name == "enter" then
		local result = selected_result(state)
		if result == nil then
			return false
		end
		local track = to_track(result)
		if track ~= nil and (k.shift or k.ctrl or k.meta) then
			enqueue_track(block, track)
		else
			open_result(block, result)
		end
	else
		return nil
	end
	return true
end

local function key_search(block: Block, k: Key): boolean?
	local state = block.state
	local handled = key_results(block, k)
	if handled ~= nil then
		return handled
	end
	if k.name == "escape" then
		if block.origin_category ~= nil then
			back_to_results(block)
		elseif state.query ~= "" then
			block.search_seq += 1
			block.searching = false
			state.query = ""
			state.cursor = 0
			state.results = {}
			block.search_at = nil
		else
			show_tab(block, "home")
		end
		return true
	end
	return edit_query(block, k)
end

local function key_artist(block: Block, k: Key): boolean?
	local state = block.state
	local handled = key_results(block, k)
	if handled ~= nil then
		return handled
	end
	if k.name == "escape" then
		if state.artist_filter ~= "" then
			state.artist_filter = ""
			state.artist_cursor = 0
			state.sel_search = 1
		else
			state.mode = "search"
			focus_later(block, QUERY_ID)
		end
		return true
	end
	return edit_artist_filter(state, k)
end

local function key_playlist_name(block: Block, k: Key): boolean?
	if k.name == "enter" then
		save_playlist(block, "queue")
		return true
	elseif k.name == "escape" then
		block.state.mode = "library"
		return true
	end
	return edit_playlist_name(block.state, k)
end

local function key_library(block: Block, k: Key): boolean
	local state = block.state
	local count = #player.playlists()
	if k.name == "up" then
		state.sel_playlist = math.max(1, state.sel_playlist - 1)
	elseif k.name == "down" then
		state.sel_playlist = math.min(math.max(count, 1), state.sel_playlist + 1)
	elseif k.name == "enter" then
		play_playlist(block, state.sel_playlist)
	elseif k.name == "e" then
		enqueue_playlist(block, state.sel_playlist)
	elseif k.name == "d" or k.name == "delete" then
		delete_playlist(block, state.sel_playlist)
	else
		return key_global(block, k)
	end
	return true
end

-- The 1-based index at the end of a node id such as `main.search.results.r3`.
local function index_in(id: any, letter: string): number?
	if type(id) ~= "string" then
		return nil
	end
	local digits = string.match(id, "%." .. letter .. "(%d+)$")
	return if digits == nil then nil else tonumber(digits)
end

local function recent_track(index: number?): Track?
	if index == nil or index > RECENT_LIMIT then
		return nil
	end
	return player.history()[index]
end

-- A context-menu pick: `act` is the entry, `id` the node it was opened on.
local function on_menu(block: Block, act: string, id: any): boolean
	local state = block.state
	local track: Track? = nil
	local result_index = index_in(id, "r")
	local card_index = index_in(id, "c")
	local recent_index = index_in(id, "h")
	local queue_index = index_in(id, "q")
	local playlist_index = index_in(id, "p")
	if result_index ~= nil then
		local result = filtered_results(state)[result_index]
		if result == nil then
			return true
		end
		state.sel_search = result_index
		if act == "Open" or result.kind ~= "track" then
			open_result(block, result)
			return true
		end
		track = to_track(result)
	elseif card_index ~= nil then
		state.sel_rec = card_index
		state.home_focus = "recs"
		track = player.recommendations()[card_index]
	elseif recent_index ~= nil then
		state.sel_recent = recent_index
		state.home_focus = "recent"
		track = recent_track(recent_index)
	elseif queue_index ~= nil then
		state.sel_queue = queue_index
		if act == "Remove" then
			remove_at(block, queue_index - 1)
		else
			jump_to(block, queue_index - 1)
		end
		return true
	elseif playlist_index ~= nil then
		state.sel_playlist = playlist_index
		if act == "Delete" then
			delete_playlist(block, playlist_index)
		elseif act == "Add to queue" then
			enqueue_playlist(block, playlist_index)
		else
			play_playlist(block, playlist_index)
		end
		return true
	else
		return false
	end
	if track == nil then
		return true
	end
	if act == "Play next" then
		play_next(block, track)
	elseif act == "Add to queue" then
		enqueue_track(block, track)
	else
		play_track(block, track)
	end
	return true
end

local function on_action(block: Block, state: State, act: string, raw: string?): ()
	if act == "category" and raw ~= nil then
		if raw == "tracks" or raw == "artists" or raw == "playlists" or raw == "podcasts" then
			set_category(block, raw :: SearchCategory)
			focus_later(block, QUERY_ID)
		end
	elseif act == "back-results" then
		back_to_results(block)
	elseif act == "play-pause" then
		toggle_play(block)
	elseif act == "next" then
		next_track(block)
	elseif act == "prev" then
		previous_track(block)
	elseif act == "shuffle" then
		toggle_shuffle(block)
	elseif act == "loop" then
		cycle_loop(block)
	elseif act == "mute" then
		toggle_mute(block)
	elseif act == "volume-up" then
		bump_volume(block, VOLUME_STEP)
	elseif act == "volume-down" then
		bump_volume(block, -VOLUME_STEP)
	elseif act == "clear" then
		clear_queue(block)
	elseif act == "toggle-autoplay" then
		toggle_autoplay(block)
	elseif act == "duration" and raw ~= nil and state.category == "tracks" and (raw == "all" or raw == "short" or raw == "medium" or raw == "long") then
		state.duration_filter = raw :: DurationFilter
		state.sel_search = 1
	elseif act == "play-all" then
		local tracks = filtered_tracks(state)
		play_tracks(block, tracks, 1, string.format("Playing %d tracks", #tracks))
	elseif act == "queue-all" then
		local tracks = filtered_tracks(state)
		queue_tracks(block, tracks, string.format("Added %d tracks to the queue", #tracks))
	elseif act == "save-results" then
		save_playlist(block, "results")
	elseif act == "save-queue" then
		save_playlist(block, "queue")
	elseif act == "save-queue-as" then
		state.mode = "playlist-name"
		focus_later(block, NAME_ID)
		say(block, "Name the playlist, then press enter")
	elseif act == "play-playlist" then
		play_playlist(block, state.sel_playlist)
	elseif act == "queue-playlist" then
		enqueue_playlist(block, state.sel_playlist)
	elseif act == "delete-playlist" then
		delete_playlist(block, state.sel_playlist)
	elseif act == "refresh-recs" then
		player.refresh_recommendations()
	elseif raw ~= nil and act == "rec" then
		local index = tonumber(raw) or 0
		local track = player.recommendations()[index]
		if track ~= nil then
			state.sel_rec = index
			state.home_focus = "recs"
			play_track(block, track)
		end
	end
end

-- A click (`select`) or double-click (`activate`) on a list row.
local function on_row(block: Block, ev: UiEvent): ()
	local state = block.state
	local activate = ev.ev == "activate"
	local item = ev.item
	local result_index = index_in(item, "r")
	local queue_index = index_in(item, "q")
	local playlist_index = index_in(item, "p")
	local recent_index = index_in(item, "h")
	if result_index ~= nil then
		state.sel_search = result_index
		if activate then
			local result = filtered_results(state)[result_index]
			if result ~= nil then
				open_result(block, result)
			end
		end
	elseif queue_index ~= nil then
		state.sel_queue = queue_index
		if state.mode ~= "queue" then
			state.mode = "queue"
		end
		if activate then
			jump_to(block, queue_index - 1)
		end
	elseif playlist_index ~= nil then
		state.sel_playlist = playlist_index
		state.mode = "library"
		if activate then
			play_playlist(block, playlist_index)
		end
	elseif recent_index ~= nil then
		state.sel_recent = recent_index
		state.home_focus = "recent"
		state.mode = "home"
		if activate then
			local track = recent_track(recent_index)
			if track ~= nil then
				play_track(block, track)
			end
		end
	end
end

-- The block -------------------------------------------------------------

local MODES: { [string]: Mode } = {
	home = "home",
	search = "search",
	["artist-filter"] = "artist-filter",
	queue = "queue",
	library = "library",
	["playlist-name"] = "playlist-name",
}

local player_block: BlockDef<State> = {
	init = function(cx: BlockCx, args: { string }, saved: any): State
		yt.ensure_dirs()
		local restored: any = saved
		local state: State = {
			mode = "home",
			category = "tracks",
			detail_title = "",
			query = "",
			cursor = 0,
			results = {},
			sel_search = 1,
			artist_filter = "",
			artist_cursor = 0,
			duration_filter = "all",
			playlist_name = "",
			playlist_cursor = 0,
			sel_playlist = 1,
			sel_queue = 1,
			sel_rec = 1,
			sel_recent = 1,
			home_focus = "recs",
			flash = "",
			flash_until = 0,
		}
		if type(restored) == "table" then
			if restored.category == "tracks"
				or restored.category == "artists"
				or restored.category == "playlists"
				or restored.category == "podcasts"
			then
				state.category = restored.category
			end
			if type(restored.query) == "string" then
				state.query = restored.query
				state.cursor = #state.query
			end
			local mode = MODES[if type(restored.mode) == "string" then restored.mode else ""]
			if mode ~= nil then
				state.mode = mode :: Mode
			end
			if type(restored.artist_filter) == "string" then
				state.artist_filter = restored.artist_filter
				state.artist_cursor = #state.artist_filter
			end
			if restored.duration_filter == "all"
				or restored.duration_filter == "short"
				or restored.duration_filter == "medium"
				or restored.duration_filter == "long"
			then
				state.duration_filter = restored.duration_filter
			end
			if type(restored.playlist_name) == "string" then
				state.playlist_name = restored.playlist_name
				state.playlist_cursor = #state.playlist_name
			end
			if type(restored.sel_playlist) == "number" then
				state.sel_playlist = math.max(1, math.floor(restored.sel_playlist))
			end
		end
		local focus_id = if state.mode == "playlist-name"
			then NAME_ID
			elseif state.mode == "artist-filter" then ARTIST_ID
			elseif state.mode == "search" then QUERY_ID
			else nil
		local block: Block = {
			context = cx,
			state = state,
			blob = nil,
			blob_key = nil,
			resend_at = nil,
			covers = {},
			covers_seq = 0,
			rendered = "",
			searching = false,
			search_seq = 0,
			search_at = if state.query ~= "" then tern.now() + SEARCH_DEBOUNCE_MS else nil,
			focus_at = if focus_id == nil then nil else tern.now() + FOCUS_DELAY_MS,
			focus_id = focus_id,
			optimistic = {},
			origin_category = nil,
			origin_query = nil,
			confirm = nil,
			confirm_until = 0,
		}
		blocks[cx.pane] = block
		start_loop()
		-- Launch arguments are a first-run thing: a reload or a daemon restart
		-- passes them again, and replaying them would restart the queue.
		local first = if restored == nil then args[1] else nil
		if first ~= nil and first ~= "" then
			if yt.is_playable_url(first) then
				play_track(block, {
					url = first,
					video = yt.youtube_id(first) or "",
					title = first,
					artist = "",
					duration = nil,
				})
				state.mode = "queue"
				block.focus_at = nil
				block.focus_id = nil
			else
				state.mode = "search"
				state.query = first
				state.cursor = #first
				block.search_at = tern.now() + SEARCH_DEBOUNCE_MS
				focus_later(block, QUERY_ID)
			end
		end
		player.ensure()
		return state
	end,

	title = function(_state: State): string?
		local p = player.state()
		if p ~= nil and p.title ~= "" then
			return yt.cut(p.title, 48)
		end
		return "Music Player"
	end,

	view = function(state: State, cx: BlockCx): BlockView
		local block = blocks[cx.pane]
		if block == nil then
			return { main = ui.col({ ui.text({ ui.span("This block has ended", "muted") }) }) }
		end
		local p = shown(block)
		local children: { Node } = {}
		local problem = problem_card()
		if problem ~= nil then
			table.insert(children, problem)
		end
		table.insert(children, now_playing(block, p, cx))
		table.insert(children, tabs_node(state))
		local tab = tab_of(state.mode)
		if tab == "search" then
			table.insert(children, search_page(block, state, cx))
		elseif tab == "queue" then
			table.insert(children, queue_page(block, state, p, cx))
		elseif tab == "library" then
			table.insert(children, library_page(block, state, cx))
		else
			table.insert(children, home_page(block, state, cx))
		end
		return { main = with(ui.col(children), { role = "ytm-main" }), dock = dock(state, cx) }
	end,

	key = function(state: State, k: Key, cx: BlockCx): boolean?
		local block = blocks[cx.pane]
		if block == nil then
			return false
		end
		if k.name == "tab" then
			cycle_tab(block, if k.shift then -1 else 1)
			return true
		end
		local mode = state.mode
		if mode == "search" then
			return key_search(block, k)
		elseif mode == "artist-filter" then
			return key_artist(block, k)
		elseif mode == "playlist-name" then
			return key_playlist_name(block, k)
		elseif mode == "library" then
			return key_library(block, k)
		elseif mode == "queue" then
			return key_queue(block, k)
		end
		return key_home(block, k)
	end,

	event = function(state: State, ev: UiEvent, cx: BlockCx): ()
		local block = blocks[cx.pane]
		if block == nil then
			return
		end
		if ev.ev == "focus" then
			if ev.id == QUERY_ID then
				state.mode = "search"
			elseif ev.id == ARTIST_ID then
				state.mode = "artist-filter"
			elseif ev.id == NAME_ID then
				state.mode = "playlist-name"
			end
			if ev.id ~= nil then
				cx:frame({ { "focus", ev.id } })
			end
			return
		end
		if ev.ev == "select" and ev.id == TABS_ID then
			local item = ev.item
			if item == "home" or item == "search" or item == "queue" or item == "library" then
				show_tab(block, item :: Tab)
			end
			return
		end
		if ev.ev == "select" or ev.ev == "activate" then
			on_row(block, ev)
			return
		end
		if ev.ev ~= "action" then
			return
		end
		local act = ev.act
		if type(act) ~= "string" then
			return
		end
		if act == "Play" or act == "Play next" or act == "Add to queue" or act == "Remove" or act == "Delete" or act == "Open" then
			if on_menu(block, act, ev.id) then
				return
			end
		end
		on_action(block, state, act, ev.value)
	end,

	save = function(state: State): any
		return {
			query = state.query,
			mode = state.mode,
			category = state.category,
			artist_filter = state.artist_filter,
			duration_filter = state.duration_filter,
			playlist_name = state.playlist_name,
			sel_playlist = state.sel_playlist,
		}
	end,
}

tern.block.define("player", player_block)

-- After a reload with the player still running and no block open, the poll
-- loop is the plugin's daemon (history, autoplay, failed-track replacement):
-- start it now instead of waiting for a block.
if yt.fresh((yt.read())) then
	start_loop()
end
