-- Runs inside mpv, not inside Tern: `mpv --idle --script=.../mpv/bridge.lua`.
--
-- This is the player's half of the plugin's file protocol (the other half is
-- src/ytmusic.luau). It polls `cmds/` for commands, applies them to mpv and
-- writes `state.txt` and `queue.txt` back. mpv is started with the plugin's
-- data directory as its working directory, so the three names are relative.
--
-- Plain Lua, not Luau: mpv embeds its own Lua, and this file must run there.
-- Arguments: first line of a command file is the name, the rest are its fields.

local mp = require 'mp'
local utils = require 'mp.utils'

local TICK = 0.5      -- seconds between polls
local CMD_STALE = 90  -- drop a half-written command file after this long

-- Where the plugin keeps its files. The plugin passes it as TERN_YT_DATA, and
-- on a host that applies the process working directory the two agree; the
-- variable wins so a child that inherited some other directory still writes
-- next to the state the plugin reads.
local function data_dir()
	local from_env = os.getenv and os.getenv('TERN_YT_DATA')
	if from_env ~= nil and from_env ~= '' then
		return from_env
	end
	return utils.getcwd() or '.'
end

local cwd = data_dir()
local function path(name)
	return utils.join_path(cwd, name)
end

local STATE = path('state.txt')
local QUEUE = path('queue.txt')
local CMDS = path('cmds')

local hints = {}        -- url -> {id, title, artist}, as the plugin queued it
local end_seq = 0       -- counts files that ended, so the plugin sees a track end
local end_reason = ''
local last_err = ''
local last_state = nil
local queue_dirty = true
local first_tick = true

local function read_file(name)
	local handle = io.open(name, 'rb')
	if handle == nil then
		return nil
	end
	local text = handle:read('*a')
	handle:close()
	return text
end

local function write_file(name, text)
	local handle = io.open(name, 'wb')
	if handle == nil then
		return false
	end
	handle:write(text)
	handle:close()
	return true
end

local function clean(value)
	if value == nil then
		return ''
	end
	return (tostring(value):gsub('%c+', ' '))
end

local function flag(value)
	if value then
		return '1'
	end
	return '0'
end

local function metadata_value(metadata, keys)
	for _, key in ipairs(keys) do
		local value = metadata[key]
		if type(value) == 'string' and value ~= '' then
			return value
		end
	end
	return nil
end

local function state_name()
	if mp.get_property_native('idle-active') then
		return 'idle'
	end
	if mp.get_property_native('pause') then
		return 'paused'
	end
	if mp.get_property_native('core-idle') then
		return 'starting'
	end
	return 'playing'
end

local function snapshot()
	local current = mp.get_property('path') or ''
	local hint = hints[current] or {}
	local metadata = mp.get_property_native('metadata') or {}
	local title = mp.get_property('media-title') or ''
	if title == '' then
		title = hint.title or ''
	end
	local artist = metadata_value(metadata, { 'artist', 'ARTIST', 'uploader', 'channel', 'creator' }) or hint.artist or ''
	local duration = mp.get_property_number('duration')
	local position = mp.get_property_number('time-pos') or 0
	local volume = mp.get_property_number('volume') or 0
	local loop = 'off'
	if mp.get_property('loop-file') == 'inf' then
		loop = 'one'
	elseif mp.get_property('loop-playlist') == 'inf' then
		loop = 'all'
	end
	local lines = {
		'v=1',
		'beat=' .. tostring(os.time()),
		'pid=' .. tostring(utils.getpid()),
		'state=' .. state_name(),
		'pos=' .. string.format('%.1f', position),
		'duration=' .. (duration and string.format('%.1f', duration) or ''),
		'volume=' .. tostring(math.floor(volume + 0.5)),
		'mute=' .. flag(mp.get_property_native('mute')),
		'shuffle=' .. flag(mp.get_property_native('shuffle')),
		'loop=' .. loop,
		'index=' .. tostring(mp.get_property_number('playlist-pos') or -1),
		'count=' .. tostring(mp.get_property_number('playlist-count') or 0),
		'seq=' .. tostring(end_seq),
		'end=' .. clean(end_reason),
		'title=' .. clean(title),
		'artist=' .. clean(artist),
		'video=' .. clean(hint.id),
		'err=' .. clean(last_err),
	}
	return table.concat(lines, '\n') .. '\n'
