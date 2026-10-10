-- Text for the Line Details window: times, distances, speeds, differences
-- and their tooltips. Pure functions over the plain tables the collectors
-- return; no engine reads. Runs on the GUI thread (api.util formatters).
-- Types live in tealdef/mls_def.d.tl (MlsFormatting).

local LUA_UTILS : string = "bottle_more_line_stats::/scripts/lua_utils.script.tl"
local luaUtils = require(LUA_UTILS) as MlsLuaUtils

local ESTIMATED_NOTE : string = "Estimated: no vehicle has completed this leg yet. The game uses this estimate until one does."

-- "4:40", "~4:40" if estimated, "?" if unknown.
local function legTimeStr(leg : MlsLeg) : string
	if leg.time <= 0 then return "?" end
	return (leg.estimated and "~" or "") .. luaUtils.getTimeStr(leg.time)
end

-- "8:45 (7:58 driving, 0:47 at stations)", or just the total without a
-- driving time.
local function splitStr(leg : MlsLeg) : string
	local total = luaUtils.getTimeStr(leg.time)
	if leg.drive <= 0 or leg.drive > leg.time then return total end
	local atStations = leg.time - leg.drive
	return total .. " (" .. luaUtils.getTimeStr(leg.drive) .. " driving, "
		.. (atStations >= 1 and luaUtils.getTimeStr(atStations) or "0:00") .. " at stations)"
end

local function legTooltip(leg : MlsLeg, isLast : boolean) : string
	if leg.time <= 0 then return "No time known for this leg yet." end
	local text = "Average time from this stop to the next one"
		.. (isLast and " (back to stop 1)" or "")
		.. ", including time at stations: " .. splitStr(leg) .. "."
	if leg.estimated then text = text .. "\n" .. ESTIMATED_NOTE end
	return text
end

-- Distances and speeds use the game's formatters, so they follow the
-- player's unit setting. Times keep our compact m:ss: the game's own time
-- formatter spells out "8 min 42 s", too wide for the columns.

local function distanceStr(metres : number) : string
	if metres == nil or metres <= 0 then return "?" end
	return api.util.formatLength(metres)
end

-- Crow-flies distance over driving time (the TF2 figure); the total time
-- if no driving time is known.
local function speedStr(leg : MlsLeg) : string
	local t = leg.drive > 0 and leg.drive or leg.time
	if leg.distance <= 0 or t <= 0 then return "?" end
	return api.util.formatSpeed(leg.distance / t)
end

local function journeyTooltip(journey : MlsLeg) : string
	if journey.time <= 0 then return "The journey time is unknown until every leg has a time." end
	local text = "One full round trip, including time at stations: " .. splitStr(journey) .. "."
	if journey.estimated then text = text .. "\nIncludes estimated legs, marked ~." end
	return text
end

-- "120 (85%)": on board + waiting, and that as a share of passenger
-- capacity. No percentage without a capacity.
local function demandStr(stats : MlsLineStats) : string
	local demand = stats.onBoard + stats.waitingTotal
	if stats.capacity <= 0 then return tostring(demand) end
	local pct = math.floor(demand * 100 / stats.capacity + 0.5)
	return tostring(demand) .. " (" .. tostring(pct) .. "%)"
end

-- A competing line's time, in the same spelling as a leg time.
local function competingTimeStr(line : MlsCompetingLine) : string
	return legTimeStr({ time = line.time, drive = 0, estimated = line.estimated, distance = 0 })
end

local function competingTimeTooltip(line : MlsCompetingLine, data : MlsCompeting, dest : MlsDestination) : string
	if line.time <= 0 then
		return "No time known yet: a leg between these stations has no time on this line."
	end
	local text = "Time on " .. line.name .. " from " .. data.fromName .. " to " .. dest.name
		.. ", including time at stations: " .. luaUtils.getTimeStr(line.time) .. "."
	if line.estimated then text = text .. "\nIncludes estimated legs, marked ~." end
	return text
end

-- "-0:30" faster, "+1:35" slower, "same", "(current)"; "" if either time
-- is unknown; "~" in front if either time includes an estimate.
local function differenceStr(line : MlsCompetingLine, dest : MlsDestination) : string
	if line.isThisLine then return "(current)" end
	if line.time <= 0 or dest.thisLineTime <= 0 then return "" end
	local d = line.time - dest.thisLineTime
	if math.abs(d) < 0.5 then return "same" end
	local prefix = (line.estimated or dest.thisLineEstimated) and "~" or ""
	return prefix .. (d < 0 and "-" or "+") .. luaUtils.getTimeStr(math.abs(d))
end

local function isFaster(line : MlsCompetingLine, dest : MlsDestination) : boolean
	return not line.isThisLine and line.time > 0 and dest.thisLineTime > 0
		and line.time < dest.thisLineTime - 0.5
end

local function differenceTooltip(line : MlsCompetingLine, dest : MlsDestination) : string
	if line.isThisLine then return "The line this window is about." end
	if line.time <= 0 or dest.thisLineTime <= 0 then
		return "No difference: one of the two times is unknown."
	end
	local d = line.time - dest.thisLineTime
	if math.abs(d) < 0.5 then return "Takes the same time as this line." end
	local text = luaUtils.getTimeStr(math.abs(d)) .. (d < 0 and " faster" or " slower")
		.. " than this line to " .. dest.name .. "."
	if line.estimated or dest.thisLineEstimated then
		text = text .. "\nOne of the times includes estimated legs."
	end
	return text
end

local M : MlsFormatting = {
	legTimeStr = legTimeStr,
	legTooltip = legTooltip,
	distanceStr = distanceStr,
	speedStr = speedStr,
	journeyTooltip = journeyTooltip,
	demandStr = demandStr,
	competingTimeStr = competingTimeStr,
	competingTimeTooltip = competingTimeTooltip,
	differenceStr = differenceStr,
	isFaster = isFaster,
	differenceTooltip = differenceTooltip,
}
return M
