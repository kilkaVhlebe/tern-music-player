--!strict
-- Public YouTube Music search and related-track endpoints.
-- The API is undocumented; category filtering keeps results inside the music catalog.
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
}

local API = "https://music.youtube.com/youtubei/v1/"
local API_KEY = "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"
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

local function duration_seconds(row: any): number?
	local columns = field(row, "flexColumns")
	if type(columns) ~= "table" then
		return nil
	end
	for _, flex in columns do
		local value = text(path(flex, { "musicResponsiveListItemFlexColumnRenderer", "text" }))
		local hours, minutes, seconds = string.match(value, "^(%d+):(%d%d):(%d%d)$")
		if hours ~= nil and minutes ~= nil and seconds ~= nil then
			return (tonumber(hours) or 0) * 3600 + (tonumber(minutes) or 0) * 60 + (tonumber(seconds) or 0)
		end
		minutes, seconds = string.match(value, "^(%d+):(%d%d)$")
		if minutes ~= nil and seconds ~= nil then
			return (tonumber(minutes) or 0) * 60 + (tonumber(seconds) or 0)
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

local function new_item(kind: Kind, title: string, artist: string, detail: string, video: string, duration: number?, browse_id: string): Item
	return {
		kind = kind,
		title = title,
		artist = artist,
		detail = detail,
		url = if video == "" then "" else "https://www.youtube.com/watch?v=" .. video,
		video = video,
		duration = duration,
		browse_id = browse_id,
	}
end

local function track_from_row(row: any, require_recommendation_type: boolean): Item?
	local video = video_id(row)
	local title = column(row, 1)
	local artist = column(row, 2)
	local kind = music_video_type(row)
	if video == "" or title == "" then
		return nil
	end
	if require_recommendation_type and (kind ~= "MUSIC_VIDEO_TYPE_ATV" and kind ~= "MUSIC_VIDEO_TYPE_OMV") then
		return nil
	end
	if kind ~= "" and not accepted_type(kind) then
		return nil
	end
	return new_item("track", title, artist, artist, video, duration_seconds(row), "")
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
	return new_item("track", title, detail, detail, video, nil, "")
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
		done(nil, tostring(response.error))
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

local function post(endpoint: string, body: { [string]: any }, done: (document: any?, err: string?) -> ()): ()
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
	local url = API .. endpoint .. "?alt=json&key=" .. API_KEY
	local started, failure = pcall(function()
		tern.fetch(url, {
			method = "POST",
			headers = {
				["Content-Type"] = "application/json",
				Origin = "https://music.youtube.com",
				["User-Agent"] = USER_AGENT,
			},
			body = encoded,
			timeout_ms = 15000,
		}, function(response: FetchResult, _cx)
			decode_response(response, done)
		end)
	end)
	if not started then
		done(nil, tostring(failure))
	end
end

function catalog.search(query: string, category: Category, done: (items: { Item }, err: string?) -> ()): ()
	if query == "" then
		done({}, nil)
		return
	end
	post("search", { query = query, params = SEARCH_PARAMS[category] }, function(document: any?, err: string?)
		if err ~= nil or document == nil then
			done({}, err)
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
					local kind: Kind = if category == "artists" then "artist" elseif category == "playlists" then "playlist" else "podcast"
					local detail = column(row, 2)
					table.insert(items, new_item(kind, title, if kind == "artist" then title else detail, detail, "", nil, browse_id))
					seen[browse_id] = true
				end
			end
			if #items >= LIMIT then
				break
			end
		end
		done(items, nil)
	end)
end

function catalog.browse(browse_id: string, kind: Kind, done: (items: { Item }, err: string?) -> ()): ()
	post("browse", { browseId = browse_id }, function(document: any?, err: string?)
		if err ~= nil or document == nil then
			done({}, err)
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
		done(items, nil)
	end)
end

function catalog.related(video: string, done: (items: { Item }, err: string?) -> ()): ()
	if video == "" then
		done({}, nil)
		return
	end
	post("next", {
		videoId = video,
		playlistId = "RDAMVM" .. video,
		enablePersistentPlaylistPanel = true,
		isAudioOnly = true,
		tunerSettingValue = "AUTOMIX_SETTING_NORMAL",
	}, function(document: any?, err: string?)
		if err ~= nil or document == nil then
			done({}, err)
			return
		end
		local tabs = path(document, { "contents", "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer", "watchNextTabbedResultsRenderer", "tabs" })
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
			done({}, nil)
			return
		end
		post("browse", { browseId = related_id }, function(related: any?, related_error: string?)
			if related_error ~= nil or related == nil then
				done({}, related_error)
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
			done(items, nil)
		end)
	end)
end

return catalog
