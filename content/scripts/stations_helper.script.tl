-- Competing lines: for a stop S of a line, every later station T on the
-- line and the player's other passenger lines that also go from S to T,
-- with their S->T times. Port of the TF2 mod's
-- stationsHelper, except that only the player's passenger lines count and
-- each line is read once per calculation.
-- getCompetingFromStation() is the station-window variant: from a station
-- S, every other station T that two or more of the player's passenger
-- lines reach, with each line's S->T time.
--
-- Both run inside engine_react_util.useStepStateTimer, on a game
-- worker thread: only api.engine.* / api.res.* reads, plain
-- Lua tables out, no writes to module-level state. hasPassengerTerminal()
-- (the station card's one-shot check) follows the same rules.
--
-- Types in tealdef/mls_def.d.tl (MlsStationsHelper, MlsCompeting).

local JOURNEY_HELPER : string = "bottle_more_line_stats::/scripts/journey_helper.script.tl"
local LINE_STATS_HELPER : string = "bottle_more_line_stats::/scripts/line_stats_helper.script.tl"
local LUA_UTILS : string = "bottle_more_line_stats::/scripts/lua_utils.script.tl"
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

local function entityName(entity : Engine.Entity) : string
	if entity == nil or not api.engine.entityExists(entity) then return "?" end
	return api.engine.util.getEntityName(entity) or "?"
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
	startIndex : integer -- the 1-based stop at `from` the time starts at (the first one if no time is known); 0 if `from` is not on the line
end

-- Shortest time from station `from` to station `to` on one line: walk
-- forward (wrapping) from every stop at `from`, summing leg times until a
-- stop at `to`, and keep the minimum. A path is unknown if any leg on it
-- has no time.
local function timeBetween(data : LineData, from : Engine.Entity, to : Engine.Entity) : Travel
	local best : Travel = { time = 0, estimated = false, startIndex = 0 }
	local stopCount = #data.stops
	for i = 1, stopCount do
		if data.stops[i] == from then
			if best.startIndex == 0 then best.startIndex = i end
			local total : number = 0
			local estimated = false
			local known = true
			local reached = false
			local walkIndex = i
			for _ = 1, stopCount do
				local leg = data.legs[walkIndex]
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
				walkIndex = (walkIndex % stopCount) + 1
				if data.stops[walkIndex] == to then
					reached = true
					break
				end
			end
			if known and reached and (best.time <= 0 or total < best.time) then
				best.time = total
				best.estimated = estimated
				best.startIndex = i
			end
		end
	end
	return best
end

local function toSet(list : {Engine.Entity}) : {Engine.Entity : boolean}
	local set : {Engine.Entity : boolean} = {}
	if list ~= nil then
		for _, entity in ipairs(list) do set[entity] = true end
	end
	return set
end

-- Known times ascending, unknown (0) last; ties by line id so the order
-- is stable between refreshes.
local function byTime(lineA : MlsCompetingLine, lineB : MlsCompetingLine) : boolean
	local timeA : number = lineA.time > 0 and lineA.time or math.huge
	local timeB : number = lineB.time > 0 and lineB.time or math.huge
	if timeA ~= timeB then return timeA < timeB end
	return lineA.lineId < lineB.lineId
end

local function emptyResult() : MlsCompeting
	return { fromStationGroup = nil, fromName = "?", destinations = {} }
end

local function getCompetingUnsafe(lineId : Engine.Entity, stopIndex : integer) : MlsCompeting
	local result = emptyResult()
	if lineId == nil or not api.engine.entityExists(lineId) then return result end

	local cache : {Engine.Entity : LineData} = {}
	local this = getLineData(cache, lineId)
	local stopCount = #this.stops
	if stopCount < 2 or stopIndex == nil or stopIndex < 1 or stopIndex > stopCount then return result end

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
	for _ = 1, stopCount - 1 do
		idx = (idx % stopCount) + 1
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
							local travel = timeBetween(data, from, to)
							lines[#lines + 1] = {
								lineId = other,
								name = data.name,
								time = travel.time,
								estimated = travel.estimated,
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
	-- Destinations in the order this line reaches them from S: shortest own
	-- time first, unknown times last, stop order as the tie-break (the walk
	-- above is in stop order, which differs from time order on out-and-back
	-- lines, where a station on the way back can be nearer the other way).
	local order : {Engine.Entity : integer} = {}
	for i, dest in ipairs(result.destinations) do order[dest.stationGroup] = i end
	table.sort(result.destinations, function(destA : MlsDestination, destB : MlsDestination) : boolean
		local timeA : number = destA.thisLineTime > 0 and destA.thisLineTime or math.huge
		local timeB : number = destB.thisLineTime > 0 and destB.thisLineTime or math.huge
		if timeA ~= timeB then return timeA < timeB end
		return order[destA.stationGroup] < order[destB.stationGroup]
	end)
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

------------------------------------------------------------
-- COMPETING LINES FROM A STATION (the station window)
------------------------------------------------------------

-- Within this of the best known time counts as fastest too, so two
-- equivalent lines are both marked instead of one showing "+0:00".
local FASTEST_TOLERANCE : number = 0.5

local function emptyStationResult(kind : string) : MlsStationCompeting
	return { kind = kind, stationGroup = nil, name = "?", lineCount = 0, destinations = {} }
end

-- Nearest first: by the best known time, unknown last; name, then station
-- group id (two groups can share a name) keep the order stable.
local function byNearest(destA : MlsStationDestination, destB : MlsStationDestination) : boolean
	local timeA : number = destA.fastestTime > 0 and destA.fastestTime or math.huge
	local timeB : number = destB.fastestTime > 0 and destB.fastestTime or math.huge
	if timeA ~= timeB then return timeA < timeB end
	if destA.name ~= destB.name then return destA.name < destB.name end
	return destA.stationGroup < destB.stationGroup
end

local function getCompetingFromStationUnsafe(stationGroup : Engine.Entity) : MlsStationCompeting
	if stationGroup == nil or not api.engine.entityExists(stationGroup) then
		return emptyStationResult("missing")
	end
	local result = emptyStationResult("ok")
	result.stationGroup = stationGroup
	result.name = entityName(stationGroup)

	-- The player's passenger lines at S, each read once into the cache.
	local lineSystem = api.engine.system.lineSystem
	local playerLines = toSet(lineSystem.getLinesForPlayer(api.engine.util.getPlayer()))
	local cache : {Engine.Entity : LineData} = {}
	local candidates : {Engine.Entity} = {}
	for _, lineId in ipairs(lineSystem.getLinesForStationGroup(stationGroup)) do
		if playerLines[lineId] then
			-- A line that fails to read is skipped, not the whole window.
			local ok, err : boolean, any = pcall(function()
				if getLineData(cache, lineId).passenger then
					candidates[#candidates + 1] = lineId
				end
			end)
			if not ok then
				luaUtils.log("skipping line " .. tostring(lineId) .. ": " .. tostring(err))
			end
		end
	end
	result.lineCount = #candidates

	-- Every other station the candidates stop at, and which of them go
	-- there. The lines' own stop lists say who goes where; no per-station
	-- engine call is needed.
	local destOrder : {Engine.Entity} = {}
	local linesAt : {Engine.Entity : {Engine.Entity}} = {}
	for _, lineId in ipairs(candidates) do
		local seen : {Engine.Entity : boolean} = {}
		for _, to in ipairs(cache[lineId].stops) do
			if to ~= stationGroup and not seen[to] then
				seen[to] = true
				if linesAt[to] == nil then
					linesAt[to] = {}
					destOrder[#destOrder + 1] = to
				end
				local list = linesAt[to]
				list[#list + 1] = lineId
			end
		end
	end

	-- Destinations served by one line only are not competition.
	for _, to in ipairs(destOrder) do
		local lineIds = linesAt[to]
		if #lineIds >= 2 then
			local lines : {MlsCompetingLine} = {}
			for _, lineId in ipairs(lineIds) do
				local data = cache[lineId]
				local travel = timeBetween(data, stationGroup, to)
				lines[#lines + 1] = {
					lineId = lineId,
					name = data.name,
					time = travel.time,
					estimated = travel.estimated,
					isThisLine = false,
					isFastest = false,
					stopIndex = travel.startIndex,
				}
			end
			table.sort(lines, byTime)
			-- After the sort the first line has the best known time, or 0 if
			-- no line has one.
			local best = lines[1]
			local fastestTime : number = best.time
			for _, line in ipairs(lines) do
				line.isFastest = fastestTime > 0 and line.time > 0 and line.time < fastestTime + FASTEST_TOLERANCE
			end
			result.destinations[#result.destinations + 1] = {
				stationGroup = to,
				name = entityName(to),
				lines = lines,
				fastestTime = fastestTime,
				fastestEstimated = fastestTime > 0 and best.estimated or false,
			}
		end
	end
	table.sort(result.destinations, byNearest)
	return result
end

-- Never throws: a failure must not break the window.
local function getCompetingFromStation(stationGroup : Engine.Entity) : MlsStationCompeting
	local ok, result = pcall(getCompetingFromStationUnsafe, stationGroup)
	if ok then return result as MlsStationCompeting end
	local failed = emptyStationResult("error")
	failed.error = tostring(result)
	luaUtils.log("getCompetingFromStation failed for station group " .. tostring(stationGroup) .. ": " .. failed.error)
	return failed
end

-- True if any terminal of any station in the group handles passengers
-- (the game's own test in its station window: Terminal.passengersLoad or
-- passengersUnload). A cargo-only station gets no card. Never throws; an
-- unreadable station counts as not passenger.
local function hasPassengerTerminalUnsafe(stationGroup : Engine.Entity) : boolean
	if stationGroup == nil or not api.engine.entityExists(stationGroup) then return false end
	local group = api.engine.getComponent(stationGroup, api.type.ComponentType.STATION_GROUP) as Engine.Component.StationGroup
	if group == nil or group.stations == nil then return false end
	for _, stationId in ipairs(group.stations) do
		local station = api.engine.getComponent(stationId, api.type.ComponentType.STATION) as Station
		if station ~= nil and station.terminals ~= nil then
			for _, terminal in ipairs(station.terminals) do
				if terminal.passengersLoad or terminal.passengersUnload then return true end
			end
		end
	end
	return false
end

local function hasPassengerTerminal(stationGroup : Engine.Entity) : boolean
	local ok, result = pcall(hasPassengerTerminalUnsafe, stationGroup)
	if ok then return result as boolean end
	luaUtils.log("hasPassengerTerminal failed for station group " .. tostring(stationGroup) .. ": " .. tostring(result))
	return false
end

local exports : MlsStationsHelper = {
	getCompeting = getCompeting,
	getCompetingFromStation = getCompetingFromStation,
	hasPassengerTerminal = hasPassengerTerminal,
}
return exports
