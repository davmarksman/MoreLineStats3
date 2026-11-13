-- Gathers the stats shown in Cargo Details (the cargo counterpart of
-- line_stats_helper; the shared reads come from there).
--
-- collect() runs inside engine_react_util.useStepStateTimer, on a game
-- worker thread. Rules for everything it calls:
--   1. only api.engine.* / api.res.* reads, never api.gui.*
--   2. return plain Lua tables, never engine userdata
--   3. no writes to module-level state
--
-- What the engine keeps for cargo (verified in game, 2026-10-10): per type, the line's
-- capacity and items on board, the vehicles' loads, the game's quality
-- (unhappy) count, and per stop the types configured to load. There is no
-- "waiting at a stop for this line" and no leg demand for cargo. What waits
-- is the stock of the industries and warehouses a stop reaches (2026-11-11):
-- read only when collect() is asked for it (Cargo Details), since the Lines
-- window's Cargo tab and the line-window card don't show it.
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
		stopWaiting = {},
		stopWaitingByType = {},
		waiting = -1,
		legLoad = {},
		legLoadByType = {},
		legTypeLoad = {},
		legTypeUnhappy = {},
		sectionUnhappyRead = false,
		stopTypeWaiting = {},
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

-- Cargo waiting at a stop for the types it loads: the stocks of every
-- industry and warehouse the stop's stations reach (probed in game
-- 2026-11-11, ENGINE_FACTS §6). The catchables carry their own STOCK_LIST.
-- An industry's OutputStock holds its one cargoType; a warehouse's
-- StorageStock (cargoType -1, maybe mixed) any type, so it is asked for each.
-- Input stocks are skipped, and with them the town buildings. Returns the
-- count per type and whether the stop reaches any output or storage stock.
local function waitingAtStop(stationGroup : Engine.Entity, ids : {integer}) : {integer : integer}, boolean
	local counts : {integer : integer} = {}
	local group = api.engine.getComponent(stationGroup, CT.STATION_GROUP) as Engine.Component.StationGroup
	if group == nil or group.stations == nil then return counts, false end
	local stockType = api.type["enum"].StockListType
	local atStock = api.engine.system.simEntityAtStockSystem
	local seen : {Engine.Entity : boolean} = {}
	local reachesStock = false
	for _, station in ipairs(group.stations) do
		for _, entity in ipairs(api.engine.system.catchmentAreaSystem.getStationCatchables(station, true) or {}) do
			if not seen[entity] then
				seen[entity] = true
				local stockList = api.engine.getComponent(entity, CT.STOCK_LIST) as Engine.Component.StockList
				for j, stock in ipairs(stockList ~= nil and stockList.stocks or {}) do
					local storage = stock.type == stockType.StorageStock
					if storage or stock.type == stockType.OutputStock then
						reachesStock = true
						for _, id in ipairs(ids) do
							if storage or stock.cargoType == id as CargoTypeId then
								local count = atStock.getStockCountForCargoType(entity, (j - 1) as StockId, id as CargoTypeId) or 0
								counts[id] = (counts[id] or 0) + count
							end
						end
					end
				end
			end
		end
	end
	return counts, reachesStock
end

