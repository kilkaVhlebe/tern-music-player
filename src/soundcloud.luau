--!strict
-- SoundCloud search via direct api-v2 with scraped client_id and yt-dlp fallback.

local process = require("./process")
local yt = require("./ytmusic")
local catalog = require("./catalog")
local net = require("./net")

local SEARCH_LIMIT = 15
local SEARCH_TIMEOUT_MS = 15000
local SEARCH_MEMO_TTL_MS = 10 * 60 * 1000

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

local function urlencode(s: string): string
	return (string.gsub(s, "([^%w%-_%.~])", function(c: string): string
		return string.format("%%%02X", string.byte(c))
	end))
end

-- Thumbnail helper for yt-dlp fallback entries
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

local function item_from_ytdlp(entry: any): catalog.Item?
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
	local art = artwork_of(entry)
	return {
		kind = "track",
		title = title,
		artist = artist,
		detail = artist,
		url = url,
		video = "",
		duration = number_field(entry, "duration"),
		browse_id = "",
		art = if art ~= "" then art else nil,
	}
end

-- Bounded FIFO queue for yt-dlp fallback (at most 1 concurrent, queue bound 4)
type YtDlpJob = {
	query: string,
	done: (items: { catalog.Item }, err: string?) -> (),
}

local ytdlp_active = false
local ytdlp_queue: { YtDlpJob } = {}

local function pump_ytdlp_queue(): ()
	if ytdlp_active or #ytdlp_queue == 0 then
		return
	end
	local job = table.remove(ytdlp_queue, 1)
	if job == nil then
		return
	end
	ytdlp_active = true
	local term = string.format("scsearch%d:%s", SEARCH_LIMIT, job.query)
	local env = yt.tool_env()
	env["PYTHONIOENCODING"] = "utf-8"

	local function on_result(result: ProcessResult): ()
		ytdlp_active = false
		pump_ytdlp_queue()

		if result.timed_out then
			job.done({}, "SoundCloud search timed out")
			return
		end
		if result.status ~= 0 then
			local detail = string.match(result.stderr, "[^\r\n]+")
			job.done({}, "SoundCloud search failed: " .. yt.cut(detail or "yt-dlp exited " .. tostring(result.status), 140))
			return
		end
		local ok, document = pcall(tern.json.decode, result.stdout)
		if not ok or type(document) ~= "table" then
			job.done({}, "SoundCloud search returned invalid data")
			return
		end
		local entries = document.entries
		if type(entries) ~= "table" then
			job.done({}, nil)
			return
		end
		local items: { catalog.Item } = {}
		for _, entry in entries do
			local item = item_from_ytdlp(entry)
			if item ~= nil then
				table.insert(items, item)
			end
			if #items >= SEARCH_LIMIT then
				break
			end
		end
		job.done(items, nil)
	end

	-- A yt-dlp that cannot start must not leave the queue locked.
	local started, failure = pcall(function()
		process.run({ yt.ytdlp_bin(), "--encoding", "utf-8", "--flat-playlist", "-J", term }, {
			timeout_ms = SEARCH_TIMEOUT_MS,
			env = env,
		}, on_result)
	end)
	if not started then
		ytdlp_active = false
		job.done({}, "yt-dlp did not start: " .. yt.cut(tostring(failure), 140))
		pump_ytdlp_queue()
	end
end

local function search_ytdlp(query: string, done: (items: { catalog.Item }, err: string?) -> ()): ()
	if #ytdlp_queue >= 4 then
		local oldest = table.remove(ytdlp_queue, 1)
		if oldest ~= nil then
			oldest.done({}, "superseded")
		end
	end
	table.insert(ytdlp_queue, { query = query, done = done })
	pump_ytdlp_queue()
end

-- Client ID scraping and caching
local cached_client_id: string? = nil
local client_id_waiters: { (id: string?, err: string?) -> () }? = nil

local function extract_scripts(html: string): { string }
	local list: { string } = {}
	local seen: { [string]: boolean } = {}
	for url in string.gmatch(html, 'src="(https://a%-v2%.sndcdn%.com/assets/[^"]+%.js)"') do
		if not seen[url] then
			seen[url] = true
			table.insert(list, url)
		end
	end
	if #list == 0 then
		for url in string.gmatch(html, 'https://a%-v2%.sndcdn%.com/assets/[%w%-_%.]+%.js') do
			if not seen[url] then
				seen[url] = true
				table.insert(list, url)
			end
		end
	end
	return list
end

local function find_client_id_in_text(text: string): string?
	for id in string.gmatch(text, 'client_id[:=]"?([%w]+)"?') do
		if #id >= 30 and #id <= 40 then
			return id
		end
	end
	return nil
end

