-- Leg times, distances and frequency for a line.
-- Runs on the timer thread: api.engine / api.res reads only, plain tables
-- out. Types in tealdef/mls_def.d.tl (MlsJourneyHelper).
--
-- LineCargoInfo, verified in game:
--   sectionTimes[i]      leg i in seconds, including time at stations; the
--                        measured average once a vehicle has run the leg,
--                        otherwise the game's estimate. The last entry is
--                        the leg back to stop 1.
--   driveSectionTimes[i] the same, driving only.
--   realSectionTimes[i]  {measured average, count}; count 0 = estimated.
--   frequency            vehicles per second.
--   The call returns nil for a line with no vehicles.

local LUA_UTILS : string = "bottle_more_line_stats::/scripts/lua_utils.script.tl"
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

local function unknownLeg() : MlsLeg
	return { time = 0, drive = 0, estimated = false, distance = 0 }
end

-- Legs and frequency from one getLineCargoInfo call. The frequency is
-- vehicles per second; its inverse is the seconds between two vehicles.
local function getLegs(lineId : Engine.Entity, stopCount : integer) : {MlsLeg}, number
	local legs : {MlsLeg} = {}
	local info = api.engine.system.transportVehicleSystem.getLineCargoInfo(lineId, paxId())
	local frequency : number = 0
	if info ~= nil and info.frequency ~= nil and info.frequency > 0 then
		frequency = 1 / info.frequency
	end
	for i = 1, stopCount do
		local leg = unknownLeg()
		if info ~= nil then
			local t = info.sectionTimes[i]
			if t ~= nil and t > 0 then
				leg.time = t
				leg.drive = info.driveSectionTimes[i] or 0
				local real = info.realSectionTimes[i]
				leg.estimated = real == nil or real[2] == nil or real[2] == 0
			end
		end
		legs[i] = leg
	end
	return legs, frequency
end

local function sumLegs(legs : {MlsLeg}) : MlsLeg
	local total : MlsLeg = { time = 0, drive = 0, estimated = false, distance = 0 }
	local allDistances, allDrives = true, true
	for _, leg in ipairs(legs) do
		if leg.time <= 0 then
			return unknownLeg()
		end
		total.time = total.time + leg.time
		total.estimated = total.estimated or leg.estimated
		if leg.drive > 0 then total.drive = total.drive + leg.drive else allDrives = false end
		if leg.distance > 0 then total.distance = total.distance + leg.distance else allDistances = false end
	end
	-- A sum with a part missing would understate; report it as unknown.
	if not allDrives then total.drive = 0 end
	if not allDistances then total.distance = 0 end
	return total
end

-- Plain numbers, never the engine's Vec3f.
local record Pos
	x : number
	y : number
	z : number
end

local function nodePos(entity : Engine.Entity) : Pos
	local node = api.engine.getComponent(entity, CT.BASE_NODE) as Engine.Component.BaseNode
	if node == nil or node.position == nil then return nil end
	return { x = node.position.x, y = node.position.y, z = node.position.z }
end

-- Station position (port of the TF2 getStationLocationInternal): the
-- construction's transform for built stations. Bus and tram stops have no
-- construction; their first terminal's node id names the street edge, whose
-- BASE_EDGE holds both end positions, so the stop is at the midpoint.
local function stationPositionUnsafe(sg : Engine.Entity) : Pos
	local group = api.engine.getComponent(sg, CT.STATION_GROUP) as Engine.Component.StationGroup
	if group == nil or group.stations == nil or group.stations[1] == nil then return nil end
	local station = group.stations[1]

	local constr = api.engine.system.streetConnectorSystem.getConstructionEntityForStation(station)
	if constr ~= nil and constr ~= -1 and api.engine.entityExists(constr) then
		local c = api.engine.getComponent(constr, CT.CONSTRUCTION) as Engine.Component.Construction
		if c ~= nil and c.transf ~= nil then
			local t = c.transf:getTransl()
			return { x = t.x, y = t.y, z = t.z }
		end
	end

	local st = api.engine.getComponent(station, CT.STATION) as Station
	if st ~= nil and st.terminals ~= nil and st.terminals[1] ~= nil and st.terminals[1].vehicleNodeId ~= nil then
		local entity = st.terminals[1].vehicleNodeId.entity
		local edge = api.engine.getComponent(entity, CT.BASE_EDGE) as Engine.Component.BaseEdge
		if edge ~= nil and edge.position0 ~= nil and edge.position1 ~= nil then
			return {
				x = (edge.position0.x + edge.position1.x) / 2,
				y = (edge.position0.y + edge.position1.y) / 2,
				z = (edge.position0.z + edge.position1.z) / 2,
			}
		end
		local pos = edge ~= nil and edge.node0 ~= nil and nodePos(edge.node0) or nodePos(entity)
		if pos ~= nil then return pos end
	end
	luaUtils.debug("no position for station group " .. tostring(sg) .. " (station " .. tostring(station) .. ")")
	return nil
end

local function fillDistances(legs : {MlsLeg}, stops : {Engine.Entity})
	local n = #stops
	if n < 2 then return end
	-- Each station group is read once per call (no module state).
	local cache : {Engine.Entity : Pos} = {}
	local missing : {Engine.Entity : boolean} = {}
	local function posOf(sg : Engine.Entity) : Pos
		if cache[sg] ~= nil then return cache[sg] end
		if missing[sg] then return nil end
		local ok, p = pcall(stationPositionUnsafe, sg)
		if ok and p ~= nil then
			cache[sg] = p as Pos
			return cache[sg]
		end
		if not ok then luaUtils.log("station position failed for " .. tostring(sg) .. ": " .. tostring(p)) end
		missing[sg] = true
		return nil
	end
	for i = 1, n do
		local a = posOf(stops[i])
		local b = posOf(stops[(i % n) + 1])
		if legs[i] ~= nil and a ~= nil and b ~= nil then
			local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
			legs[i].distance = math.sqrt(dx * dx + dy * dy + dz * dz)
		end
	end
end

local M : MlsJourneyHelper = {
	getLegs = getLegs,
	sumLegs = sumLegs,
	fillDistances = fillDistances,
}
return M
