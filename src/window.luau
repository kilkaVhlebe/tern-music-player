--!strict
-- Music Player: the window half — palette commands, the track-link route and
-- the status-line segment.
--
-- It speaks the same files as the block (`src/ytmusic.luau`), which works
-- because a window and the daemon it is attached to share one machine. With a
-- remote daemon the window sees its own files, not the remote player's; the
-- commands then say the player is not running. The block on the remote host
-- still works.
--
-- Everything here runs on the window's UI thread under a 50 ms budget (4 ms
-- for the status formatter), so the hooks do as little as possible: the
-- status formatter returns a table built by the poll, and the poll reads one
-- small file every POLL_MS.

local yt = require("./ytmusic")
local sched = require("./sched")

local KIND = "ytmusic.player"
local GROUP = "Music Player"
local POLL_MS = 1500
local VOLUME_STEP = 5
-- How long after the link route hands a URL to the block a new pane counts
-- as the one it opened (and gets floated).
local FLOAT_WINDOW_MS = 3000

-- The status line's segments, rebuilt by the poll only when they change.
local segments: { StatusSegment }? = nil
local last_text: string? = nil
local last_playing: boolean? = nil
local float_until = 0
local last_player: yt.Player? = nil

local function fresh(): yt.Player?
	local player, torn = yt.read()
	if torn then
		-- Caught the bridge mid-write: the last read is still the best guess.
		return if yt.fresh(last_player) then last_player else nil
	end
	last_player = player
	if yt.fresh(player) then
		return player
	end
	return nil
end

-- Floats a freshly opened player in the corner and focuses it.
local function float(cx: WindowCx, pane: number): ()
	local info = cx.session:pane(pane)
	if info ~= nil and info.block == KIND and not info.floating then
		cx.layout:float(pane, nil, "br", { focus = true })
		cx.layout:focus(pane)
	end
end

-- Only panes the route just asked for are looked at: querying every new
-- pane of the window would cost every split a session lookup.
tern.on("pane_created", function(event: PaneEvent, cx: WindowCx)
	if tern.now() > float_until then
		return
	end
	float_until = 0
	float(cx, event.pane)
end)

local function open_player(cx: WindowCx): ()
	for _, pane in cx.session:panes() do
		if pane.block == KIND then
			cx.layout:focus(pane.pane)
			return
		end
	end
	-- An empty cwd keeps the picture-in-picture title strip clean.
	local target = cx.session:focused()
	local pane = if target
		then cx.layout:split(target, "right", { block = KIND, cwd = "" })
		else cx:new_block(KIND, nil, "beside")
	if pane == nil then
		cx:toast("error", "Music Player is not loaded on this host", "Install the plugin where your panes run.")
		return
	end
	float(cx, pane)
end

tern.command({
	id = "open",
	title = "Music Player: Open",
	icon = "wave",
	group = GROUP,
	keys = { "cmd+shift+y" },
	run = open_player,
})

local function control(id: string, title: string, icon: string, run: (cx: WindowCx, player: yt.Player) -> ()): ()
	tern.command({
		id = id,
		title = "Music Player: " .. title,
		icon = icon,
		group = GROUP,
		run = function(cx: WindowCx)
			local player = fresh()
			if player == nil then
				cx:toast("info", "The music player is not running", "Open it with Music Player: Open.")
				return
			end
			run(cx, player)
		end,
	})
end

control("play-pause", "Play/Pause", "play", function(_cx: WindowCx, _player: yt.Player)
	yt.send("toggle")
end)

control("next", "Next track", "frame-next", function(_cx: WindowCx, _player: yt.Player)
	yt.send("next")
end)

control("previous", "Previous track", "frame-prev", function(_cx: WindowCx, _player: yt.Player)
	yt.send("prev")
end)

control("volume-up", "Volume up", "plus", function(_cx: WindowCx, player: yt.Player)
	local level = math.min(yt.volume_max, math.floor(player.volume + 0.5) + VOLUME_STEP)
	yt.send("volume", tostring(level))
	yt.remember_volume(level)
end)

control("volume-down", "Volume down", "minus", function(_cx: WindowCx, player: yt.Player)
	local level = math.max(0, math.floor(player.volume + 0.5) - VOLUME_STEP)
	yt.send("volume", tostring(level))
	yt.remember_volume(level)
end)

control("mute", "Mute/Unmute", "slash-circle", function(_cx: WindowCx, player: yt.Player)
	yt.send("mute", if player.mute then "off" else "on")
end)

control("shuffle", "Toggle shuffle", "swap", function(_cx: WindowCx, player: yt.Player)
	yt.send("shuffle", if player.shuffle then "off" else "on")
end)

local NEXT_LOOP: { [string]: yt.Loop } = { off = "all", all = "one", one = "off" }

control("loop", "Cycle repeat", "repeat", function(_cx: WindowCx, player: yt.Player)
	yt.send("loop", NEXT_LOOP[player.loop] or "off")
end)

control("clear", "Clear the queue", "trash", function(_cx: WindowCx, _player: yt.Player)
	yt.send("clear")
end)

control("stop", "Stop the player", "stop", function(_cx: WindowCx, _player: yt.Player)
	yt.send("quit")
end)

-- Clicking a playable track link anywhere in Tern opens it in the player.
tern.route.link(function(link: LinkRequest, _cx: WindowCx): RouteDecision?
	if yt.is_playable_url(link.url) then
		float_until = tern.now() + FLOAT_WINDOW_MS
		return { block = KIND, args = { link.url } }
	end
	return nil
end)

-- The current track in the status line, for whichever pane is focused.
tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
	return segments
end)

local function poll_once(_cx: any): boolean?
	local player = fresh()
	local text: string? = nil
	local playing = false
	if player ~= nil and player.title ~= "" then
		playing = player.state == "playing"
		local line = yt.cut(player.title, 34)
		if player.artist ~= "" then
			line ..= " · " .. yt.cut(player.artist, 22)
		end
		text = line
	end
	if text == last_text and playing == last_playing then
		return true
	end
	last_text = text
	last_playing = playing
	segments = if text == nil
		then nil
		else {
			{
				text = text,
				icon = if playing then "play" else "pause",
				tone = if playing then nil else "muted",
				command = "plugin.ytmusic.open",
			},
		}
	tern.chrome.refresh()
	return true
end

sched.every(POLL_MS, poll_once)
