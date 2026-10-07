--!strict
-- YouTube Music: the host half, the `ytmusic.player` block.
--
-- A block is a picture of state that lives elsewhere: mpv owns the playlist,
-- `mpv/bridge.lua` writes it to files, `src/player.luau` reads and commands it,
-- and everything here turns that into a view and into commands.
--
-- The player outlives the block on purpose: closing the pane keeps the music
-- playing, the window half's status line shows the track and its palette
-- commands keep controlling it. Blocks have no close hook, so the poll loop
-- drops panes it no longer sees in `tern.pane.list()`.

local yt = require("./ytmusic")
local player = require("./player")

local ui = tern.ui

local SEARCH_DEBOUNCE_MS = 400
local POLL_MS = 500
local OPTIMISTIC_MS = 2500
local FLASH_MS = 4000
local SEEK_STEP_S = 10
local VOLUME_STEP = 5
local FOCUS_DELAY_MS = 250
local FOCUS_ID = "main.search.field.query"
local COVER_RESEND_MS = 1500
local MAX_QUEUE_VIEW = 12

type Track = player.Track
type Mode = "search" | "queue" | "playlist-name" | "artist-filter" | "library"
type DurationFilter = "all" | "short" | "medium" | "long"

type State = {
	mode: Mode,
	query: string,
	cursor: number,
	results: { Track },
	sel_search: number,
	artist_filter: string,
	artist_cursor: number,
	duration_filter: DurationFilter,
	playlist_name: string,
	playlist_cursor: number,
	sel_playlist: number,
	sel_queue: number,
	flash: string,
	flash_until: number,
}

type Block = {
	context: BlockCx,
	state: State,
	blob: string?,
	blob_key: string?,
	resend_at: number?,
	rendered: string,
	searching: boolean,
	search_seq: number,
	search_at: number?,
	focus_at: number?,
	focus_id: string?,
	optimistic: { [string]: { value: any, expires: number } },
}

local blocks: { [number]: Block } = {}
local queue: { yt.Flat } = {}
local shown_err: string? = nil
local loop: TimerHandle? = nil

local function with(node: Node, props: { [string]: any }): Node
	local merged: { [string]: any } = node.p or {}
	for key, value in props do
		merged[key] = value
	end
	node.p = merged
	return node
end

local function clickable(node: Node, click: string, role: string?): Node
	local name = if role == nil then "ytm-act" else "ytm-act " .. role
	return with(node, { role = name, actions = { click = click } })
end

local function say(block: Block, message: string): ()
	block.state.flash = message
	block.state.flash_until = tern.now() + FLASH_MS
	block.rendered = ""
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
		title = p.title,
		artist = p.artist,
		video = p.video,
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
		say(block, "The queue is empty: search, then press enter on a result")
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

local function seek_by(block: Block, seconds: number): ()
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

local function play_track(block: Block, track: Track): ()
	player.request("play", track.url, track.video, track.title, track.artist)
	expect(block, "state", "starting")
	block.state.mode = "queue"
	block.state.sel_queue = 1
	say(block, "Playing " .. yt.cut(track.title, 60))
end

local function enqueue_track(block: Block, track: Track): ()
	player.request("enqueue", track.url, track.video, track.title, track.artist)
	say(block, "Queued " .. yt.cut(track.title, 60))
end

local function filtered_results(state: State): { Track }
	local needle = string.lower(string.match(state.artist_filter, "^%s*(.-)%s*$") or "")
	local visible: { Track } = {}
	for _, track in state.results do
		local duration = track.duration
		local duration_matches = if state.duration_filter == "short"
			then duration ~= nil and duration < 300
			elseif state.duration_filter == "medium"
			then duration ~= nil and duration >= 300 and duration < 1200
			elseif state.duration_filter == "long"
			then duration ~= nil and duration >= 1200
			else true
		local artist_matches = needle == "" or string.find(string.lower(track.artist), needle, 1, true) ~= nil
		if duration_matches and artist_matches then
			table.insert(visible, track)
		end
	end
	return visible
end

