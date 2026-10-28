--!strict
-- Public YouTube Music search and related-track endpoints.
-- The API is undocumented; category filtering keeps results inside the music catalog.
local net = require("./net")

local catalog = {}
export type Category = "tracks" | "artists" | "playlists" | "podcasts"
export type Kind = "track" | "artist" | "playlist" | "podcast"
export type Item = {
	kind: Kind,
	title: string,
	artist: string,
	detail: string,
	url: string,
	video: string,
	duration: number?,
	browse_id: string,
	-- Artwork URL when the source reported one (SoundCloud does); YouTube
	-- thumbnails are built from the video id instead.
	art: string?,
}

local API = "https://music.youtube.com/youtubei/v1/"
local SECRETS_FILE = ".secrets.json"
local USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:88.0) Gecko/20100101 Firefox/88.0"
local LIMIT = 40

local SEARCH_PARAMS: { [Category]: string } = {
	tracks = "EgWKAQIIAWoMEA4QChADEAQQCRAF",
	artists = "EgWKAQIgAWoMEA4QChADEAQQCRAF",
	playlists = "Eg-KAQwIABAAGAAgACgBMABqChAEEAMQCRAFEAo%3D",
	podcasts = "EgWKAQJQAWoMEA4QChADEAQQCRAF",
}

local function field(value: any, key: string | number): any
	if type(value) == "table" then
		return value[key]
	end
	return nil
end

local function path(value: any, keys: { string | number }): any
	for _, key in keys do
		value = field(value, key)
		if value == nil then
			return nil
		end
	end
	return value
end

local function text(value: any): string
	if type(value) == "string" then
		return value
	end
	local simple = field(value, "simpleText")
	if type(simple) == "string" then
		return simple
	end
	local runs = field(value, "runs")
	if type(runs) ~= "table" then
		return ""
	end
	local parts: { string } = {}
	for _, run in runs do
		local part = field(run, "text")
		if type(part) == "string" then
			table.insert(parts, part)
		end
	end
	return table.concat(parts)
end

local function column(row: any, index: number): string
	return text(path(row, { "flexColumns", index, "musicResponsiveListItemFlexColumnRenderer", "text" }))
end

local function clock_seconds(value: string): number?
	local hours, minutes, seconds = string.match(value, "^(%d+):(%d%d):(%d%d)$")
	if hours ~= nil and minutes ~= nil and seconds ~= nil then
		return (tonumber(hours) or 0) * 3600 + (tonumber(minutes) or 0) * 60 + (tonumber(seconds) or 0)
	end
	minutes, seconds = string.match(value, "^(%d+):(%d%d)$")
	if minutes ~= nil and seconds ~= nil then
		return (tonumber(minutes) or 0) * 60 + (tonumber(seconds) or 0)
	end
	return nil
end

-- A column's text split on the " • " separators YouTube Music puts between
-- artist, album, view count and duration.
local function segments(value: string): { string }
	local parts: { string } = {}
	for part in string.gmatch(value .. " • ", "(.-) • ") do
		local trimmed = string.match(part, "^%s*(.-)%s*$") or ""
		if trimmed ~= "" then
			table.insert(parts, trimmed)
		end
	end
	return parts
end

-- The duration from a flex column segment or a fixed column (playlist rows).
local function duration_seconds(row: any): number?
	for _, group in { "flexColumns", "fixedColumns" } do
		local columns = field(row, group)
		if type(columns) == "table" then
			for _, column_value in columns do
				local renderer = field(column_value, "musicResponsiveListItemFlexColumnRenderer")
					or field(column_value, "musicResponsiveListItemFixedColumnRenderer")
				for _, part in segments(text(field(renderer, "text"))) do
					local seconds = clock_seconds(part)
					if seconds ~= nil then
						return seconds
					end
				end
			end
		end
	end
	return nil
end

local function video_id(row: any): string
	local candidates = {
		path(row, { "playlistItemData", "videoId" }),
		path(row, { "overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer", "playNavigationEndpoint", "watchEndpoint", "videoId" }),
		path(row, { "navigationEndpoint", "watchEndpoint", "videoId" }),
		path(row, { "onTap", "watchEndpoint", "videoId" }),
	}
	for _, candidate in candidates do
		if type(candidate) == "string" and candidate ~= "" then
			return candidate
		end
	end
	return ""
