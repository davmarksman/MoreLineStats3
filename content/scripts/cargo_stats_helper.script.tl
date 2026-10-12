-- Gathers the stats shown in Cargo Details (the cargo counterpart of
-- line_stats_helper; the shared reads come from there).
--
-- collect() runs inside engine_react_util.useStepStateTimer, on a game
-- worker thread. Rules for everything it calls:
--   1. only api.engine.* / api.res.* reads, never api.gui.*
--   2. return plain Lua tables, never engine userdata
--   3. no writes to module-level state
--
-- What the engine keeps for cargo (DESIGNv3 §4.8): per type, the line's
-- capacity and items on board, the vehicles' loads, the game's quality
-- (unhappy) count, and per stop the types configured to load. There is no
-- "waiting at a stop for this line" and no leg demand for cargo, so neither
-- is computed here.
--
-- Index rules: Lua lists are 1-based; cargo-indexed lists use cargo id + 1.
--
-- Types in tealdef/mls_def.d.tl (MlsCargoStatsHelper, MlsCargoStats, MlsCargoType).

local LINE_STATS_HELPER : string = "bottle_more_line_stats::/scripts/line_stats_helper.script.tl"
local JOURNEY_HELPER : string = "bottle_more_line_stats::/scripts/journey_helper.script.tl"
local LUA_UTILS : string = "bottle_more_line_stats::/scripts/lua_utils.script.tl"
local lineStatsHelper = require(LINE_STATS_HELPER) as MlsLineStatsHelper
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

local function round(value : number) : integer
	return math.floor((value or 0) + 0.5) as integer
end

local function emptyStats(lineId : Engine.Entity, kind : string) : MlsCargoStats
	return {
		lineId = lineId,
		name = "?",
		kind = kind,
		numVehicles = 0,
		stops = {},
		stopNames = {},
		legs = {},
		journey = { time = 0, drive = 0, estimated = false, distance = 0 },
		frequency = 0,
		rate = 0,
		onBoard = 0,
		capacity = 0,
		unhappy = 0,
		types = {},
		stopLoads = {},
		legLoad = {},
		legLoadByType = {},
		legVehicles = {},
		legAtStation = {},
		legVehicleNames = {},
		vehicles = {},
		carrier = "other",
	}
end

-- Display name and icon path of a cargo type, as plain strings (the rep
-- object is userdata and must not leave the timer thread).
local function typeNameAndIcon(id : integer) : string, string
	local ok, rep = pcall(api.res.cargoTypeRep.get, id as CargoTypeId)
	if ok and rep ~= nil then
		local ct = rep as CargoType
		return ct.name or ("Cargo " .. tostring(id)), ct.icon or ""
	end
	return "Cargo " .. tostring(id), ""
end

-- The line's cargo capacity and items on board per type (passengers left
-- out): the usages with the "current load config" flag, which match the
-- vehicles' configured compartments. A new line reports no usages until
-- its vehicles have loaded, so the vehicles' capacities are the fallback.
local function carried(lineId : Engine.Entity) : {integer : integer}, {integer : integer}
	local caps : {integer : integer} = {}
	local used : {integer : integer} = {}
	local any = false
	-- Declared as a map, but it is a 1-based list indexed by cargo id + 1.
	local usages = api.engine.util.line.getLineCapacityUsages(lineId, false) as {UtilLine.LineCapacityUsage}
	if usages ~= nil then
		for i, usage in ipairs(usages) do
			local id = i - 1
			if id ~= paxId() and usage ~= nil and (usage.capacity or 0) > 0 then
				caps[id] = round(usage.capacity)
				used[id] = round(usage.used)
				any = true
			end
		end
	end
	if not any then
		for _, vehicleId in ipairs(api.engine.system.transportVehicleSystem.getLineVehicles(lineId)) do
			local transportVehicle = api.engine.getComponent(vehicleId, CT.TRANSPORT_VEHICLE) as Engine.Component.TransportVehicle
			local vcaps = transportVehicle ~= nil and transportVehicle.config ~= nil and transportVehicle.config.capacities or nil
			if vcaps ~= nil then
				for i, cap in ipairs(vcaps) do
					local id = i - 1
					if id ~= paxId() and cap > 0 then
						caps[id] = (caps[id] or 0) + cap
						used[id] = used[id] or 0
					end
				end
			end
		end
	end
	return caps, used
