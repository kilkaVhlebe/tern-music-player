--!strict
-- Network fetch queue with concurrency cap, retry backoff, and TTL memoization.

local net = {}

export type FetchOptions = {
	method: string?,
	headers: { [string]: string }?,
	body: string?,
	timeout_ms: number?,
	retries: number?,
}

export type FetchCallback = (result: FetchResult) -> ()
export type MemoFinish = (value: any, err: string?) -> ()
export type MemoLoad = (finish: MemoFinish) -> ()
export type MemoDone = (value: any, err: string?) -> ()

local MAX_CONCURRENT = 6
local in_flight = 0

type FetchTask = {
	url: string,
	opts: FetchOptions?,
	done: FetchCallback,
	attempt: number,
	max_retries: number,
}

local fetch_queue: { FetchTask } = {}

local function is_transient(result: FetchResult): boolean
	if result.error ~= nil or result.timed_out then
		return true
	end
	if result.status == 429 then
		return true
	end
	if result.status >= 500 and result.status <= 599 then
		return true
	end
	return false
end

local pump_fetch_queue: () -> ()

local function execute_task(task: FetchTask): ()
	local fetch_opts: FetchOptions? = if task.opts ~= nil
		then {
			method = task.opts.method,
			headers = task.opts.headers,
			body = task.opts.body,
			timeout_ms = task.opts.timeout_ms,
		}
		else nil

	-- One attempt settles once: by its callback, or by the watchdog below
	-- when the callback never comes (its hook disabled by a stall). Either
	-- way the concurrency slot is returned and the caller hears back.
	local settled = false
	local function settle(result: FetchResult): ()
		if settled then
			return
		end
		settled = true
		in_flight -= 1
		pump_fetch_queue()

		if is_transient(result) and task.attempt < task.max_retries then
			task.attempt += 1
			local backoff_ms = 400 * task.attempt
			-- Scheduled through both hooks (as in sched.luau): if one was
			-- disabled by a stall, the other still brings the retry back.
			local requeued = false
			local function requeue(): ()
				if requeued then
					return
				end
				requeued = true
				table.insert(fetch_queue, task)
				pump_fetch_queue()
			end
			tern.timer(backoff_ms, function(_cx_timer)
				requeue()
			end)
			tern.sleep(backoff_ms):next(function()
				requeue()
			end)
			return
		end

		local cb_ok, cb_err = pcall(function(): any
			return (task.done :: any)(result)
		end)
		if not cb_ok then
			tern.log.warn("net.fetch consumer callback failed: " .. tostring(cb_err))
		end
	end

	local ok, err_msg = pcall(function()
		tern.fetch(task.url, fetch_opts, function(result: FetchResult, _cx)
			settle(result)
		end)
	end)

	if not ok then
		settle({
			status = 0,
			headers = {},
			body = "",
			error = "fetch failed to start: " .. tostring(err_msg),
			timed_out = false,
		})
		return
	end

	local limit = (if fetch_opts ~= nil and fetch_opts.timeout_ms ~= nil then fetch_opts.timeout_ms else 30000) + 10000
	local function give_up(): ()
		settle({ status = 0, headers = {}, body = "", error = "no response", timed_out = true })
	end
	tern.timer(limit, function(_cx_timer)
		give_up()
	end)
	tern.sleep(limit):next(function()
		give_up()
	end)
end

pump_fetch_queue = function(): ()
	while in_flight < MAX_CONCURRENT and #fetch_queue > 0 do
		local task = table.remove(fetch_queue, 1)
		if task ~= nil then
			in_flight += 1
			execute_task(task)
		end
	end
end

function net.fetch(url: string, opts: FetchOptions?, done: FetchCallback): ()
	local max_retries: number
	if opts ~= nil and opts.retries ~= nil then
		max_retries = opts.retries
	else
		local method = if opts ~= nil and opts.method ~= nil then string.upper(opts.method) else "GET"
		max_retries = if method == "GET" then 1 else 0
	end

	local task: FetchTask = {
		url = url,
		opts = opts,
		done = done,
		attempt = 0,
		max_retries = max_retries,
	}

	table.insert(fetch_queue, task)
	pump_fetch_queue()
end

