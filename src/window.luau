--!strict
-- YouTube Music: the window half — palette commands, the YouTube link route and
-- the status-line segment.
--
-- It speaks the same files as the block (`src/ytmusic.luau`), which works
-- because a window and the daemon it is attached to share one machine. With a
-- remote daemon the window sees its own files, not the remote player's; the
-- commands then say the player is not running. The block on the remote host
-- still works.

local yt = require("./ytmusic")

local KIND = "ytmusic.player"
local POLL_MS = 1000
local VOLUME_STEP = 5

local segment: StatusSegment? = nil
local shown_err: string? = nil

local function fresh(): yt.Player?
	local player = yt.read()
	if yt.fresh(player) then
		return player
	end
	return nil
end

-- Floats a freshly opened player in the corner and focuses it, like the other
-- player plugins; the block is what the user just asked for.
local function float(cx: WindowCx, pane: number): ()
	local info = cx.session:pane(pane)
	if info ~= nil and info.block == KIND and not info.floating then
		cx.layout:float(pane, nil, "br", { focus = true })
		cx.layout:focus(pane)
	end
end

tern.on("pane_created", function(event: PaneEvent, cx: WindowCx)
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
		cx:toast("error", "YouTube Music is not loaded on this host", "Install the plugin where your panes run.")
		return
	end
	float(cx, pane)
end

tern.command({
	id = "open",
	title = "YouTube Music: Open player",
	icon = "wave",
	group = "YouTube Music",
	keys = { "cmd+shift+y" },
	run = open_player,
})

local function control(id: string, title: string, icon: string, run: (cx: WindowCx, player: yt.Player) -> ()): ()
	tern.command({
		id = id,
		title = title,
		icon = icon,
		group = "YouTube Music",
		run = function(cx: WindowCx)
			local player = fresh()
			if player == nil then
				cx:toast("info", "The YouTube player is not running", "Open the player block to start it.")
				return
			end
			run(cx, player)
		end,
	})
end

control("play-pause", "YouTube Music: Play/Pause", "play", function(_cx: WindowCx, _player: yt.Player)
	yt.send("toggle")
end)

control("next", "YouTube Music: Next track", "frame-next", function(_cx: WindowCx, _player: yt.Player)
	yt.send("next")
end)

control("previous", "YouTube Music: Previous track", "frame-prev", function(_cx: WindowCx, _player: yt.Player)
	yt.send("prev")
end)

control("volume-up", "YouTube Music: Volume up", "plus", function(_cx: WindowCx, player: yt.Player)
	local level = math.min(yt.volume_max, math.floor(player.volume + 0.5) + VOLUME_STEP)
	yt.send("volume", tostring(level))
	yt.remember_volume(level)
end)

control("volume-down", "YouTube Music: Volume down", "minus", function(_cx: WindowCx, player: yt.Player)
	local level = math.max(0, math.floor(player.volume + 0.5) - VOLUME_STEP)
	yt.send("volume", tostring(level))
	yt.remember_volume(level)
end)

control("mute", "YouTube Music: Mute/Unmute", "slash-circle", function(_cx: WindowCx, player: yt.Player)
	yt.send("mute", if player.mute then "off" else "on")
end)

control("shuffle", "YouTube Music: Toggle shuffle", "swap", function(_cx: WindowCx, player: yt.Player)
	yt.send("shuffle", if player.shuffle then "off" else "on")
end)

local NEXT_LOOP: { [string]: yt.Loop } = { off = "all", all = "one", one = "off" }

control("loop", "YouTube Music: Cycle repeat", "repeat", function(_cx: WindowCx, player: yt.Player)
	yt.send("loop", NEXT_LOOP[player.loop] or "off")
end)

control("clear", "YouTube Music: Clear the queue", "trash", function(_cx: WindowCx, _player: yt.Player)
	yt.send("clear")
end)

tern.command({
	id = "stop",
	title = "YouTube Music: Stop the player",
	icon = "stop",
	group = "YouTube Music",
	run = function(cx: WindowCx)
		if fresh() == nil then
			cx:toast("info", "The YouTube player is not running")
			return
		end
		yt.send("quit")
	end,
})

-- Clicking a YouTube link anywhere in Tern opens it in the player.
tern.route.link(function(link: LinkRequest, _cx: WindowCx): RouteDecision?
	if yt.is_youtube(link.url) then
		return { block = KIND, args = { link.url } }
	end
	return nil
end)

local function segment_of(player: yt.Player?): StatusSegment?
	if player == nil or player.title == "" then
		return nil
	end
	local playing = player.state == "playing"
	local text = yt.cut(player.title, 34)
	if player.artist ~= "" then
		text ..= " · " .. yt.cut(player.artist, 22)
	end
	return {
		text = text,
		icon = if playing then "play" else "pause",
		tone = if playing then nil else "muted",
		command = "plugin.ytmusic.open",
	}
end

local function same(left: StatusSegment?, right: StatusSegment?): boolean
	if left == nil or right == nil then
		return left == right
	end
	return left.text == right.text and left.icon == right.icon and left.tone == right.tone
end

-- The current track in the status line, for whichever pane is focused; the
-- poll loop below keeps `segment` current and refreshes the line when it moves.
tern.chrome.status(function(_pane: StatusPaneInfo): { StatusSegment }?
	if segment == nil then
		return nil
	end
	return { segment }
end)

local function poll_once(cx: WindowCx?): ()
	local player = fresh()
	if cx ~= nil and player ~= nil and player.err ~= "" and player.err ~= shown_err then
		shown_err = player.err
		cx:toast("error", "YouTube Music", player.err)
	end
	local next_segment = segment_of(player)
	if not same(segment, next_segment) then
		segment = next_segment
		tern.chrome.refresh()
	end
end

-- One bad poll must not end the loop that keeps the status line honest.
local function tick(cx: WindowCx?): ()
	pcall(poll_once, cx)
	tern.timer(POLL_MS, tick)
end

tern.timer(POLL_MS, tick)