end

local function music_video_type(row: any): string
	local candidates = {
		path(row, { "navigationEndpoint", "watchEndpoint", "watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType" }),
		path(row, { "overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer", "playNavigationEndpoint", "watchEndpoint", "watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType" }),
		path(row, { "onTap", "watchEndpoint", "watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType" }),
	}
	for _, candidate in candidates do
		if type(candidate) == "string" and candidate ~= "" then
			return candidate
		end
	end
	return ""
end

local function accepted_type(video_type: string): boolean
	return video_type == "MUSIC_VIDEO_TYPE_ATV"
		or video_type == "MUSIC_VIDEO_TYPE_OMV"
		or video_type == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"
end

local function artwork_of(row: any): string?
	local thumbs = path(row, { "thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails" })
	if type(thumbs) ~= "table" then
		return nil
	end
	local best_url = ""
	local best_size = -1
	for _, thumb in thumbs do
		if type(thumb) == "table" and type(thumb.url) == "string" and thumb.url ~= "" then
			local w = if type(thumb.width) == "number" then thumb.width else 0
			if w >= best_size then
				best_size = w
				best_url = thumb.url
			end
		end
	end
	if best_url == "" then
		return nil
	end
	if string.find(best_url, "googleusercontent.com", 1, true) ~= nil then
		return string.gsub(best_url, "=w%d+%-h%d+.*$", "=w300-h300-l90-rj")
	end
	return best_url
end

local function new_item(
	kind: Kind,
	title: string,
	artist: string,
	detail: string,
	video: string,
	duration: number?,
	browse_id: string,
	art: string?
): Item
	return {
		kind = kind,
		title = title,
		artist = artist,
		detail = detail,
		url = if video == "" then "" else "https://www.youtube.com/watch?v=" .. video,
		video = video,
		duration = duration,
		browse_id = browse_id,
		art = art,
	}
end

local function track_from_row(row: any, require_recommendation_type: boolean): Item?
	local video = video_id(row)
	local title = column(row, 1)
	local kind = music_video_type(row)
	if video == "" or title == "" then
		return nil
	end
	if require_recommendation_type then
		if kind ~= "MUSIC_VIDEO_TYPE_ATV" and kind ~= "MUSIC_VIDEO_TYPE_OMV" then
			return nil
		end
	elseif kind ~= "" and not accepted_type(kind) then
		return nil
	end
	-- Column 2 reads "Artist • Album • 3:45" (search) or just "Artist"
	-- (related, playlists): the artist is the first segment, the album the
	-- next one that is not a duration or a play count.
	local parts = segments(column(row, 2))
	local artist = parts[1] or ""
	local album = ""
	for index = 2, #parts do
		local part = parts[index]
		if clock_seconds(part) == nil and not string.find(part, "%d[%d%.,]*[KMB]? plays$") and not string.find(part, "views$") then
			album = part
			break
		end
	end
	local detail = if album ~= "" then artist .. " · " .. album else artist
	return new_item("track", title, artist, detail, video, duration_seconds(row), "", artwork_of(row))
end

local function podcast_episode(row: any): Item?
	local video = video_id(row)
	local title = text(field(row, "title"))
	if video == "" or title == "" then
		return nil
	end
	local kind = music_video_type(row)
	if kind ~= "" and kind ~= "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" then
		return nil
	end
	local detail = column(row, 2)
	return new_item("track", title, detail, detail, video, nil, "", artwork_of(row))
end

local function collect(value: any, key_name: string, output: { any }, depth: number): ()
	if depth > 32 or type(value) ~= "table" then
		return
	end
	for key, child in value do
		if key == key_name and type(child) == "table" then
			table.insert(output, child)
		else
			collect(child, key_name, output, depth + 1)
		end
	end
end