local function play_tracks(block: Block, tracks: { Track }, from: number, message: string): ()
	if #tracks == 0 then
		say(block, "No tracks to play")
		return
	end
	local start = math.clamp(from, 1, #tracks)
	player.request("clear")
	for _, track in tracks do
		player.request("enqueue", track.url, track.video, track.title, track.artist)
	end
	player.request("jump", tostring(start - 1))
	expect(block, "state", "starting")
	block.state.mode = "queue"
	block.state.sel_queue = start
	say(block, message)
end

local function queue_tracks(block: Block, tracks: { Track }, message: string): ()
	if #tracks == 0 then
		say(block, "No tracks to add")
		return
	end
	for _, track in tracks do
		player.request("enqueue", track.url, track.video, track.title, track.artist)
	end
	say(block, message)
end


local function save_playlist(block: Block, source: "results" | "queue"): ()
	local name = string.match(block.state.playlist_name, "^%s*(.-)%s*$") or ""
	local tracks: { Track } = {}
	if source == "results" then
		tracks = filtered_results(block.state)
	else
		for _, row in queue do
			table.insert(tracks, {
				url = row.url,
				video = row.video,
				title = row.title,
				artist = row.artist,
				duration = nil,
			})
		end
	end
	local ok, failure = player.save_playlist(name, tracks)
	if not ok then
		say(block, failure or "Could not save the playlist")
		return
	end
	block.state.sel_playlist = #player.playlists()
	say(block, string.format("Saved %d tracks to %s", #tracks, name))
end

local function delete_playlist(block: Block): ()
	local ok, failure = player.delete_playlist(block.state.sel_playlist)
	if not ok then
		say(block, failure or "Could not delete the playlist")
		return
	end
	block.state.sel_playlist = math.max(1, math.min(block.state.sel_playlist, #player.playlists()))
	say(block, "Playlist deleted")
end

local function play_all(block: Block, from: number): ()
	local tracks = filtered_results(block.state)
	play_tracks(block, tracks, from, string.format("Playing %d filtered tracks", #tracks))
end

local function play_selected_playlist(block: Block): ()
	local saved = player.playlists()[block.state.sel_playlist]
	if saved == nil then
		say(block, "Select a playlist first")
		return
	end
	play_tracks(block, saved.tracks, 1, "Playing playlist " .. yt.cut(saved.name, 48))
end

local function enqueue_selected_playlist(block: Block): ()
	local saved = player.playlists()[block.state.sel_playlist]
	if saved == nil then
		say(block, "Select a playlist first")
		return
	end
	queue_tracks(block, saved.tracks, string.format("Added %d tracks from %s", #saved.tracks, yt.cut(saved.name, 36)))
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
	player.request("clear")
	say(block, "The queue is cleared")
end

local function focus_input(block: Block, mode: Mode, id: string): ()
	block.state.mode = mode
	block.focus_id = id
	block.focus_at = tern.now() + FOCUS_DELAY_MS
end

local function focus_search(block: Block): ()
	focus_input(block, "search", FOCUS_ID)
end

-- Search ----------------------------------------------------------------

local function start_search(block: Block): ()
	local query = block.state.query
	if query == "" then
		block.state.results = {}
		block.searching = false
		block.rendered = ""
		return
	end
	block.search_seq += 1
	local seq = block.search_seq
	block.searching = true
	block.rendered = ""
	player.search(query, function(tracks: { Track }, err: string?)
		local live = blocks[block.context.pane]
		if live ~= block or block.search_seq ~= seq then
			return
		end
		block.searching = false
		if err ~= nil then
			say(block, "yt-dlp failed: " .. err)
		else
			block.state.results = tracks
			block.state.sel_search = 1
		end
		block.rendered = ""
		block.context:render()
	end)
end

local function edit_text(text: string, cursor: number, k: Key): (string, number, boolean)
	if k.name == "paste" and k.text ~= nil then
		text = text:sub(1, cursor) .. k.text .. text:sub(cursor + 1)
		cursor += #k.text
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

-- View ------------------------------------------------------------------

local function badge_row(p: yt.Player?): Node
	local chips: { Node } = {}
	if p == nil then
		table.insert(chips, with(ui.badge(if player.is_running() then "starting" else "stopped", "muted"), { key = "state" }))
	else
		local label = if p.state == "starting" then "loading" else p.state
		table.insert(chips, with(ui.badge(label, if p.state == "playing" then "accent" else "muted"), { key = "state" }))
		table.insert(chips, with(ui.badge(tostring(math.floor(p.volume + 0.5)) .. "%", "muted"), { key = "volume" }))
		if p.count > 0 then
			local count = if p.index >= 0
				then string.format("%d/%d", p.index + 1, p.count)
				else tostring(p.count) .. " queued"
			table.insert(chips, with(ui.badge(count, "muted"), { key = "count" }))
		end
		if p.mute then
			table.insert(chips, with(ui.badge("muted", "warning"), { key = "mute" }))
		end
		if p.loop ~= "off" then
			table.insert(chips, with(ui.badge("repeat " .. p.loop, "muted"), { key = "loop" }))
		end
		if p.shuffle then
			table.insert(chips, with(ui.badge("shuffle", "muted"), { key = "shuffle" }))
		end
	end
	local autoplay = player.autoplay()
	table.insert(chips, clickable(ui.badge(if autoplay then "autoplay on" else "autoplay off", if autoplay then "accent" else "muted"), "toggle-autoplay", "ytm-autoplay"))
	return with(ui.row(chips), { key = "chips", role = "ytm-chips" })
end

local function hero(block: Block, p: yt.Player?, cx: BlockCx): Node
	local track: yt.Flat? = nil
	if p ~= nil and p.index >= 0 and p.index < #queue then
		track = queue[p.index + 1]
	end
	local art = player.art()
	local cover: Node
	if block.blob ~= nil and art.key ~= nil and block.blob_key == art.key then
		cover = with(ui.node("image", { blob = block.blob, alt = "Cover", w = 176, h = 176 }), {
			key = "art",
			role = "ytm-cover",
		})
	else
		cover = with(ui.node("icon", { name = "wave" }), { key = "art", role = "ytm-cover ytm-cover-empty" })
	end
	local title = "Nothing playing"
	if p ~= nil and p.title ~= "" then
		title = p.title
	elseif track ~= nil and track.title ~= "" then
		title = track.title
	end
	local artist = ""
	if p ~= nil and p.artist ~= "" then
		artist = p.artist
	elseif track ~= nil then
		artist = track.artist
	end
	local meta: { Node } = {
		with(ui.text({ ui.span(yt.cut(title, 80), "strong") }), { key = "title", role = "ytm-title" }),
	}
	if artist ~= "" then
		table.insert(meta, with(ui.text({ ui.span(yt.cut(artist, 80), "muted") }), { key = "artist", role = "ytm-artist" }))
	end
	table.insert(meta, badge_row(p))
	local kids: { Node } = { cover, with(ui.col(meta), { key = "meta", grow = 1 }) }
	local narrow = cx.cols < 64
	return with(if narrow then ui.col(kids) else ui.row(kids), {
		key = "hero",
		role = if narrow then "ytm-hero ytm-hero-narrow" else "ytm-hero",
	})
end

local function progress_row(p: yt.Player?): Node
	local position = if p == nil then 0 else p.pos
	local total = if p == nil then nil else p.duration
	local fill: number? = nil
	if total ~= nil and total > 0 then
		fill = math.max(0, math.min(1, position / total))
	end
	-- The times sit beside the bar, so the bar itself needs no label.
	return with(ui.row({
		with(ui.text({ ui.span(yt.clock(position), "muted num") }), {
			key = "at",
			role = "ytm-time",
			min = { w = "5ch" },
		}),
		with(ui.progress(fill, ""), { key = "bar", role = "ytm-bar", grow = 1 }),
		with(ui.text({ ui.span(yt.clock(total), "muted num") }), {
			key = "len",
			role = "ytm-time",
			min = { w = "5ch" },
		}),
	}), { key = "progress", role = "ytm-progress" })
end

local function control_row(p: yt.Player?): Node
	local live = p ~= nil
	local shuffle_on = p ~= nil and p.shuffle
	local has_queue = p ~= nil and p.count > 0
	local playing_now = p ~= nil and p.state == "playing"
	local muted = p ~= nil and p.mute
	local looping = p ~= nil and p.loop ~= "off"
	return with(ui.row({
		clickable(ui.node("icon", { name = "swap", tone = if shuffle_on then "accent" else nil }), "shuffle", "ytm-shuffle"),
		clickable(ui.node("icon", { name = "frame-prev" }), "prev", "ytm-prev"),
		clickable(ui.node("icon", { name = if playing_now then "pause" else "play" }), "play-pause", "ytm-play"),
		clickable(ui.node("icon", { name = "frame-next" }), "next", "ytm-next"),
		clickable(ui.node("icon", { name = "repeat", tone = if looping then "accent" else nil }), "loop", "ytm-repeat"),
		clickable(ui.node("icon", { name = if muted then "slash-circle" else "wave" }), "mute", "ytm-mute"),
		clickable(ui.node("icon", { name = "minus" }), "volume-down", "ytm-volume"),
		clickable(ui.node("icon", { name = "plus" }), "volume-up", "ytm-volume"),
		clickable(ui.node("icon", { name = "search" }), "focus-search", "ytm-focus"),
		clickable(ui.node("icon", { name = "trash", tone = if live and has_queue then nil else "muted" }), "clear", "ytm-clear"),
	}), { key = "controls", role = "ytm-controls" })
end

local function search_section(block: Block, state: State): Node
	local visible = filtered_results(state)
	local items: { Item } = {}
	for index, track in visible do
		items[index] = {
			label = if track.title ~= "" then track.title else track.url,
			detail = if track.artist ~= "" then track.artist else nil,
			value = yt.clock(track.duration),
		}
	end
	local list = ui.list(items)
	local children: { Node } = list.c or {}
	for index, child in children do
		with(child, {
			key = "r" .. tostring(index),
			actions = { click = "play=" .. tostring(index), dblclick = "queue=" .. tostring(index) },
		})
	end
	local selected: string? = nil
	if #visible > 0 then
		selected = "main.search.results.r" .. tostring(math.clamp(state.sel_search, 1, #visible))
	end
	list.p = {
		key = "results",
		selected = selected,
		max = { lines = 8 },
		empty = {
			ui.span(
				if block.searching
					then "Searching YouTube…"
					elseif #state.results > 0
					then "No results match these filters"
					else "Search for a track to get started",
				"muted"
			),
		},
	}

	local head: { Span } = { ui.span("Search", "strong") }
	if block.searching then
		table.insert(head, ui.span("  searching", "muted"))
	end
	if #state.results > 0 then
		table.insert(head, ui.span(string.format("  %d of %d tracks", #visible, #state.results), "muted"))
	end

	local query_input = with(ui.node("input", {
		key = "query",
		text = state.query,
		cursor = yt.units_for_bytes(state.query, state.cursor),
		placeholder = "Search YouTube…",
	}), { grow = 1 })
	local search_buttons = with(ui.row({
		clickable(ui.badge("Add selected", "muted"), "enqueue-selected"),
		clickable(ui.badge("Play all", "accent"), "play-all"),
	}), { key = "buttons", role = "ytm-search-buttons" })

	local duration_filter = state.duration_filter
	local function duration_chip(id: DurationFilter, label: string): Node
		return clickable(ui.badge(label, if duration_filter == id then "accent" else "muted"), "duration=" .. id, "ytm-filter-chip")
	end
	local channel_input = with(ui.node("input", {
		key = "artist",
		text = state.artist_filter,
		cursor = yt.units_for_bytes(state.artist_filter, state.artist_cursor),
		placeholder = "Filter by artist or channel",
	}), { grow = 1 })

	return with(ui.section(head, {
		with(ui.row({ query_input, search_buttons }), { key = "field", role = "ytm-search-field" }),
		with(ui.row({
			duration_chip("all", "Any length"),
			duration_chip("short", "Under 5 min"),
			duration_chip("medium", "5–20 min"),
			duration_chip("long", "20+ min"),
		}), { key = "duration-filters", role = "ytm-filter-row" }),
		with(ui.row({ channel_input }), { key = "filters", role = "ytm-channel-filter" }),
		list,
	}), { key = "search", role = "ytm-search", collapsible = true })
end

local function queue_section(state: State, p: yt.Player?): Node
	local items: { Item } = {}
	for index, row in queue do
		local playing_row = p ~= nil and p.index == row.index
		items[index] = {
			label = if row.title ~= "" then row.title else row.url,
			detail = if row.artist ~= "" then row.artist else nil,
			icon = if playing_row then "play" else nil,
			tone = if playing_row then "accent" else nil,
		}
	end
	local list = ui.list(items)
	local children: { Node } = list.c or {}
	for index, child in children do
		with(child, { key = "q" .. tostring(index), actions = { click = "jump=" .. tostring(index) } })
	end
	local selected: string? = nil
	if #queue > 0 then
		selected = "main.queue.list.q" .. tostring(math.clamp(state.sel_queue, 1, #queue))
	end
	list.p = {
		key = "list",
		selected = selected,
		max = { lines = MAX_QUEUE_VIEW },
		empty = { ui.span("The queue is empty: search, then press enter on a result", "muted") },
	}
	local head: { Span } = {
		ui.span("Queue", "strong"),
		ui.span("  " .. tostring(#queue) .. " tracks", "muted"),
	}
	if p ~= nil and p.index >= 0 then
		table.insert(head, ui.span(string.format("  %d/%d current", p.index + 1, p.count), "muted"))
	end
	return with(ui.section(head, { list }), { key = "queue", role = "ytm-queue", collapsible = true })
end

local function playlists_section(state: State): Node
	local saved = player.playlists()
	local items: { Item } = {}
	for index, playlist in saved do
		items[index] = {
			label = playlist.name,
			detail = tostring(#playlist.tracks) .. " tracks",
			icon = "wave",
		}
	end
	local list = ui.list(items)
	local children: { Node } = list.c or {}
	for index, child in children do
		with(child, { key = "p" .. tostring(index) })
	end
	local selected: string? = nil
	if #saved > 0 then
		selected = "main.library.list.p" .. tostring(math.clamp(state.sel_playlist, 1, #saved))
	end
	list.p = {
		key = "list",
		selected = selected,
		max = { lines = 6 },
		empty = { ui.span("Save search results or the current queue to build a playlist", "muted") },
	}

	local name_input = with(ui.node("input", {
		key = "name",
		text = state.playlist_name,
		cursor = yt.units_for_bytes(state.playlist_name, state.playlist_cursor),
		placeholder = "Playlist name",
	}), { grow = 1 })
	local save_buttons = with(ui.row({
		clickable(ui.badge("Save results", "muted"), "save-results"),
		clickable(ui.badge("Save queue", "muted"), "save-queue"),
	}), { key = "save-buttons", role = "ytm-playlist-save" })
	local playlist_buttons = with(ui.row({
		clickable(ui.badge("Play", "accent"), "play-playlist"),
		clickable(ui.badge("Add to queue", "muted"), "queue-playlist"),
		clickable(ui.badge("Delete", "warning"), "delete-playlist"),
	}), { key = "playlist-buttons", role = "ytm-playlist-actions" })

	local body: { Node } = {
		with(ui.row({ name_input, save_buttons }), { key = "form", role = "ytm-playlist-form" }),
		list,
		playlist_buttons,
	}
	local problem = player.preferences_problem()
	if problem ~= nil then
		table.insert(body, ui.text({ ui.span("Playlist storage unavailable: " .. yt.cut(problem, 100), "error") }))
	end
	return with(ui.section({
		ui.span("Playlists", "strong"),
		ui.span("  " .. tostring(#saved), "muted"),
	}, body), { key = "library", role = "ytm-library", collapsible = true })
end

local function problem_card(): Node?
	local problem = player.problem()
	if problem == nil then
		return nil
	end
	return with(ui.card({ ui.span("The player cannot run", "strong error") }, {
		ui.text({ ui.span(problem, "error") }),
		ui.text({
			ui.span("winget install mpv yt-dlp   ·   brew install mpv yt-dlp   ·   sudo apt install mpv yt-dlp", "muted"),
		}),
		ui.text({ ui.span("The player's files, mpv.log included, sit in the plugin's data directory.", "muted") }),
	}), { key = "problem", tone = "error" })
end

local function hints(state: State, cx: BlockCx): Node
	local narrow = cx.cols < 64
	local spans: { Span } = {}
	local function key(label: string, description: string): ()
		if #spans > 0 then
			table.insert(spans, ui.span("   ", "dim"))
		end
		table.insert(spans, ui.span(label, "key"))
		table.insert(spans, ui.span(" " .. description, "dim"))
	end
	if state.mode == "search" then
		key("type", "search")
		key("↑↓", "pick results")
		key("enter", "play")
		key("tab", "queue")
	elseif state.mode == "artist-filter" then
		key("type", "filter artist")
		key("↑↓", "pick results")
		key("enter", "play")
		key("tab", "queue")
	elseif state.mode == "playlist-name" then
		key("type", "playlist name")
		key("enter", "save queue")
		key("tab", "queue")
	elseif state.mode == "library" then
		key("↑↓", "pick playlist")
		key("enter", "play playlist")
		key("+", "add playlist")
		key("d", "delete playlist")
		key("tab", "queue")
	elseif narrow then
		key("space", "play")
		key("n p", "track")
		key("/", "search")
		key("l", "playlists")
		key("tab", "search")
	else
		key("space", "play")
		key("←→", "seek")
		key("n p", "track")
		key("+ -", "volume")
		key("m", "mute")
		key("s", "shuffle")
		key("r", "repeat")
		key("d", "remove")
		key("c", "clear")
		key("/", "search")
		key("l", "playlists")
	end
	return with(ui.text(spans), { key = "hints", role = "ytm-hints" })
end

local function dock(state: State, p: yt.Player?, cx: BlockCx): Node
	local lines: { Node } = {}
	if state.flash ~= "" then
		table.insert(lines, with(ui.text({ ui.span(state.flash, "muted") }), { key = "flash", role = "ytm-flash" }))
	end
	table.insert(lines, hints(state, cx))
	local status: { Span } = {}
	if player.problem() ~= nil then
		table.insert(status, ui.span("the player cannot run", "error"))
	elseif p == nil then
		table.insert(status, ui.span(if player.is_running() then "starting mpv…" else "the player is not running", "muted"))
	else
		table.insert(status, ui.span(p.state, if p.state == "playing" then "success" else "muted"))
		table.insert(status, ui.span(string.format("  ·  %d%% volume", math.floor(p.volume + 0.5)), "muted"))
		if p.err ~= "" then
			table.insert(status, ui.span("  ·  " .. p.err, "error"))
		end
	end
	table.insert(status, ui.span(if player.autoplay() then "  · autoplay on" else "  · autoplay off", "muted"))
	local autoplay_message = player.autoplay_message()
	if autoplay_message ~= "" then
		table.insert(status, ui.span("  · " .. autoplay_message, if string.find(autoplay_message, "failed", 1, true) then "error" else "muted"))
	end
	table.insert(lines, with(ui.text(status), { key = "status", role = "ytm-status" }))
	return with(ui.col(lines), { role = "ytm-dock" })
end

local function signature(block: Block): string
	local p = shown(block)
	local parts: { string } = {
		if p == nil then "none" else p.state,
		tostring(if p == nil then 0 else p.pos // 1),
		tostring(if p == nil then nil else p.duration),
		tostring(if p == nil then -1 else p.index),
		tostring(if p == nil then 0 else p.count),
		tostring(if p == nil then 0 else p.seq),
		if p == nil then "" else p.title,
		if p == nil then "" else p.artist,
		if p == nil then "" else p.video,
		if p == nil then "" else p.err,
		if p == nil then "" else tostring(p.volume),
		if p == nil then "" else tostring(p.mute),
		if p == nil then "" else p.loop,
		if p == nil then "" else tostring(p.shuffle),
		tostring(#queue),
		block.state.mode,
		block.state.query,
		tostring(block.state.cursor),
		tostring(#block.state.results),
		tostring(block.state.sel_search),
		tostring(block.state.sel_queue),
		block.state.artist_filter,
		tostring(block.state.artist_cursor),
		block.state.duration_filter,
		block.state.playlist_name,
		tostring(block.state.playlist_cursor),
		tostring(block.state.sel_playlist),
		tostring(#player.playlists()),
		tostring(player.autoplay()),
		player.autoplay_message(),
		tostring(player.preferences_problem()),
		block.state.flash,
		tostring(block.searching),
		tostring(block.blob_key),
		tostring(player.problem()),
		tostring(player.is_running()),
	}
	return table.concat(parts, "|")
end

-- The poll loop ---------------------------------------------------------

-- One poll. Returns false when there is nothing left to watch, so the loop can
-- stop when the last block closes.
local function poll_once(): boolean
	loop = nil
	local live = alive_panes()
	for pane in blocks do
		if not live[pane] then
			blocks[pane] = nil
		end
	end
	if next(blocks) == nil then
		return false
	end
	player.check_tools()
	local latest = player.poll()
	if latest ~= nil then
		if latest.video ~= "" then
			player.load_cover(latest.video, share_art)
		end
		if latest.err ~= "" and latest.err ~= shown_err then
			shown_err = latest.err
			for _, block in blocks do
				block.context:toast("error", "YouTube Music", latest.err)
			end
		end
	end
	queue = player.queue()
	local now = tern.now()
	for _, block in blocks do
		if block.state.flash_until > 0 and now > block.state.flash_until then
			block.state.flash = ""
			block.state.flash_until = 0
		end
		if block.focus_at ~= nil and now >= block.focus_at then
			block.focus_at = nil
			local focus_id = block.focus_id or FOCUS_ID
			block.focus_id = nil
			block.context:frame({ { "focus", focus_id } })
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

-- The poll loop is the block's heartbeat; one bad poll must not end it.
local function tick(): ()
	local ok, keep = pcall(poll_once)
	if not ok or keep then
		loop = tern.timer(POLL_MS, tick)
	end
end

local function start_loop(): ()
	if loop == nil then
		loop = tern.timer(0, tick)
	end
end

-- Keys and events -------------------------------------------------------

local function key_queue(block: Block, k: Key): boolean?
	local state = block.state
	local count = #queue
	if k.name == "space" or k.name == "k" then
		toggle_play(block)
	elseif k.name == "n" then
		next_track(block)
	elseif k.name == "p" then
		previous_track(block)
	elseif k.name == "left" then
		seek_by(block, -SEEK_STEP_S)
	elseif k.name == "right" then
		seek_by(block, SEEK_STEP_S)
	elseif k.name == "up" then
		state.sel_queue = math.max(1, state.sel_queue - 1)
	elseif k.name == "down" then
		state.sel_queue = math.min(math.max(count, 1), state.sel_queue + 1)
	elseif k.name == "enter" then
		jump_to(block, state.sel_queue - 1)
	elseif k.name == "d" or k.name == "delete" then
		remove_at(block, state.sel_queue - 1)
	elseif k.name == "c" then
		clear_queue(block)
	elseif k.name == "+" or k.name == "=" or k.name == "equal" or k.name == "plus" then
		bump_volume(block, VOLUME_STEP)
	elseif k.name == "-" or k.name == "_" or k.name == "minus" then
		bump_volume(block, -VOLUME_STEP)
	elseif k.name == "m" then
		toggle_mute(block)
	elseif k.name == "s" then
		toggle_shuffle(block)
	elseif k.name == "r" then
		cycle_loop(block)
	elseif k.name == "/" then
		focus_search(block)
	elseif k.name == "l" then
		state.mode = "library"
	else
		return false
	end
	return true
end

local function key_search(block: Block, k: Key): boolean?
	local state = block.state
	local visible = filtered_results(state)
	if k.name == "up" then
		state.sel_search = math.max(1, state.sel_search - 1)
	elseif k.name == "down" then
		state.sel_search = math.min(math.max(#visible, 1), state.sel_search + 1)
	elseif k.name == "enter" then
		local track = visible[math.clamp(state.sel_search, 1, math.max(#visible, 1))]
		if track ~= nil then
			play_track(block, track)
		end
	elseif k.name == "escape" then
		if state.query ~= "" then
			state.query = ""
			state.cursor = 0
			block.search_at = tern.now() + SEARCH_DEBOUNCE_MS
		else
			state.mode = "queue"
		end
	else
		return edit_query(block, k)
	end
	return true
end

local function key_artist(block: Block, k: Key): boolean?
	local state = block.state
	local visible = filtered_results(state)
	if k.name == "up" then
		state.sel_search = math.max(1, state.sel_search - 1)
	elseif k.name == "down" then
		state.sel_search = math.min(math.max(#visible, 1), state.sel_search + 1)
	elseif k.name == "enter" then
		local track = visible[math.clamp(state.sel_search, 1, math.max(#visible, 1))]
		if track ~= nil then
			play_track(block, track)
		end
	elseif k.name == "escape" then
		if state.artist_filter ~= "" then
			state.artist_filter = ""
			state.artist_cursor = 0
			state.sel_search = 1
		else
			focus_search(block)
		end
	else
		return edit_artist_filter(state, k)
	end
	return true
end

local function key_playlist_name(block: Block, k: Key): boolean?
	if k.name == "enter" then
		save_playlist(block, "queue")
		block.state.mode = "library"
	elseif k.name == "escape" then
		block.state.mode = "library"
	else
		return edit_playlist_name(block.state, k)
	end
	return true
end

local function key_library(block: Block, k: Key): boolean?
	local state = block.state
	local count = #player.playlists()
	if k.name == "up" then
		state.sel_playlist = math.max(1, state.sel_playlist - 1)
	elseif k.name == "down" then
		state.sel_playlist = math.min(math.max(count, 1), state.sel_playlist + 1)
	elseif k.name == "enter" then
		play_selected_playlist(block)
	elseif k.name == "+" or k.name == "=" or k.name == "equal" or k.name == "plus" then
		enqueue_selected_playlist(block)
	elseif k.name == "d" or k.name == "delete" then
		delete_playlist(block)
	elseif k.name == "/" then
		focus_search(block)
	else
		return false
	end
	return true
end

local function selected_track(state: State): Track?
	local visible = filtered_results(state)
	if #visible == 0 then
		return nil
	end
	return visible[math.clamp(state.sel_search, 1, #visible)]
end

local function on_action(block: Block, state: State, act: string, raw: string?): ()
	if act == "play-pause" then
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
	elseif act == "focus-search" then
		focus_search(block)
	elseif act == "toggle-autoplay" then
		local enabled = not player.autoplay()
		local ok, failure = player.set_autoplay(enabled)
		say(block, if ok then (if enabled then "Similar-track autoplay enabled" else "Autoplay disabled") else "Could not update autoplay: " .. (failure or "unknown error"))
	elseif act == "duration" and raw ~= nil and (raw == "all" or raw == "short" or raw == "medium" or raw == "long") then
		state.duration_filter = raw :: DurationFilter
		state.sel_search = 1
	elseif act == "play-all" then
		play_all(block, state.sel_search)
	elseif act == "enqueue-selected" then
		local track = selected_track(state)
		if track ~= nil then
			enqueue_track(block, track)
		end
	elseif act == "save-results" then
		save_playlist(block, "results")
	elseif act == "save-queue" then
		save_playlist(block, "queue")
	elseif act == "play-playlist" then
		play_selected_playlist(block)
	elseif act == "queue-playlist" then
		enqueue_selected_playlist(block)
	elseif act == "delete-playlist" then
		delete_playlist(block)
	elseif raw ~= nil and act == "play" then
		local track = filtered_results(state)[tonumber(raw) or 0]
		if track ~= nil then
			play_track(block, track)
		end
	elseif raw ~= nil and act == "queue" then
		local track = filtered_results(state)[tonumber(raw) or 0]
		if track ~= nil then
			enqueue_track(block, track)
		end
	elseif raw ~= nil and act == "jump" then
		jump_to(block, tonumber(raw) or -1)
	end
end

-- The block -------------------------------------------------------------

local player_block: BlockDef<State> = {
	init = function(cx: BlockCx, args: { string }, saved: any): State
		yt.ensure_dirs()
		local restored: any = saved
		local state: State = {
			mode = "search",
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
			flash = "",
			flash_until = 0,
		}
		if type(restored) == "table" then
			if type(restored.query) == "string" then
				state.query = restored.query
				state.cursor = #state.query
			end
			if restored.mode == "queue"
				or restored.mode == "search"
				or restored.mode == "playlist-name"
				or restored.mode == "artist-filter"
				or restored.mode == "library"
			then
				state.mode = restored.mode
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
			then "main.library.form.name"
			elseif state.mode == "artist-filter"
			then "main.search.filters.artist"
			elseif state.mode == "search"
			then FOCUS_ID
			else nil
		local block: Block = {
			context = cx,
			state = state,
			blob = nil,
			blob_key = nil,
			resend_at = nil,
			rendered = "",
			searching = false,
			search_seq = 0,
			search_at = if state.query ~= "" then tern.now() + SEARCH_DEBOUNCE_MS else nil,
			focus_at = if focus_id == nil then nil else tern.now() + FOCUS_DELAY_MS,
			focus_id = focus_id,
			optimistic = {},
		}
		blocks[cx.pane] = block
		start_loop()
		-- Launch arguments are a first-run thing: a reload or a daemon restart
		-- passes them again, and replaying them would restart the queue.
		local first = if restored == nil then args[1] else nil
		if first ~= nil and first ~= "" then
			if yt.is_youtube(first) then
				play_track(block, {
					url = first,
					video = yt.youtube_id(first) or "",
					title = first,
					artist = "",
					duration = nil,
				})
				block.focus_at = nil
				block.focus_id = nil
			else
				state.query = first
				state.cursor = #first
				block.search_at = tern.now() + SEARCH_DEBOUNCE_MS
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
		return "YouTube Player"
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
		elseif p == nil then
			table.insert(children, with(ui.card({ ui.span("Waiting for the player", "strong") }, {
				ui.text({ ui.span(if player.is_running() then "mpv is starting…" else "mpv is not running", "muted") }),
			}), { key = "waiting" }))
		end
		table.insert(children, hero(block, p, cx))
		table.insert(children, progress_row(p))
		table.insert(children, control_row(p))
		table.insert(children, search_section(block, state))
		table.insert(children, queue_section(state, p))
		table.insert(children, playlists_section(state))
		return { main = with(ui.col(children), { role = "ytm-main" }), dock = dock(state, p, cx) }
	end,

	key = function(state: State, k: Key, cx: BlockCx): boolean?
		local block = blocks[cx.pane]
		if block == nil then
			return false
		end
		if k.name == "tab" then
			if state.mode == "queue" then
				focus_search(block)
			elseif state.mode == "library" then
				state.mode = "queue"
			else
				state.mode = "queue"
			end
			return true
		end
		if state.mode == "search" then
			return key_search(block, k)
		elseif state.mode == "artist-filter" then
			return key_artist(block, k)
		elseif state.mode == "playlist-name" then
			return key_playlist_name(block, k)
		elseif state.mode == "library" then
			return key_library(block, k)
		end
		return key_queue(block, k)
	end,

	event = function(state: State, ev: UiEvent, cx: BlockCx): ()
		local block = blocks[cx.pane]
		if block == nil then
			return
		end
		if ev.ev == "focus" then
			if ev.id == FOCUS_ID then
				state.mode = "search"
			elseif ev.id == "main.search.filters.artist" then
				state.mode = "artist-filter"
			elseif ev.id == "main.library.form.name" then
				state.mode = "playlist-name"
			end
			if ev.id ~= nil then
				block.focus_id = ev.id
				cx:frame({ { "focus", ev.id } })
			end
			return
		end
		if ev.ev == "select" or ev.ev == "activate" then
			local item = if type(ev.item) == "string" then ev.item else ""
			local index = tonumber(string.match(item, "%.p(%d+)$"))
			if index ~= nil then
				state.mode = "library"
				state.sel_playlist = index
				if ev.ev == "activate" then
					play_selected_playlist(block)
				end
			end
			return
		end
		if ev.ev ~= "action" then
			return
		end
		local act = ev.act
		if act ~= nil then
			on_action(block, state, act, ev.value)
		end
	end,

	save = function(state: State): any
		return {
			query = state.query,
			mode = state.mode,
			artist_filter = state.artist_filter,
			duration_filter = state.duration_filter,
			playlist_name = state.playlist_name,
			sel_playlist = state.sel_playlist,
		}
	end,
}

tern.block.define("player", player_block)
