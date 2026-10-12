-- Gathers the stats shown in Line Details.
--
-- collect() runs inside engine_react_util.useStepStateTimer, on a game
-- worker thread. Rules for everything it calls:
--   1. only api.engine.* / api.res.* reads, never api.gui.*
--   2. return plain Lua tables, never engine userdata
--   3. no writes to module-level state
--
-- Index rules: Lua lists are 1-based; stop indexes the engine
-- takes or returns are 0-based; cargo-indexed lists use cargo id + 1.
--
-- Types in tealdef/mls_def.d.tl (MlsLineStatsHelper, MlsLineStats).

local JOURNEY_HELPER : string = "bottle_more_line_stats::/scripts/journey_helper.script.tl"
local LUA_UTILS : string = "bottle_more_line_stats::/scripts/lua_utils.script.tl"
local journeyHelper = require(JOURNEY_HELPER) as MlsJourneyHelper
local luaUtils = require(LUA_UTILS) as MlsLuaUtils

local CT = api.type.ComponentType
-- Read on first use: api.res is not available while the mod validator loads
-- this file.
local paxIdCache : CargoTypeId = nil
local function paxId() : CargoTypeId
	if paxIdCache == nil then
		paxIdCache = api.res.cargoTypeRep.getPassengerCargoTypeId()
	end
	return paxIdCache
end

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
		legAtStation = {},
		legVehicleNames = {},
		vehicles = {},
		carrier = "other",
		hasCompetition = false,
	}
end

-- Leg demand: every passenger waiting for or riding this line adds one to
-- each leg from their boarding stop to their exit stop, walking forward
-- with wrap-around. Cheap: a few milliseconds for every line of a 66-line
-- save.
local function fillLegDemand(stats : MlsLineStats, lineId : Engine.Entity)
	local stopCount = #stats.stops
	for i = 1, stopCount do stats.legDemand[i] = 0 end
	if stopCount < 2 then return end

	local function record(stop0 : integer, stop1 : integer)
		local cur = stop0 + 1
		local dest = stop1 + 1
		if cur < 1 or cur > stopCount or dest < 1 or dest > stopCount then return end
		local steps = 0
		while cur ~= dest and steps < stopCount do
			stats.legDemand[cur] = stats.legDemand[cur] + 1
			cur = (cur % stopCount) + 1
			steps = steps + 1
		end
	end

	for _, person in ipairs(api.engine.system.simPersonSystem.getSimPersonsForLine(lineId)) do
		local atTerminal = api.engine.getComponent(person, CT.SIM_ENTITY_AT_TERMINAL) as Engine.Component.SimEntityAtTerminal
		if atTerminal ~= nil and atTerminal.line == lineId then
			record(atTerminal.lineStop0, atTerminal.lineStop1)
		else
			local atVehicle = api.engine.getComponent(person, CT.SIM_ENTITY_AT_VEHICLE) as Engine.Component.SimEntityAtVehicle
			if atVehicle ~= nil and atVehicle.line == lineId then
				record(atVehicle.lineStop0, atVehicle.lineStop1)
			end
		end
	end
end

-- The game's own vehicle kind (the icon it draws), as a string for the GUI.
local function vehicleKind(vehicleId : Engine.Entity) : string
	local icons = api.type.enum.VehicleIconType
	-- Declared as an integer, but it is the enum's value.
	local iconType = api.engine.util.vehicle.getVehicleType(vehicleId) as VehicleIconType
	if iconType == icons.Bus then return "bus" end
	if iconType == icons.Truck then return "truck" end
	if iconType == icons.TrainSteam or iconType == icons.TrainElectric or iconType == icons.TrainDiesel then return "train" end
	if iconType == icons.Tram then return "tram" end
	if iconType == icons.Aircraft then return "aircraft" end
	if iconType == icons.Helicopter then return "helicopter" end
	if iconType == icons.Ship then return "ship" end
	return "other"
end