local function decode_response(response: any, done: (document: any?, err: string?) -> ()): ()
	if response.error ~= nil then
		done(nil, "YouTube Music request failed")
		return
	end
	if response.status < 200 or response.status >= 300 then
		done(nil, "YouTube Music returned HTTP " .. tostring(response.status))
		return
	end
	local ok, document = pcall(tern.json.decode, response.body)
	if not ok or type(document) ~= "table" then
		done(nil, "YouTube Music returned invalid search data")
		return
	end
	done(document, nil)
end

local cached_api_key: string? = nil
local last_key_attempt = 0
local KEY_RETRY_COOLDOWN_MS = 30000

local function read_api_key(): (string?, string?)
	local ok, content = pcall(tern.fs.read, SECRETS_FILE, 4096)
	if not ok or type(content) ~= "string" then
		return nil, "Missing .secrets.json with youtube_music_api_key"
	end
	local decoded, secrets = pcall(tern.json.decode, content)
	if not decoded or type(secrets) ~= "table" then
		return nil, "Invalid .secrets.json; expected youtube_music_api_key"
	end
	local key = field(secrets, "youtube_music_api_key")
	if type(key) ~= "string" or string.match(key, "^AIza[%w_-]+$") == nil then
		return nil, "Invalid youtube_music_api_key in .secrets.json"
	end
	return key, nil
end

local function get_api_key(): (string?, string?)
	if cached_api_key ~= nil then
		return cached_api_key, nil
	end
	local now = tern.now()
	if last_key_attempt > 0 and (now - last_key_attempt) < KEY_RETRY_COOLDOWN_MS then
		return nil, "Missing or invalid .secrets.json (retrying in " .. tostring(math.ceil((KEY_RETRY_COOLDOWN_MS - (now - last_key_attempt)) / 1000)) .. "s)"
	end
	last_key_attempt = now
	local key, key_error = read_api_key()
	if key ~= nil then
		cached_api_key = key
		return key, nil
	end
	return nil, key_error
end

local function post(endpoint: string, body: { [string]: any }, done: (document: any?, err: string?) -> ()): ()
	local api_key, key_error = get_api_key()
	if api_key == nil then
		done(nil, key_error)
		return
	end

	body.context = {
		client = {
			clientName = "WEB_REMIX",
			clientVersion = "1." .. os.date("!%Y%m%d", os.time()) .. ".01.00",
			hl = "en",
		},
		user = {},
	}
	local encoded_ok, encoded = pcall(tern.json.encode, body)
	if not encoded_ok or type(encoded) ~= "string" then
		done(nil, "Could not encode YouTube Music request")
		return
	end
	local url = API .. endpoint .. "?alt=json&key=" .. api_key
	net.fetch(url, {
		method = "POST",
		headers = {
			["Content-Type"] = "application/json",
			Origin = "https://music.youtube.com",
			["User-Agent"] = USER_AGENT,
		},
		body = encoded,
		timeout_ms = 15000,
		retries = 1,
	}, function(response: FetchResult)
		decode_response(response, done)
	end)
end

local SEARCH_MEMO_TTL_MS = 10 * 60 * 1000
local BROWSE_MEMO_TTL_MS = 30 * 60 * 1000
local RELATED_MEMO_TTL_MS = 30 * 60 * 1000

function catalog.search(query: string, category: Category, done: (items: { Item }, err: string?) -> ()): ()
	if query == "" then
		done({}, nil)
		return
	end
	local memo_key = "yt:search:" .. category .. ":" .. query
	net.memo(memo_key, SEARCH_MEMO_TTL_MS, function(finish)
		post("search", { query = query, params = SEARCH_PARAMS[category] }, function(document: any?, err: string?)
			if err ~= nil or document == nil then
				finish(nil, err)
				return
			end
			local rows: { any } = {}
			collect(document, "musicResponsiveListItemRenderer", rows, 0)
			local items: { Item } = {}
			local seen: { [string]: boolean } = {}
			for _, row in rows do
				if category == "tracks" then
					local item = track_from_row(row, false)
					if item ~= nil and seen[item.video] ~= true then
						table.insert(items, item)
						seen[item.video] = true
					end
				else
					local browse_id = path(row, { "navigationEndpoint", "browseEndpoint", "browseId" })
					local title = column(row, 1)
					if type(browse_id) == "string" and browse_id ~= "" and title ~= "" and seen[browse_id] ~= true then
						local kind: Kind = if category == "artists"
							then "artist"
							elseif category == "playlists" then "playlist"
							else "podcast"
						local detail = column(row, 2)
						table.insert(
							items,
							new_item(kind, title, if kind == "artist" then title else detail, detail, "", nil, browse_id, artwork_of(row))
						)
						seen[browse_id] = true
					end
				end
				if #items >= LIMIT then
					break
				end
			end
			finish(items, nil)
		end)
	end, function(value: any, err: string?)
		if err ~= nil or value == nil then
			done({}, err)
		else
			done(value :: { Item }, nil)
		end
	end)