end

local function write_queue()
	local entries = mp.get_property_native('playlist') or {}
	local lines = {}
	for index, entry in ipairs(entries) do
		local url = entry.filename or ''
		local hint = hints[url] or {}
		lines[index] = table.concat({
			tostring(index - 1),
			clean(url),
			clean(hint.id),
			clean(hint.title),
			clean(hint.artist),
		}, '\t')
	end
	local text = table.concat(lines, '\n')
	if text ~= '' then
		text = text .. '\n'
	end
	write_file(QUEUE, text)
end

local commands = {}

local function play_index(index)
	-- mpv 0.35+ restarts the entry even if it is the current one, which is what
	-- pressing play after the playlist ended needs. Older mpv fails the command
	-- (mp.commandv raises) and falls back to the property, which does not
	-- restart the current entry but still resumes.
	local ok = pcall(mp.commandv, 'playlist-play-index', tostring(index))
	if not ok then
		mp.commandv('set', 'playlist-pos', tostring(index))
		mp.commandv('set', 'pause', 'no')
	end
end

commands['toggle'] = function()
	local count = mp.get_property_number('playlist-count') or 0
	if count == 0 then
		return
	end
	local index = mp.get_property_number('playlist-pos') or -1
	if index < 0 then
		-- After the playlist ended, playlist-pos is gone; the current flag still
		-- remembers the entry that played last, so play resumes from there.
		local current = mp.get_property_number('playlist-current-pos')
		if current ~= nil and current >= 0 then
			index = current
		end
	end
	local finished = mp.get_property_native('idle-active') or mp.get_property_native('eof-reached') or index < 0
	if finished then
		if index < 0 then
			index = 0
		end
		play_index(index)
	else
		mp.commandv('set', 'pause', flag(mp.get_property_native('pause')) == '1' and 'no' or 'yes')
	end
end

commands['next'] = function()
	mp.commandv('playlist-next')
end

commands['prev'] = function()
	mp.commandv('playlist-prev')
end

commands['seek'] = function(args)
	local seconds = tonumber(args[1])
	if seconds == nil then
		return
	end
	mp.commandv('seek', tostring(math.max(0, seconds)), 'absolute')
end

commands['volume'] = function(args)
	local value = tonumber(args[1])
	if value == nil then
		return
	end
	mp.commandv('set', 'volume', tostring(math.max(0, math.min(130, math.floor(value + 0.5)))))
end

commands['mute'] = function(args)
	mp.commandv('set', 'mute', args[1] == 'on' and 'yes' or 'no')
end

commands['shuffle'] = function(args)
	mp.commandv('set', 'shuffle', args[1] == 'on' and 'yes' or 'no')
end

commands['loop'] = function(args)
	local mode = args[1] or 'off'
	mp.commandv('set', 'loop-file', mode == 'one' and 'inf' or 'no')
	mp.commandv('set', 'loop-playlist', mode == 'all' and 'inf' or 'no')
end

commands['play'] = function(args)
	local url = args[1] or ''
	if url == '' then
		return
	end
	hints[url] = { id = args[2] or '', title = args[3] or '', artist = args[4] or '' }
	mp.commandv('playlist-clear')
	mp.commandv('loadfile', url, 'replace')
	queue_dirty = true
end

commands['enqueue'] = function(args)
	local url = args[1] or ''
	if url == '' then
		return
	end
	hints[url] = { id = args[2] or '', title = args[3] or '', artist = args[4] or '' }
	mp.commandv('loadfile', url, 'append')
	queue_dirty = true
