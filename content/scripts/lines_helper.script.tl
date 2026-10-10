-- All of the player's passenger lines, one row each, for the More Line
-- Stats window. Reuses lineStatsHelper.collect per line (about 1 ms each).
-- Engine reads: runs in an event handler (the HUD button, Refresh) or on a
-- timer thread, never in a recipe body. Plain tables out.
-- Types in tealdef/mls_def.d.tl (MlsLinesHelper).

local LINE_STATS_HELPER : string = "bottle_more_line_stats::/scripts/line_stats_helper.script.tl"
local LUA_UTILS : string = "bottle_more_line_stats::/scripts/lua_utils.script.tl"
local lineStatsHelper = require(LINE_STATS_HELPER) as MlsLineStatsHelper
local luaUtils = require(LUA_UTILS) as MlsLuaUtils

local CT = api.type.ComponentType

local function rowOf(stats : MlsLineStats) : MlsLineRow
	local demand = stats.onBoard + stats.waitingTotal
	-- The busiest stop: the most passengers waiting at any one stop.
	local busiest = 0
	for _, w in ipairs(stats.waiting) do
		if w > busiest then busiest = w end
	end
	local pct : integer = 0
	if stats.capacity > 0 then
		pct = math.floor(demand * 100 / stats.capacity + 0.5) as integer
	end
	return {
		lineId = stats.lineId,
		name = stats.name,
		kind = stats.carrier,
		numVehicles = stats.numVehicles,
		demand = demand,
		demandPct = pct,
		onBoard = stats.onBoard,
		capacity = stats.capacity,
		waiting = stats.waitingTotal,
		unhappy = stats.unhappyWaitingTotal + stats.unhappyOnBoard,
		busiest = busiest,
		journey = stats.journey,
		frequency = stats.frequency,
	}
end

-- Today's game date in the player's format, "?" if it can't be read.
local function gameDate() : string
	local ok, result = pcall(function() : string
		local gt = api.engine.getComponent(api.engine.util.getWorld(), CT.GAME_TIME) as Engine.Component.GameTime
		local date = api.engine.util.getCalendarDate(gt.gameTime)
		return api.util.formatDate(date, api.type.enum.DateFormat.MEDIUM)
	end)
	if ok then return result as string end
	luaUtils.log("game date failed: " .. tostring(result))
	return "?"
end

local function collectAllUnsafe() : MlsLinesTable
	local t : MlsLinesTable = { rows = {}, cargoLines = 0, otherLines = 0, asOf = gameDate() }
	local player = api.engine.util.getPlayer()
	for _, lineId in ipairs(api.engine.system.lineSystem.getLinesForPlayer(player)) do
		local stats = lineStatsHelper.collect(lineId)
		if stats.kind == "passenger" then
			t.rows[#t.rows + 1] = rowOf(stats)
		elseif stats.kind == "cargo" then
			t.cargoLines = t.cargoLines + 1
		else
			t.otherLines = t.otherLines + 1
		end
	end
	return t
end

-- Never throws: a failure shows as a message in the window.
local function collectAll() : MlsLinesTable
	local ok, result = pcall(collectAllUnsafe)
	if ok then return result as MlsLinesTable end
	luaUtils.log("collectAll failed: " .. tostring(result))
	return { rows = {}, cargoLines = 0, otherLines = 0, asOf = "?", error = tostring(result) }
end

local M : MlsLinesHelper = {
	collectAll = collectAll,
}
return M