end

function catalog.browse(browse_id: string, kind: Kind, done: (items: { Item }, err: string?) -> ()): ()
	local memo_key = "yt:browse:" .. kind .. ":" .. browse_id
	net.memo(memo_key, BROWSE_MEMO_TTL_MS, function(finish)
		post("browse", { browseId = browse_id }, function(document: any?, err: string?)
			if err ~= nil or document == nil then
				finish(nil, err)
				return
			end
			local rows: { any } = {}
			collect(document, "musicResponsiveListItemRenderer", rows, 0)
			local items: { Item } = {}
			local seen: { [string]: boolean } = {}
			for _, row in rows do
				local item = track_from_row(row, false)
				if item ~= nil and seen[item.video] ~= true then
					table.insert(items, item)
					seen[item.video] = true
				end
				if #items >= LIMIT then
					break
				end
			end
			if kind == "podcast" and #items < LIMIT then
				local episodes: { any } = {}
				collect(document, "musicMultiRowListItemRenderer", episodes, 0)
				for _, row in episodes do
					local item = podcast_episode(row)
					if item ~= nil and seen[item.video] ~= true then
						table.insert(items, item)
						seen[item.video] = true
					end
					if #items >= LIMIT then
						break
					end
				end
			end
			finish(items, nil)
		end)
	end, function(value: any, err: string?)
		if err ~= nil or value == nil then
			done({}, err)
		else
			done(value :: { Item }, nil)
		end
	end)
end

function catalog.related(video: string, done: (items: { Item }, err: string?) -> ()): ()
	if video == "" then
		done({}, nil)
		return
	end
	local memo_key = "yt:related:" .. video
	net.memo(memo_key, RELATED_MEMO_TTL_MS, function(finish)
		post("next", {
			videoId = video,
			playlistId = "RDAMVM" .. video,
			enablePersistentPlaylistPanel = true,
			isAudioOnly = true,
			tunerSettingValue = "AUTOMIX_SETTING_NORMAL",
		}, function(document: any?, err: string?)
			if err ~= nil or document == nil then
				finish(nil, err)
				return
			end
			local tabs = path(
				document,
				{ "contents", "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer", "watchNextTabbedResultsRenderer", "tabs" }
			)
			local related_id = ""
			if type(tabs) == "table" then
				for _, tab in tabs do
					if path(tab, { "tabRenderer", "title" }) == "Related" then
						local id = path(tab, { "tabRenderer", "endpoint", "browseEndpoint", "browseId" })
						if type(id) == "string" then
							related_id = id
						end
						break
					end
				end
			end
			if related_id == "" then
				finish({}, nil)
				return
			end
			post("browse", { browseId = related_id }, function(related: any?, related_error: string?)
				if related_error ~= nil or related == nil then
					finish(nil, related_error)
					return
				end
				local rows: { any } = {}
				collect(related, "musicResponsiveListItemRenderer", rows, 0)
				local items: { Item } = {}
				local seen: { [string]: boolean } = {}
				for _, row in rows do
					local item = track_from_row(row, true)
					if item ~= nil and item.video ~= video and seen[item.video] ~= true then
						table.insert(items, item)
						seen[item.video] = true
					end
					if #items >= LIMIT then
						break
					end
				end
				finish(items, nil)
			end)
		end)
	end, function(value: any, err: string?)
		if err ~= nil or value == nil then
			done({}, err)
		else
			done(value :: { Item }, nil)
		end
	end)
end
return catalog