end

commands['jump'] = function(args)
	local index = tonumber(args[1])
	if index == nil or index < 0 then
		return
	end
	play_index(math.floor(index))
end

commands['remove'] = function(args)
	local index = tonumber(args[1])
	if index == nil or index < 0 then
		return
	end
	mp.commandv('playlist-remove', tostring(math.floor(index)))
	queue_dirty = true
end

commands['clear'] = function()
	-- playlist-clear keeps the current entry; the queue here must end up empty.
	local count = mp.get_property_number('playlist-count') or 0
	for index = count - 1, 0, -1 do
		mp.commandv('playlist-remove', tostring(index))
	end
	mp.commandv('set', 'pause', 'no')
	queue_dirty = true
end

commands['quit'] = function()
	mp.commandv('quit')
end

commands['dump'] = function()
	last_state = nil
	queue_dirty = true
end

local function run_command(text)
	local lines = {}
	for line in text:gmatch('[^\n]+') do
		lines[#lines + 1] = line
	end
	local name = table.remove(lines, 1)
	if name == nil or name == '' or name == 'done' then
		return
	end
	local run = commands[name]
	if run == nil then
		mp.msg.warn('tern bridge: unknown command ' .. name)
		return
	end
	local ok, err = pcall(run, lines)
	if not ok then
		last_err = 'command ' .. name .. ' failed: ' .. tostring(err)
		mp.msg.warn('tern bridge: ' .. last_err)
	end
end

local function process_commands()
	local files = utils.readdir(CMDS, 'files')
	if files == nil then
		return
	end
	table.sort(files)
	local now = os.time()
	for _, name in ipairs(files) do
		local full = utils.join_path(CMDS, name)
		local text = read_file(full)
		if text == nil then
			os.remove(full)
		elseif text:sub(-1) == '\n' then
			run_command(text)
			if not os.remove(full) then
				write_file(full, 'done\n')
			end
		else
			-- A write that has not finished, or a file a crash left behind.
			local info = utils.file_info(full)
			if info ~= nil and now - (info.mtime or now) > CMD_STALE then
				os.remove(full)
			end
		end
	end
end

-- True when another bridge is writing the state file right now: the plugin
-- spawned a fresh player because this one looked dead, and two players must not
-- fight over the same files. Our own pid is in the state we just wrote.
local function taken_over()
	local text = read_file(STATE)
	if text == nil then
		return false
	end
	local beat = tonumber(string.match(text, 'beat=(%d+)') or '')
	local pid = tonumber(string.match(text, 'pid=(%d+)') or '')
	if beat == nil or pid == nil then
		return false
	end
	if os.time() - beat > 3 then
		return false
	end
	return pid ~= utils.getpid()
end

local function tick()
	process_commands()
	local state = snapshot()
	if state ~= last_state then
		last_state = state
		write_file(STATE, state)
		queue_dirty = true
	end
	if queue_dirty then
		queue_dirty = false
		write_queue()
	end
	if not first_tick and taken_over() then
		mp.msg.info('tern bridge: another player owns the state file; stopping')
		mp.commandv('quit')
		return
	end
	first_tick = false
	mp.add_timeout(TICK, tick)
end

mp.observe_property('playlist-pos', nil, function()
	queue_dirty = true
end)
mp.observe_property('playlist-count', nil, function()
	queue_dirty = true
end)

mp.register_event('end-file', function(event)
	end_seq = end_seq + 1
	end_reason = event.reason or 'unknown'
	if end_reason == 'error' then
		last_err = 'playback failed; see mpv.log'
	end
	queue_dirty = true
end)

mp.register_event('start-file', function()
	end_reason = ''
	-- A new file starting clears the last failure: the error field then always
	-- describes the file the player is on (or was last on).
	last_err = ''
end)

mp.msg.info('tern bridge: watching ' .. CMDS)
mp.add_timeout(0.05, tick)
