-- Gathers the stats shown in Line Details.
--
-- collect() runs inside engine_react_util.useStepStateTimer, on a game
-- worker thread. Rules for everything it calls:
--   1. only api.engine.* / api.res.* reads, never api.gui.*
--   2. return plain Lua tables, never engine userdata
--   3. no writes to module-level state
--
-- Index rules (verified): Lua lists are 1-based; stop indexes the engine
-- takes or returns are 0-based; cargo-indexed lists use cargo id + 1.
--
-- Types in tealdef/mls_def.d.tl (MlsLineStatsHelper, MlsLineStats).

local JOURNEY_HELPER : string = "bottle_more_line_stats::/scripts/journeyHelper.script.tl"
local LUA_UTILS : string = "bottle_more_line_stats::/scripts/luaUtils.script.tl"
local journeyHelper = require(JOURNEY_HELPER) as MlsJourneyHelper
local luaUtils = require(LUA_UTILS) as MlsLuaUtils

local CT = api.type.ComponentType
local PAX_ID : CargoTypeId = api.res.cargoTypeRep.getPassengerCargoTypeId()

local function emptyStats(lineId : Engine.Entity, kind : string) : MlsLineStats
	return {
		lineId = lineId,
		name = "?",
		kind = kind,
		numVehicles = 0,
		stops = {},
		stopNames = {},
		legs = {},
		journey = { time = 0, drive = 0, estimated = false, distance = 0 },
		waiting = {},
		waitingTotal = 0,
		onBoard = 0,
		capacity = 0,
		frequency = 0,
		legDemand = {},
		unhappyWaiting = {},
		unhappyWaitingTotal = 0,
		unhappyOnBoard = 0,
		legVehicles = {},
		legVehicleNames = {},
		hasCompetition = false,
	}
end