type LruNode = {
	key: string,
	value: any,
	expires_at: number,
	prev: LruNode?,
	next: LruNode?,
}

local MAX_LRU_ENTRIES = 256
local lru_cache: { [string]: LruNode } = {}
local lru_size = 0
local lru_head: LruNode? = nil
local lru_tail: LruNode? = nil

-- Loads in progress by key: who waits for them and when they started. A load
-- whose answer never came back (a callback hook disabled mid-flight) is given
-- up after MEMO_STALE_MS, so the key does not stay stuck until a reload.
local MEMO_STALE_MS = 45 * 1000
local in_flight_memo: { [string]: { waiters: { MemoDone }, started: number, abandon: (err: string) -> () } } = {}

local function detach_node(node: LruNode): ()
	if node.prev ~= nil then
		node.prev.next = node.next
	else
		lru_head = node.next
	end
	if node.next ~= nil then
		node.next.prev = node.prev
	else
		lru_tail = node.prev
	end
	node.prev = nil
	node.next = nil
end

local function attach_front(node: LruNode): ()
	node.next = lru_head
	node.prev = nil
	if lru_head ~= nil then
		lru_head.prev = node
	else
		lru_tail = node
	end
	lru_head = node
end

local function touch_node(node: LruNode): ()
	if lru_head == node then
		return
	end
	detach_node(node)
	attach_front(node)
end

local function evict_tail(): ()
	local old_tail = lru_tail
	if old_tail == nil then
		return
	end
	detach_node(old_tail)
	lru_cache[old_tail.key] = nil
	lru_size -= 1
end

local function invoke_memo_done(done: MemoDone, value: any, err: string?): ()
	local ok, cb_err = pcall(function(): any
		return (done :: any)(value, err)
	end)
	if not ok then
		tern.log.warn("net.memo consumer callback failed: " .. tostring(cb_err))
	end
end

function net.memo(
	key: string,
	ttl_ms: number,
	load: (finish: (value: any, err: string?) -> ()) -> (),
	done: (value: any, err: string?) -> ()
): ()
	local cached = lru_cache[key]
	if cached ~= nil then
		local now = tern.now()
		if now < cached.expires_at then
			touch_node(cached)
			invoke_memo_done(done, cached.value, nil)
			return
		else
			detach_node(cached)
			lru_cache[key] = nil
			lru_size -= 1
		end
	end

	local waiting = in_flight_memo[key]
	if waiting ~= nil then
		if tern.now() - waiting.started < MEMO_STALE_MS then
			table.insert(waiting.waiters, done)
			return
		end
		waiting.abandon("request timed out")
	end

	local waiters: { MemoDone } = { done }

	local finished = false
	local function finish(val: any, err: string?): ()
		if finished then
			return
		end
		finished = true

		if in_flight_memo[key] ~= nil and in_flight_memo[key].waiters == waiters then
			in_flight_memo[key] = nil
		end

		if err == nil then
			local existing = lru_cache[key]
			if existing ~= nil then
				existing.value = val
				existing.expires_at = tern.now() + ttl_ms
				touch_node(existing)
			else
				if lru_size >= MAX_LRU_ENTRIES then
					evict_tail()
				end
				local new_node: LruNode = {
					key = key,
					value = val,
					expires_at = tern.now() + ttl_ms,
					prev = nil,
					next = nil,
				}
				lru_cache[key] = new_node
				attach_front(new_node)
				lru_size += 1
			end
		end

		for _, cb in waiters do
			invoke_memo_done(cb, val, err)
		end
	end

	in_flight_memo[key] = {
		waiters = waiters,
		started = tern.now(),
		abandon = function(err: string)
			finish(nil, err)
		end,
	}

	local ok, load_err = pcall(function(): any
		return (load :: any)(finish)
	end)
	if not ok then
		tern.log.warn("net.memo load function failed: " .. tostring(load_err))
		finish(nil, tostring(load_err))
	end
end

function net.forget(prefix: string): ()
	local prefix_len = #prefix
	local current = lru_head
	while current ~= nil do
		local next_node = current.next
		if prefix_len == 0 or string.sub(current.key, 1, prefix_len) == prefix then
			detach_node(current)
			lru_cache[current.key] = nil
			lru_size -= 1
		end
		current = next_node
	end
end

return net