-- Per stop, the Waiting figure and its per-type tooltip lines (-1 / "" =
-- no figure: the stop loads none of the line's types or reaches no stock).
-- Also the line's total and each carried type's total (stats.waiting,
-- types[].waiting), where a station group the line calls at twice adds its
-- pile of a type once.
local function readStopWaiting(stats : MlsCargoStats, waitingCache : MlsWaitingCache)
	-- A line can call at the same station group twice, and the Cargo tab's
	-- lines share stations: read each once per set of types (the cache is
	-- the caller's, never module state).
	local cache = waitingCache.counts
	local reachesCache = waitingCache.reaches
	local typeById : {integer : MlsCargoType} = {}
	for _, cargoType in ipairs(stats.types) do typeById[cargoType.id] = cargoType end
	local counted : {string : boolean} = {}
	for i, stationGroup in ipairs(stats.stops) do
		stats.stopWaiting[i] = -1
		stats.stopWaitingByType[i] = ""
		stats.stopTypeWaiting[i] = {}
		local ids : {integer} = {}
		for _, cargoType in ipairs(stats.stopLoads[i] or {}) do
			if cargoType.capacity > 0 then ids[#ids + 1] = cargoType.id end
		end
		if #ids > 0 and stationGroup ~= nil and api.engine.entityExists(stationGroup) then
			local cacheKey = tostring(stationGroup) .. ":" .. table.concat(ids, ",")
			local counts = cache[cacheKey]
			local reachesStock = reachesCache[cacheKey]
			if counts == nil then
				counts, reachesStock = waitingAtStop(stationGroup, ids)
				cache[cacheKey] = counts
				reachesCache[cacheKey] = reachesStock
			end
			if reachesStock then
				local total = 0
				local parts : {string} = {}
				for _, cargoType in ipairs(stats.stopLoads[i]) do
					local count = counts[cargoType.id]
					if count ~= nil and count > 0 then
						total = total + count
						parts[#parts + 1] = tostring(count) .. " " .. cargoType.name
					end
					local lineType = typeById[cargoType.id]
					if lineType ~= nil then stats.stopTypeWaiting[i][cargoType.id] = count or 0 end
					local pileKey = tostring(stationGroup) .. ":" .. tostring(cargoType.id)
					if lineType ~= nil and not counted[pileKey] then
						counted[pileKey] = true
						lineType.waiting = math.max(lineType.waiting, 0) + (count or 0)
						stats.waiting = math.max(stats.waiting, 0) + (count or 0)
					end
				end
				stats.stopWaiting[i] = total
				stats.stopWaitingByType[i] = table.concat(parts, "\n")
			end
		end
	end
end

local function collectUnsafe(lineId : Engine.Entity, withWaiting : boolean, cache : MlsWaitingCache, withSections : boolean) : MlsCargoStats
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
			waiting = -1,
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
	if withWaiting then readStopWaiting(stats, cache or { counts = {}, reaches = {} }) end

	-- Vehicles: cargo load and capacity over all carried types. The per-type
	-- counts are kept per vehicle for the per-leg breakdown below.
	local atVehicle = api.engine.system.simEntityAtVehicleSystem
	local perVehicle : {Engine.Entity : {integer : integer}} = {}
	-- withSections: of each type on board, how many the game counts as bad,
	-- per vehicle (getCargoQualityDataForVehicle; first used here 2026-11-12,
	-- the base game's scripts never call it). Asked only for types on board.
	local perVehicleBad : {Engine.Entity : {integer : integer}} = {}
	local unhappyRead = withSections
	local function cargoLoadOf(vehicleId : Engine.Entity, transportVehicle : Engine.Component.TransportVehicle) : integer, integer
		local vcaps = transportVehicle.config ~= nil and transportVehicle.config.capacities or nil
		local byType : {integer : integer} = {}
		local badByType : {integer : integer} = {}
		local onBoard, capacity = 0, 0
		for _, id in ipairs(ids) do
			local count = atVehicle.getVehicleSimEntitiesCountForCargoType(vehicleId, id as CargoTypeId) or 0
			if count > 0 then
				byType[id] = count
				if withSections then
					local ok, quality = pcall(cargoUtil.getCargoQualityDataForVehicle, vehicleId, id as CargoTypeId)
					if ok and quality ~= nil then
						local bad = (quality as UtilCargo.CargoQualityData).countBad or 0
						if bad > 0 then badByType[id] = bad end
					else
						unhappyRead = false
					end
				end
			end
			onBoard = onBoard + count
			capacity = capacity + (vcaps ~= nil and (vcaps[id + 1] or 0) or 0)
		end
		perVehicle[vehicleId] = byType
		perVehicleBad[vehicleId] = badByType
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
		stats.legTypeUnhappy[i] = {}
	end
	for _, vehicle in ipairs(stats.vehicles) do
		stats.legLoad[vehicle.leg] = stats.legLoad[vehicle.leg] + vehicle.load
		for id, count in pairs(perVehicle[vehicle.id] or {}) do
			legByType[vehicle.leg][id] = (legByType[vehicle.leg][id] or 0) + count
		end
		local legBad = stats.legTypeUnhappy[vehicle.leg]
		for id, bad in pairs(perVehicleBad[vehicle.id] or {}) do
			legBad[id] = (legBad[id] or 0) + bad
		end
	end
	stats.legTypeLoad = legByType
	stats.sectionUnhappyRead = unhappyRead
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
local function collect(lineId : Engine.Entity, withWaiting? : boolean, cache? : MlsWaitingCache, withSections? : boolean) : MlsCargoStats
	local ok, result = pcall(collectUnsafe, lineId, withWaiting == true, cache, withSections == true)
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