-- Leg demand (TF2's recordSimJourney): every passenger waiting for or riding
-- this line adds one to each leg from their boarding stop to their exit
-- stop, walking forward with wrap-around. Cheap: a few milliseconds for
-- every line of a 66-line save.
local function fillLegDemand(stats : MlsLineStats, lineId : Engine.Entity)
	local n = #stats.stops
	for i = 1, n do stats.legDemand[i] = 0 end
	if n < 2 then return end

	local function record(stop0 : integer, stop1 : integer)
		local cur = stop0 + 1
		local dest = stop1 + 1
		if cur < 1 or cur > n or dest < 1 or dest > n then return end
		local steps = 0
		while cur ~= dest and steps < n do
			stats.legDemand[cur] = stats.legDemand[cur] + 1
			cur = (cur % n) + 1
			steps = steps + 1
		end
	end

	for _, p in ipairs(api.engine.system.simPersonSystem.getSimPersonsForLine(lineId)) do
		local atTerminal = api.engine.getComponent(p, CT.SIM_ENTITY_AT_TERMINAL) as Engine.Component.SimEntityAtTerminal
		if atTerminal ~= nil and atTerminal.line == lineId then
			record(atTerminal.lineStop0, atTerminal.lineStop1)
		else
			local atVehicle = api.engine.getComponent(p, CT.SIM_ENTITY_AT_VEHICLE) as Engine.Component.SimEntityAtVehicle
			if atVehicle ~= nil and atVehicle.line == lineId then
				record(atVehicle.lineStop0, atVehicle.lineStop1)
			end
		end
	end

end

-- Vehicles per leg. A vehicle's stopIndex is the 0-based stop it is heading
-- to (or at), so it is on the leg that ends there: leg i ends at stop i + 1.
-- Vehicles in or heading to a depot are left out.
local function fillVehicles(stats : MlsLineStats, lineId : Engine.Entity)
	local n = #stats.stops
	for i = 1, n do
		stats.legVehicles[i] = 0
		stats.legVehicleNames[i] = ""
	end
	if n == 0 then return end
	local states = api.type.enum.TransportVehicleState
	for _, v in ipairs(api.engine.system.transportVehicleSystem.getLineVehicles(lineId)) do
		local tv = api.engine.getComponent(v, CT.TRANSPORT_VEHICLE) as Engine.Component.TransportVehicle
		if tv ~= nil and tv.state ~= states.IN_DEPOT and tv.state ~= states.GOING_TO_DEPOT then
			local leg = (tv.stopIndex or 0)
			if leg < 1 or leg > n then leg = n end
			local name = api.engine.util.getEntityName(v) or "?"
			if tv.state == states.AT_TERMINAL then name = name .. " (at station)" end
			stats.legVehicles[leg] = stats.legVehicles[leg] + 1
			stats.legVehicleNames[leg] = stats.legVehicleNames[leg] == "" and name
				or (stats.legVehicleNames[leg] .. "\n" .. name)
		end
	end
end

-- The engine's own quality data: per stop it counts the passengers waiting
-- there, per line the passengers on board.
local function fillUnhappy(stats : MlsLineStats, lineId : Engine.Entity)
	local cargo = api.engine.util.cargo
	for i = 1, #stats.stops do
		local q = cargo.getCargoQualityDataAtStop(lineId, i - 1, PAX_ID)
		local bad = q ~= nil and q.countBad or 0
		stats.unhappyWaiting[i] = bad
		stats.unhappyWaitingTotal = stats.unhappyWaitingTotal + bad
	end
	local line = cargo.getCargoQualityDataForLine(lineId, PAX_ID)
	stats.unhappyOnBoard = line ~= nil and line.countBad or 0
end

-- The line's passenger capacity usage ({used, capacity}), or nil.
local function paxUsage(lineId : Engine.Entity) : UtilLine.LineCapacityUsage
	local usages = api.engine.util.line.getLineCapacityUsages(lineId, true)
	return usages ~= nil and usages[PAX_ID + 1] or nil
end

-- "empty" | "passenger" | "cargo". A line carrying passengers and cargo
-- counts as passenger. The line's capacity usage is checked first;
-- a newly created line reports 0 there until its vehicles have loaded, so
-- the vehicles' configured capacities are the fallback.
local function lineKind(lineId : Engine.Entity, numVehicles : integer, pax : UtilLine.LineCapacityUsage) : string
	if numVehicles == 0 then return "empty" end
	if pax ~= nil and pax.capacity > 0 then return "passenger" end

	for _, v in ipairs(api.engine.system.transportVehicleSystem.getLineVehicles(lineId)) do
		local tv = api.engine.getComponent(v, CT.TRANSPORT_VEHICLE) as Engine.Component.TransportVehicle
		local caps = tv ~= nil and tv.config ~= nil and tv.config.capacities or nil
		local cap = caps ~= nil and caps[PAX_ID + 1] or nil
		if cap ~= nil and cap > 0 then return "passenger" end
	end
	return "cargo"
end

-- True if some other line of the player's serves at least two distinct
-- stations of this line: then at least one stop may have a competing line,
-- and the competing panel is worth showing. Deliberately no passenger
-- check: a cargo line sharing two stations gives a harmless false positive.
local function hasCompetition(lineId : Engine.Entity, stops : {Engine.Entity}) : boolean
	local lineSystem = api.engine.system.lineSystem
	local playerLines : {Engine.Entity : boolean} = {}
	for _, l in ipairs(lineSystem.getLinesForPlayer(api.engine.util.getPlayer())) do playerLines[l] = true end

	local seen : {Engine.Entity : boolean} = {}
	local stationsServed : {Engine.Entity : integer} = {}
	for _, sg in ipairs(stops) do
		if not seen[sg] then
			seen[sg] = true
			for _, other in ipairs(lineSystem.getLinesForStationGroup(sg)) do
				if other ~= lineId and playerLines[other] then
					local count = (stationsServed[other] or 0) + 1
					if count >= 2 then return true end
					stationsServed[other] = count
				end
			end
		end
	end
	return false
end

local function collectUnsafe(lineId : Engine.Entity) : MlsLineStats
	if lineId == nil or not api.engine.entityExists(lineId) then
		return emptyStats(lineId, "missing")
	end

	local stats = emptyStats(lineId, "passenger")
	stats.name = api.engine.util.getEntityName(lineId) or "?"

	local line = api.engine.getComponent(lineId, CT.LINE) as Engine.Component.Line
	if line ~= nil and line.stops ~= nil then
		for i, stop in ipairs(line.stops) do
			local sg : Engine.Entity = stop.stationGroup
			stats.stops[i] = sg
			stats.stopNames[i] = api.engine.entityExists(sg) and (api.engine.util.getEntityName(sg) or "?") or "?"
		end
	end

	stats.numVehicles = #api.engine.system.transportVehicleSystem.getLineVehicles(lineId)
	local pax = paxUsage(lineId)
	stats.kind = lineKind(lineId, stats.numVehicles, pax)
	if stats.kind == "passenger" then
		stats.legs, stats.frequency = journeyHelper.getLegs(lineId, #stats.stops)
		journeyHelper.fillDistances(stats.legs, stats.stops)
		stats.journey = journeyHelper.sumLegs(stats.legs)

		local atTerminal = api.engine.system.simEntityAtTerminalSystem
		for i = 1, #stats.stops do
			local n = atTerminal.getLineStopSimEntitiesCount(lineId, i - 1, PAX_ID) or 0
			stats.waiting[i] = n
			stats.waitingTotal = stats.waitingTotal + n
		end

		if pax ~= nil then
			stats.onBoard = math.floor((pax.used or 0) + 0.5) as integer
			stats.capacity = math.floor((pax.capacity or 0) + 0.5) as integer
		end

		fillLegDemand(stats, lineId)
		fillUnhappy(stats, lineId)
		fillVehicles(stats, lineId)
		stats.hasCompetition = hasCompetition(lineId, stats.stops)
	end
	return stats
end

-- Never throws: an error in one line must not break the window.
local function collect(lineId : Engine.Entity) : MlsLineStats
	local ok, result = pcall(collectUnsafe, lineId)
	if ok then return result as MlsLineStats end
	local stats = emptyStats(lineId, "error")
	stats.error = tostring(result)
	luaUtils.log("collect failed for line " .. tostring(lineId) .. ": " .. stats.error)
	return stats
end

-- For stationsHelper. Reads the engine: timer thread or handler only.
local function lineKindOf(lineId : Engine.Entity) : string
	return lineKind(lineId, #api.engine.system.transportVehicleSystem.getLineVehicles(lineId), paxUsage(lineId))
end

local M : MlsLineStatsHelper = {
	collect = collect,
	lineKind = lineKindOf,
}
return M
