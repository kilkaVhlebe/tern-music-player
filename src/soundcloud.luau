--!strict
-- SoundCloud search through yt-dlp's `scsearch:` selector.
--
-- yt-dlp talks to SoundCloud's own search endpoint and handles the client id
-- it needs internally, so the plugin starts no extra services of its own and
-- mpv's ytdl hook already plays the resulting `soundcloud.com` URLs. With
-- `--flat-playlist` one `scsearchN:` call answers with a JSON playlist whose
-- entries are the search results themselves: title, uploader, duration,
-- permalink and artwork in a single process run.
local process = require("./process")
local yt = require("./ytmusic")
local catalog = require("./catalog")

local SEARCH_LIMIT = 15
local SEARCH_TIMEOUT_MS = 15000

local soundcloud = {}

local function string_field(value: any, key: string): string
	if type(value) == "table" and type(value[key]) == "string" then
		return value[key] :: string
	end
	return ""
end

local function number_field(value: any, key: string): number?
	if type(value) == "table" and type(value[key]) == "number" then
		return value[key] :: number
	end
	return nil
end

-- The artwork URL of a search entry: SoundCloud uploads carry a thumbnail
-- ladder whose `t500x500` matches what its oEmbed endpoint reports, and the
-- last entry is the largest when the ids are unfamiliar.
local function artwork_of(entry: any): string
	if type(entry) ~= "table" or type(entry.thumbnails) ~= "table" then
		return ""
	end
	local fallback = ""
	for _, thumb in entry.thumbnails do
		local url = string_field(thumb, "url")
		if url == "" then
			continue
		end
		local id = string_field(thumb, "id")
		if id == "t500x500" then
			return url
		end
		fallback = url
	end
	return fallback
end

local function item_from(entry: any): catalog.Item?
	if type(entry) ~= "table" then
		return nil
	end
	local title = string_field(entry, "title")
	local url = string_field(entry, "webpage_url")
	if url == "" then
		url = string_field(entry, "url")
	end
	local is_http = string.sub(url, 1, 7) == "http://" or string.sub(url, 1, 8) == "https://"
	if title == "" or not is_http then
		return nil
	end
	local artist = string_field(entry, "uploader")
	return {
		kind = "track",
		title = title,
		artist = artist,
		detail = artist,
		url = url,
		video = "",
		duration = number_field(entry, "duration"),
		browse_id = "",
		art = artwork_of(entry),
	}
end

function soundcloud.search(query: string, done: (items: { catalog.Item }, err: string?) -> ()): ()
	if query == "" then
		done({}, nil)
		return
	end
	local term = string.format("scsearch%d:%s", SEARCH_LIMIT, query)
	process.run({ yt.ytdlp_bin(), "--flat-playlist", "-J", term }, {
		timeout_ms = SEARCH_TIMEOUT_MS,
		env = yt.tool_env(),
	}, function(result: ProcessResult)
		if result.timed_out then
			done({}, "SoundCloud search timed out")
			return
		end
		if result.status ~= 0 then
			local detail = string.match(result.stderr, "[^\r\n]+")
			done({}, "SoundCloud search failed: " .. yt.cut(detail or "yt-dlp exited " .. tostring(result.status), 140))
			return
		end
		local ok, document = pcall(tern.json.decode, result.stdout)
		if not ok or type(document) ~= "table" then
			done({}, "SoundCloud search returned invalid data")
			return
		end
		local entries = document.entries
		if type(entries) ~= "table" then
			done({}, nil)
			return
		end
		local items: { catalog.Item } = {}
		for _, entry in entries do
			local item = item_from(entry)
			if item ~= nil then
				table.insert(items, item)
			end
			if #items >= SEARCH_LIMIT then
				break
			end
		end
		done(items, nil)
	end)
end

return soundcloud
