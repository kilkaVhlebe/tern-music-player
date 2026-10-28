--!strict
-- A heartbeat that survives one of its wake-up hooks being disabled.
--
-- Tern disables a hook for the rest of the VM's life when one call of it
-- runs past its budget (2 s on the host, 50 ms in a window). A system that
-- sleeps or stalls mid-callback trips that through no fault of the code, and
-- with a single `tern.timer` loop the player then freezes until a plugin
-- reload. So every beat is scheduled twice: once through `tern.timer` (hook
-- `timer`) and once through `tern.sleep(...):next` (hook `await`). Whichever
-- fires first runs the work; the other sees it ran and only reschedules. If
-- one hook is disabled, the other chain keeps the beat alive.

local sched = {}

export type Beat = {
	-- Stops both chains; the work never runs again.
	stop: () -> (),
	-- Runs the work at the next opportunity instead of waiting a full interval.
	poke: () -> (),
}

-- Runs `work` every `interval_ms` until it returns `false` or `stop` is called.
-- `work` receives the window `cx` when there is one (window half only).
function sched.every(interval_ms: number, work: (cx: any) -> boolean?): Beat
	local stopped = false
	local last_run = -math.huge
	local poked = false

	local function run(cx: any): ()
		if stopped then
			return
		end
		local now = tern.now()
		-- The twin chain fired moments ago: this wake-up is its echo.
		if not poked and now - last_run < interval_ms * 0.6 then
			return
		end
		poked = false
		last_run = now
		local ok, keep = pcall(work, cx)
		if not ok then
			tern.log.warn("ytmusic: heartbeat work failed", tostring(keep))
		elseif keep == false then
			stopped = true
		end
	end

	-- Each chain reschedules itself before running the work, so a work call
	-- that trips the budget still leaves the next wake-up queued (it is then
	-- dropped only if the hook itself got disabled).
	local function timer_chain(delay: number): ()
		tern.timer(delay, function(cx: any)
			if stopped then
				return
			end
			timer_chain(interval_ms)
			run(cx)
		end)
	end

	local function await_chain(delay: number): ()
		tern.sleep(delay):next(function(_result: any, _err: string?, cx: any)
			if stopped then
				return
			end
			await_chain(interval_ms)
			run(cx)
		end)
	end

	timer_chain(0)
	await_chain(0)

	return {
		stop = function()
			stopped = true
		end,
		poke = function()
			if stopped then
				return
			end
			poked = true
			tern.timer(0, function(cx: any)
				run(cx)
			end)
		end,
	}
end

return sched