-- Vehicles per leg. A vehicle's stopIndex is the 0-based stop it is heading
-- to, or standing at. A moving vehicle is on the leg that ends there (leg i
-- ends at stop i + 1); a vehicle at a station counts on the leg that starts
-- there, i.e. the row of the stop it stands at. Vehicles in or heading to a
-- depot are left out. `loadOf` decides what load and capacity a vehicle
-- records (passengers here, cargo in cargo_stats_helper).
local function readVehicles(lineId : Engine.Entity, stopCount : integer,
		loadOf : function(Engine.Entity, Engine.Component.TransportVehicle) : integer, integer) : MlsVehicleLegs
	local vehicleLegs : MlsVehicleLegs = {
		vehicles = {}, legVehicles = {}, legAtStation = {}, legVehicleNames = {}, carrier = "other",
	}
	for i = 1, stopCount do
		vehicleLegs.legVehicles[i] = 0
		vehicleLegs.legAtStation[i] = 0
		vehicleLegs.legVehicleNames[i] = ""
	end
	if stopCount == 0 then return vehicleLegs end
	local states = api.type.enum.TransportVehicleState
	for _, vehicleId in ipairs(api.engine.system.transportVehicleSystem.getLineVehicles(lineId)) do
		local transportVehicle = api.engine.getComponent(vehicleId, CT.TRANSPORT_VEHICLE) as Engine.Component.TransportVehicle
		if transportVehicle ~= nil and transportVehicle.state ~= states.IN_DEPOT and transportVehicle.state ~= states.GOING_TO_DEPOT then
			local leg = (transportVehicle.stopIndex or 0)
			if leg < 1 or leg > stopCount then leg = stopCount end
			local atStation = transportVehicle.state == states.AT_TERMINAL
			if atStation then leg = (leg % stopCount) + 1 end
			local onBoard, capacity = loadOf(vehicleId, transportVehicle)
			local vehicle : MlsVehicle = {
				id = vehicleId,
				name = api.engine.util.getEntityName(vehicleId) or "?",
				leg = leg,
				atStation = atStation,
				load = onBoard or 0,
				capacity = capacity or 0,
				kind = vehicleKind(vehicleId),
			}
			vehicleLegs.vehicles[#vehicleLegs.vehicles + 1] = vehicle
			if #vehicleLegs.vehicles == 1 then vehicleLegs.carrier = vehicle.kind end

			local name = vehicle.name .. (atStation and " (at station)" or "")
			vehicleLegs.legVehicles[leg] = vehicleLegs.legVehicles[leg] + 1
			if atStation then vehicleLegs.legAtStation[leg] = vehicleLegs.legAtStation[leg] + 1 end
			vehicleLegs.legVehicleNames[leg] = vehicleLegs.legVehicleNames[leg] == "" and name
				or (vehicleLegs.legVehicleNames[leg] .. "\n" .. name)
		end
	end
	return vehicleLegs
end

-- A vehicle's passengers on board and seats.
local function paxLoadOf(vehicleId : Engine.Entity, transportVehicle : Engine.Component.TransportVehicle) : integer, integer
	local caps = transportVehicle.config ~= nil and transportVehicle.config.capacities or nil
	local onBoard = api.engine.system.simEntityAtVehicleSystem.getVehicleSimEntitiesCountForCargoType(vehicleId, paxId()) or 0
	return onBoard, caps ~= nil and (caps[paxId() + 1] or 0) or 0
end

local function fillVehicles(stats : MlsLineStats, lineId : Engine.Entity)
	local vehicleLegs = readVehicles(lineId, #stats.stops, paxLoadOf)
	stats.vehicles = vehicleLegs.vehicles
	stats.legVehicles = vehicleLegs.legVehicles
	stats.legAtStation = vehicleLegs.legAtStation
	stats.legVehicleNames = vehicleLegs.legVehicleNames
	stats.carrier = vehicleLegs.carrier
end

-- Station group and name per stop, 1-based.
local function readStops(lineId : Engine.Entity) : {Engine.Entity}, {string}
	local stops : {Engine.Entity} = {}
	local names : {string} = {}
	local line = api.engine.getComponent(lineId, CT.LINE) as Engine.Component.Line
	if line ~= nil and line.stops ~= nil then
		for i, stop in ipairs(line.stops) do
			local stationGroup : Engine.Entity = stop.stationGroup
			stops[i] = stationGroup
			names[i] = api.engine.entityExists(stationGroup) and (api.engine.util.getEntityName(stationGroup) or "?") or "?"
		end
	end
	return stops, names
end

local function vehicleCount(lineId : Engine.Entity) : integer
	return #api.engine.system.transportVehicleSystem.getLineVehicles(lineId)
end

-- The engine's own quality data: per stop it counts the passengers waiting
-- there, per line the passengers on board.
local function fillUnhappy(stats : MlsLineStats, lineId : Engine.Entity)
	local cargo = api.engine.util.cargo
	for i = 1, #stats.stops do
		local quality = cargo.getCargoQualityDataAtStop(lineId, i - 1, paxId())
		local bad = quality ~= nil and quality.countBad or 0
		stats.unhappyWaiting[i] = bad
		stats.unhappyWaitingTotal = stats.unhappyWaitingTotal + bad
	end
	local line = cargo.getCargoQualityDataForLine(lineId, paxId())
	stats.unhappyOnBoard = line ~= nil and line.countBad or 0
end

-- The line's passenger capacity usage ({used, capacity}), or nil.
local function paxUsage(lineId : Engine.Entity) : UtilLine.LineCapacityUsage
	local usages = api.engine.util.line.getLineCapacityUsages(lineId, true)
	return usages ~= nil and usages[paxId() + 1] or nil
end

-- Passengers waiting at each stop (0-based stop index for the engine) and
-- their sum.
local function readWaiting(lineId : Engine.Entity, stopCount : integer) : {integer}, integer
	local atTerminal = api.engine.system.simEntityAtTerminalSystem
	local waiting : {integer} = {}
	local total = 0
	for i = 1, stopCount do
		local count = atTerminal.getLineStopSimEntitiesCount(lineId, i - 1, paxId()) or 0
		waiting[i] = count
		total = total + count
	end
	return waiting, total
end

-- "empty" | "passenger" | "cargo". A line carrying passengers and cargo
-- counts as passenger. Passenger if the line's capacity usage says so, or
-- if passengers are waiting at any stop (a vehicle's `capacities` are its
-- compartments as currently assigned, so a mixed line whose space is all
-- set to cargo at the moment reads 0 while people still queue for it), or,
-- for a newly created line that reports no usage until its vehicles have
-- loaded, if a vehicle is configured for passengers.
local function lineKind(lineId : Engine.Entity, numVehicles : integer, pax : UtilLine.LineCapacityUsage, waitingTotal : integer) : string
	if numVehicles == 0 then return "empty" end
	if pax ~= nil and pax.capacity > 0 then return "passenger" end
	if waitingTotal ~= nil and waitingTotal > 0 then return "passenger" end

	for _, vehicleId in ipairs(api.engine.system.transportVehicleSystem.getLineVehicles(lineId)) do
		local transportVehicle = api.engine.getComponent(vehicleId, CT.TRANSPORT_VEHICLE) as Engine.Component.TransportVehicle
		local caps = transportVehicle ~= nil and transportVehicle.config ~= nil and transportVehicle.config.capacities or nil
		local cap = caps ~= nil and caps[paxId() + 1] or nil
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
	for _, playerLine in ipairs(lineSystem.getLinesForPlayer(api.engine.util.getPlayer())) do playerLines[playerLine] = true end

	local seen : {Engine.Entity : boolean} = {}
	local stationsServed : {Engine.Entity : integer} = {}
	for _, stationGroup in ipairs(stops) do
		if not seen[stationGroup] then
			seen[stationGroup] = true
			for _, other in ipairs(lineSystem.getLinesForStationGroup(stationGroup)) do
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
	stats.stops, stats.stopNames = readStops(lineId)
	stats.numVehicles = vehicleCount(lineId)
	local pax = paxUsage(lineId)
	-- Waiting is read before the classification: it is one of its inputs.
	stats.waiting, stats.waitingTotal = readWaiting(lineId, #stats.stops)
	stats.kind = lineKind(lineId, stats.numVehicles, pax, stats.waitingTotal)
	if stats.kind == "passenger" then
		stats.legs, stats.frequency = journeyHelper.getLegs(lineId, #stats.stops)
		journeyHelper.fillDistances(stats.legs, stats.stops)
		stats.journey = journeyHelper.sumLegs(stats.legs)

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
-- Same rule as collect, including the waiting check, so a competing-line
-- candidate is classed the way its own window would class it.
local function lineKindOf(lineId : Engine.Entity) : string
	local _, waitingTotal = readWaiting(lineId, #readStops(lineId))
	return lineKind(lineId, vehicleCount(lineId), paxUsage(lineId), waitingTotal)
end

local exports : MlsLineStatsHelper = {
	collect = collect,
	lineKind = lineKindOf,
	readStops = readStops,
	readVehicles = readVehicles,
	vehicleCount = vehicleCount,
}
return exports
