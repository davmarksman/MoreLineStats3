-- Competing lines: for a stop S of a line, every later station T on the
-- line and the player's other passenger lines that also go from S to T,
-- with their S->T times. Port of the TF2 mod's
-- stationsHelper, except that only the player's passenger lines count and
-- each line is read once per calculation.
--
-- getCompeting() runs inside engine_react_util.useStepStateTimer, on a game
-- worker thread: only api.engine.* / api.res.* reads, plain
-- Lua tables out, no writes to module-level state.
--
-- Types in tealdef/mls_def.d.tl (MlsStationsHelper, MlsCompeting).

local JOURNEY_HELPER : string = "bottle_more_line_stats::/scripts/journeyHelper.script.tl"
local LINE_STATS_HELPER : string = "bottle_more_line_stats::/scripts/lineStatsHelper.script.tl"
local LUA_UTILS : string = "bottle_more_line_stats::/scripts/luaUtils.script.tl"
local journeyHelper = require(JOURNEY_HELPER) as MlsJourneyHelper
local lineStatsHelper = require(LINE_STATS_HELPER) as MlsLineStatsHelper
local luaUtils = require(LUA_UTILS) as MlsLuaUtils

-- What we need of one line, read once per calculation.
local record LineData
	name : string
	stops : {Engine.Entity}   -- station group per stop, 1-based
	legs : {MlsLeg}           -- empty unless passenger
	passenger : boolean
end

local function entityName(e : Engine.Entity) : string
	if e == nil or not api.engine.entityExists(e) then return "?" end
	return api.engine.util.getEntityName(e) or "?"
end

local function readLine(lineId : Engine.Entity) : LineData
	local data : LineData = { name = "?", stops = {}, legs = {}, passenger = false }
	if lineId == nil or not api.engine.entityExists(lineId) then return data end
	data.name = entityName(lineId)
	local line = api.engine.getComponent(lineId, api.type.ComponentType.LINE) as Engine.Component.Line
	if line ~= nil and line.stops ~= nil then
		for i, stop in ipairs(line.stops) do
			data.stops[i] = stop.stationGroup
		end
	end
	data.passenger = lineStatsHelper.lineKind(lineId) == "passenger"
	if data.passenger then
		data.legs = journeyHelper.getLegs(lineId, #data.stops)
	end
	return data
end

-- The cache is local to one calculation (no module state).
local function getLineData(cache : {Engine.Entity : LineData}, lineId : Engine.Entity) : LineData
	local data = cache[lineId]
	if data == nil then
		data = readLine(lineId)
		cache[lineId] = data
	end
	return data
end

-- A line's travel time between two stations.
local record Travel
	time : number        -- seconds; 0 = unknown or never reached
	estimated : boolean  -- any leg on the path is estimated
end

-- Shortest time from station `from` to station `to` on one line: walk
-- forward (wrapping) from every stop at `from`, summing leg times until a
-- stop at `to`, and keep the minimum. A path is unknown if any leg on it
-- has no time.
local function timeBetween(data : LineData, from : Engine.Entity, to : Engine.Entity) : Travel
	local best : Travel = { time = 0, estimated = false }
	local n = #data.stops
	for i = 1, n do
		if data.stops[i] == from then
			local total : number = 0
			local estimated = false
			local known = true
			local reached = false
			local j = i
			for _ = 1, n do
				local leg = data.legs[j]
				if leg == nil or leg.time <= 0 then
					known = false
					break
				end
				total = total + leg.time
				-- Already slower than the best path found: stop walking.
				if best.time > 0 and total >= best.time then
					known = false
					break
				end
				estimated = estimated or leg.estimated
				j = (j % n) + 1
				if data.stops[j] == to then
					reached = true
					break
				end
			end
			if known and reached and (best.time <= 0 or total < best.time) then
				best.time = total
				best.estimated = estimated
			end
		end
	end
	return best
end

local function toSet(list : {Engine.Entity}) : {Engine.Entity : boolean}
	local set : {Engine.Entity : boolean} = {}
	if list ~= nil then
		for _, e in ipairs(list) do set[e] = true end
	end
	return set
end

-- Known times ascending, unknown (0) last; ties by line id so the order
-- is stable between refreshes.
local function byTime(a : MlsCompetingLine, b : MlsCompetingLine) : boolean
	local ta : number = a.time > 0 and a.time or math.huge
	local tb : number = b.time > 0 and b.time or math.huge
	if ta ~= tb then return ta < tb end
	return a.lineId < b.lineId
end

local function emptyResult() : MlsCompeting
	return { fromStationGroup = nil, fromName = "?", destinations = {} }
end

local function getCompetingUnsafe(lineId : Engine.Entity, stopIndex : integer) : MlsCompeting
	local result = emptyResult()
	if lineId == nil or not api.engine.entityExists(lineId) then return result end

	local cache : {Engine.Entity : LineData} = {}
	local this = getLineData(cache, lineId)
	local n = #this.stops
	if n < 2 or stopIndex == nil or stopIndex < 1 or stopIndex > n then return result end

	local from : Engine.Entity = this.stops[stopIndex]
	result.fromStationGroup = from
	result.fromName = entityName(from)

	local lineSystem = api.engine.system.lineSystem
	local playerLines = toSet(lineSystem.getLinesForPlayer(api.engine.util.getPlayer()))
	local linesAtFrom = toSet(lineSystem.getLinesForStationGroup(from))

	-- Walk forward from S through every later stop, wrapping. Out-and-back
	-- lines visit a station twice, so skip station groups already seen.
	local seen : {Engine.Entity : boolean} = { [from] = true }
	local idx = stopIndex
	for _ = 1, n - 1 do
		idx = (idx % n) + 1
		local to : Engine.Entity = this.stops[idx]
		if not seen[to] then
			seen[to] = true
			local lines : {MlsCompetingLine} = {}
			for _, other in ipairs(lineSystem.getLinesForStationGroup(to)) do
				if other ~= lineId and linesAtFrom[other] and playerLines[other] then
					-- A competitor that fails to read is skipped, not the whole panel.
					local ok, err : boolean, any = pcall(function()
						local data = getLineData(cache, other)
						if data.passenger then
							local t = timeBetween(data, from, to)
							lines[#lines + 1] = {
								lineId = other,
								name = data.name,
								time = t.time,
								estimated = t.estimated,
								isThisLine = false,
							}
						end
					end)
					if not ok then
						luaUtils.log("skipping line " .. tostring(other) .. ": " .. tostring(err))
					end
				end
			end
			-- Destinations served only by this line are left out.
			if #lines > 0 then
				local own = timeBetween(this, from, to)
				lines[#lines + 1] = {
					lineId = lineId,
					name = this.name,
					time = own.time,
					estimated = own.estimated,
					isThisLine = true,
				}
				table.sort(lines, byTime)
				result.destinations[#result.destinations + 1] = {
					stationGroup = to,
					name = entityName(to),
					lines = lines,
					thisLineTime = own.time,
					thisLineEstimated = own.estimated,
				}
			end
		end
	end
	return result
end

-- Never throws: a failure must not break the window.
local function getCompeting(lineId : Engine.Entity, stopIndex : integer) : MlsCompeting
	local ok, result = pcall(getCompetingUnsafe, lineId, stopIndex)
	if ok then return result as MlsCompeting end
	local failed = emptyResult()
	failed.error = tostring(result)
	luaUtils.log("getCompeting failed for line " .. tostring(lineId)
		.. " stop " .. tostring(stopIndex) .. ": " .. failed.error)
	return failed
end

local M : MlsStationsHelper = {
	getCompeting = getCompeting,
}
return M