end

-- Carried ids, largest capacity first, then by id (stable between refreshes).
local function sortedIds(caps : {integer : integer}) : {integer}
	local ids : {integer} = {}
	for id, _ in pairs(caps) do ids[#ids + 1] = id end
	table.sort(ids, function(idA : integer, idB : integer) : boolean
		if caps[idA] ~= caps[idB] then return caps[idA] > caps[idB] end
		return idA < idB
	end)
	return ids
end

-- Leg times: the same for every type of a line, but the engine returns nil
-- for a type the line doesn't carry. Try the carried ids, then passengers
-- (a mixed line); the first with any data wins. All nil leaves "?" legs.
local function readLegs(lineId : Engine.Entity, stopCount : integer, ids : {integer}) : {MlsLeg}, number
	local candidates : {CargoTypeId} = {}
	for _, id in ipairs(ids) do candidates[#candidates + 1] = id as CargoTypeId end
	candidates[#candidates + 1] = paxId()
	local legs : {MlsLeg} = {}
	local frequency : number = 0
	for _, id in ipairs(candidates) do
		legs, frequency = journeyHelper.getLegs(lineId, stopCount, id)
		if frequency > 0 then return legs, frequency end
		for _, leg in ipairs(legs) do
			if leg.time > 0 then return legs, frequency end
		end
	end
	return legs, frequency
end

-- Per stop, the cargo types it is configured to load (stopConfig.load,
-- index = cargo id + 1), passengers left out. A type the line has no
-- capacity for is listed with capacity 0 (the window says so in the tooltip).
local function readStopLoads(lineId : Engine.Entity, stopCount : integer, caps : {integer : integer}, used : {integer : integer},
		names : {integer : string}, icons : {integer : string}) : {{MlsCargoType}}
	local loads : {{MlsCargoType}} = {}
	for i = 1, stopCount do loads[i] = {} end
	local line = api.engine.getComponent(lineId, CT.LINE) as Engine.Component.Line
	if line == nil or line.stops == nil then return loads end
	for i, stop in ipairs(line.stops) do
		if i > stopCount then break end
		local cfg = stop.stopConfig
		local flags = cfg ~= nil and cfg.load or nil
		if flags ~= nil then
			for j, on in ipairs(flags) do
				local id = j - 1
				if on and id ~= paxId() then
					if names[id] == nil then names[id], icons[id] = typeNameAndIcon(id) end
					loads[i][#loads[i] + 1] = {
						id = id,
						name = names[id],
						icon = icons[id],
						onBoard = used[id] or 0,
						capacity = caps[id] or 0,
						unhappy = 0,
					}
				end
			end
		end
	end
	return loads
end

local function collectUnsafe(lineId : Engine.Entity) : MlsCargoStats
	if lineId == nil or not api.engine.entityExists(lineId) then
		return emptyStats(lineId, "missing")
	end

	local stats = emptyStats(lineId, "cargo")
	stats.name = api.engine.util.getEntityName(lineId) or "?"
	stats.stops, stats.stopNames = lineStatsHelper.readStops(lineId)
	stats.numVehicles = lineStatsHelper.vehicleCount(lineId)
	local stopCount = #stats.stops
	if stats.numVehicles == 0 then
		stats.kind = "empty"
		return stats
	end

	local caps, used = carried(lineId)
	local ids = sortedIds(caps)
	if #ids == 0 then
		stats.kind = "nocargo"
		return stats
	end

	-- Per type: name, icon, on board, capacity, unhappy; and the totals.
	local names : {integer : string} = {}
	local icons : {integer : string} = {}
	local cargoUtil = api.engine.util.cargo
	for _, id in ipairs(ids) do
		names[id], icons[id] = typeNameAndIcon(id)
		local quality = cargoUtil.getCargoQualityDataForLine(lineId, id as CargoTypeId)
		local bad = quality ~= nil and (quality.countBad or 0) or 0
		stats.types[#stats.types + 1] = {
			id = id,
			name = names[id],
			icon = icons[id],
			onBoard = used[id],
			capacity = caps[id],
			unhappy = bad,
		}
		stats.onBoard = stats.onBoard + used[id]
		stats.capacity = stats.capacity + caps[id]
		stats.unhappy = stats.unhappy + bad
	end

	stats.legs, stats.frequency = readLegs(lineId, stopCount, ids)
	journeyHelper.fillDistances(stats.legs, stats.stops)
	stats.journey = journeyHelper.sumLegs(stats.legs)
	-- The game's own line rate (the line window's "Rate").
	stats.rate = api.engine.util.line.calcLineStationThroughput(lineId) or 0

	stats.stopLoads = readStopLoads(lineId, stopCount, caps, used, names, icons)

	-- Vehicles: cargo load and capacity over all carried types. The per-type
	-- counts are kept per vehicle for the per-leg breakdown below.
	local atVehicle = api.engine.system.simEntityAtVehicleSystem
	local perVehicle : {Engine.Entity : {integer : integer}} = {}
	local function cargoLoadOf(vehicleId : Engine.Entity, transportVehicle : Engine.Component.TransportVehicle) : integer, integer
		local vcaps = transportVehicle.config ~= nil and transportVehicle.config.capacities or nil
		local byType : {integer : integer} = {}
		local onBoard, capacity = 0, 0
		for _, id in ipairs(ids) do
			local count = atVehicle.getVehicleSimEntitiesCountForCargoType(vehicleId, id as CargoTypeId) or 0
			if count > 0 then byType[id] = count end
			onBoard = onBoard + count
			capacity = capacity + (vcaps ~= nil and (vcaps[id + 1] or 0) or 0)
		end
		perVehicle[vehicleId] = byType
		return onBoard, capacity
	end
	local vehicleLegs = lineStatsHelper.readVehicles(lineId, stopCount, cargoLoadOf)
	stats.vehicles = vehicleLegs.vehicles
	stats.legVehicles = vehicleLegs.legVehicles
	stats.legAtStation = vehicleLegs.legAtStation
	stats.legVehicleNames = vehicleLegs.legVehicleNames
	stats.carrier = vehicleLegs.carrier

	-- Cargo on each leg: the loads of the vehicles on it, all types and per type.
	local legByType : {{integer : integer}} = {}
	for i = 1, stopCount do
		stats.legLoad[i] = 0
		stats.legLoadByType[i] = ""
		legByType[i] = {}
	end
	for _, vehicle in ipairs(stats.vehicles) do
		stats.legLoad[vehicle.leg] = stats.legLoad[vehicle.leg] + vehicle.load
		for id, count in pairs(perVehicle[vehicle.id] or {}) do
			legByType[vehicle.leg][id] = (legByType[vehicle.leg][id] or 0) + count
		end
	end
	for i = 1, stopCount do
		local parts : {string} = {}
		for _, id in ipairs(ids) do
			local count = legByType[i][id]
			if count ~= nil and count > 0 then parts[#parts + 1] = tostring(count) .. " " .. names[id] end
		end
		stats.legLoadByType[i] = table.concat(parts, "\n")
	end
	return stats
end

-- Never throws: an error in one line must not break the window.
local function collect(lineId : Engine.Entity) : MlsCargoStats
	local ok, result = pcall(collectUnsafe, lineId)
	if ok then return result as MlsCargoStats end
	local stats = emptyStats(lineId, "error")
	stats.error = tostring(result)
	luaUtils.log("cargo collect failed for line " .. tostring(lineId) .. ": " .. stats.error)
	return stats
end

local exports : MlsCargoStatsHelper = {
	collect = collect,
}
return exports