local function get_client_id(refresh: boolean, done: (id: string?, err: string?) -> ()): ()
	if not refresh then
		if cached_client_id ~= nil then
			done(cached_client_id, nil)
			return
		end
		local ok_kv, kv_id = pcall(function(): any
			return (tern.kv.get :: any)("soundcloud_client_id")
		end)
		if ok_kv and type(kv_id) == "string" and #kv_id >= 30 and #kv_id <= 40 then
			cached_client_id = kv_id
			done(kv_id, nil)
			return
		end
	end

	cached_client_id = nil
	pcall(function(): any
		return (tern.kv.set :: any)("soundcloud_client_id", nil)
	end)

	if client_id_waiters ~= nil then
		table.insert(client_id_waiters, done)
		return
	end
	client_id_waiters = { done }

	local function finish_id(id: string?, err: string?): ()
		local waiters = client_id_waiters
		client_id_waiters = nil
		if waiters ~= nil then
			for _, cb in waiters do
				cb(id, err)
			end
		end
	end

	net.fetch("https://soundcloud.com/", {
		method = "GET",
		headers = {
			["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
		},
		timeout_ms = 15000,
		retries = 1,
	}, function(res: FetchResult)
		if res.status ~= 200 or res.body == "" then
			finish_id(nil, "Failed to fetch soundcloud.com: HTTP " .. tostring(res.status))
			return
		end
		local scripts = extract_scripts(res.body)
		if #scripts == 0 then
			finish_id(nil, "No asset scripts found on soundcloud.com")
			return
		end

		local current_idx = #scripts
		local check_next_script: () -> ()
		check_next_script = function(): ()
			if current_idx < 1 then
				finish_id(nil, "client_id not found in soundcloud assets")
				return
			end
			local script_url = scripts[current_idx]
			current_idx -= 1
			net.fetch(script_url, {
				method = "GET",
				timeout_ms = 15000,
				retries = 1,
			}, function(script_res: FetchResult)
				if script_res.status == 200 and script_res.body ~= "" then
					local id = find_client_id_in_text(script_res.body)
					if id ~= nil then
						cached_client_id = id
						pcall(function(): any
							return (tern.kv.set :: any)("soundcloud_client_id", id)
						end)
						finish_id(id, nil)
						return
					end
				end
				check_next_script()
			end)
		end

		check_next_script()
	end)
end

-- Direct api-v2 search
local function search_direct(
	query: string,
	client_id: string,
	can_refresh: boolean,
	done: (items: { catalog.Item }?, err: string?) -> ()
): ()
	local search_url = "https://api-v2.soundcloud.com/search/tracks?q="
		.. urlencode(query)
		.. "&client_id="
		.. client_id
		.. "&limit=15&offset=0&linked_partitioning=1"

	net.fetch(search_url, {
		method = "GET",
		headers = {
			["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
		},
		timeout_ms = 15000,
		retries = 1,
	}, function(res: FetchResult)
		if res.status == 401 or res.status == 403 then
			if can_refresh then
				get_client_id(true, function(new_id: string?, id_err: string?)
					if new_id ~= nil then
						search_direct(query, new_id, false, done)
					else
						done(nil, "Failed to refresh client_id: " .. tostring(id_err))
					end
				end)
				return
			else
				done(nil, "SoundCloud api-v2 returned HTTP " .. tostring(res.status))
				return
			end
		end

		if res.status ~= 200 or res.error ~= nil then
			done(nil, "SoundCloud api-v2 request failed: " .. (res.error or ("HTTP " .. tostring(res.status))))
			return
		end

		local ok, doc = pcall(tern.json.decode, res.body)
		if not ok or type(doc) ~= "table" then
			done(nil, "SoundCloud api-v2 returned invalid JSON")
			return
		end

		local collection = doc.collection
		if type(collection) ~= "table" then
			done({}, nil)
			return
		end

		local items: { catalog.Item } = {}
		for _, entry in collection do
			if type(entry) ~= "table" then
				continue
			end
			if entry.streamable == false or entry.policy == "BLOCK" then
				continue
			end
			local title = string_field(entry, "title")
			local url = string_field(entry, "permalink_url")
			if title == "" or url == "" then
				continue
			end
			local user = entry.user
			local artist = string_field(user, "username")
			local duration_ms = number_field(entry, "duration")
			local duration_s = if duration_ms ~= nil then math.floor(duration_ms / 1000) else nil
			local art = string_field(entry, "artwork_url")
			if art ~= "" then
				art = string.gsub(art, "%-large%.", "-t500x500.")
			else
				art = string_field(user, "avatar_url")
				if art ~= "" then
					art = string.gsub(art, "%-large%.", "-t500x500.")
				end
			end

			table.insert(items, {
				kind = "track",
				title = title,
				artist = artist,
				detail = artist,
				url = url,
				video = "",
				duration = duration_s,
				browse_id = "",
				art = if art ~= "" then art else nil,
			})
			if #items >= SEARCH_LIMIT then
				break
			end
		end

		done(items, nil)
	end)
end

local function execute_search(query: string, done: (items: { catalog.Item }, err: string?) -> ()): ()
	get_client_id(false, function(client_id: string?, id_err: string?)
		if client_id == nil then
			tern.log.warn("SoundCloud client_id unavailable (" .. tostring(id_err) .. "), falling back to yt-dlp")
			search_ytdlp(query, done)
			return
		end

		search_direct(query, client_id, true, function(items: { catalog.Item }?, direct_err: string?)
			if items ~= nil then
				done(items, nil)
				return
			end
			tern.log.warn("SoundCloud direct search failed (" .. tostring(direct_err) .. "), falling back to yt-dlp")
			search_ytdlp(query, done)
		end)
	end)
end

function soundcloud.search(query: string, done: (items: { catalog.Item }, err: string?) -> ()): ()
	if query == "" then
		done({}, nil)
		return
	end
	local memo_key = "sc:search:" .. query
	net.memo(memo_key, SEARCH_MEMO_TTL_MS, function(finish)
		execute_search(query, function(items: { catalog.Item }, err: string?)
			if err ~= nil then
				finish(nil, err)
			else
				finish(items, nil)
			end
		end)
	end, function(value: any, err: string?)
		if err ~= nil or value == nil then
			done({}, err)
		else
			done(value :: { catalog.Item }, nil)
		end
	end)
end

return soundcloud
