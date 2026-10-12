-- All of the player's passenger lines, one row each, for the More Line
-- Stats window. Reuses lineStatsHelper.collect per line (about 1 ms each).
-- Engine reads: runs in an event handler (the HUD button, Refresh) or on a
-- timer thread, never in a recipe body. Plain tables out.
-- Types in tealdef/mls_def.d.tl (MlsLinesHelper).

local LINE_STATS_HELPER : string = "bottle_more_line_stats::/scripts/line_stats_helper.script.tl"
local LUA_UTILS : string = "bottle_more_line_stats::/scripts/lua_utils.script.tl"
local lineStatsHelper = require(LINE_STATS_HELPER) as MlsLineStatsHelper
local luaUtils = require(LUA_UTILS) as MlsLuaUtils

local function rowOf(stats : MlsLineStats) : MlsLineRow
	local demand = stats.onBoard + stats.waitingTotal
	-- The busiest stop: the most passengers waiting at any one stop.
	local busiest = 0
	for _, waitingAtStop in ipairs(stats.waiting) do
		if waitingAtStop > busiest then busiest = waitingAtStop end
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

local function collectAllUnsafe() : MlsLinesTable
	local linesTable : MlsLinesTable = { rows = {}, cargoLines = 0, otherLines = 0 }
	local player = api.engine.util.getPlayer()
	for _, lineId in ipairs(api.engine.system.lineSystem.getLinesForPlayer(player)) do
		local stats = lineStatsHelper.collect(lineId)
		if stats.kind == "passenger" then
			linesTable.rows[#linesTable.rows + 1] = rowOf(stats)
		elseif stats.kind == "cargo" then
			linesTable.cargoLines = linesTable.cargoLines + 1
		else
			linesTable.otherLines = linesTable.otherLines + 1
		end
	end
	return linesTable
end

-- Never throws: a failure shows as a message in the window.
local function collectAll() : MlsLinesTable
	local ok, result = pcall(collectAllUnsafe)
	if ok then return result as MlsLinesTable end
	luaUtils.log("collectAll failed: " .. tostring(result))
	return { rows = {}, cargoLines = 0, otherLines = 0, error = tostring(result) }
end

local exports : MlsLinesHelper = {
	collectAll = collectAll,
}
return exports
