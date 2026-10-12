-- Text for the windows: times, distances, speeds, differences and their
-- tooltips. Pure functions over the plain tables the collectors return; no
-- engine reads. Runs on the GUI thread (api.util formatters).
-- Types live in tealdef/mls_def.d.tl (MlsFormatting).

local LUA_UTILS : string = "bottle_more_line_stats::/scripts/lua_utils.script.tl"
local luaUtils = require(LUA_UTILS) as MlsLuaUtils

local ESTIMATED_NOTE : string = "Estimated: no vehicle has completed this leg yet. The game uses this estimate until one does."

-- "4:40", "~4:40" if estimated, "?" if unknown.
local function legTimeStr(leg : MlsLeg) : string
	if leg.time <= 0 then return "?" end
	return (leg.estimated and "~" or "") .. luaUtils.getTimeStr(leg.time)
end

-- "7:58 driving, 0:47 at stations": the split a time cell can't show.
-- Nil without a driving time.
local function splitNote(leg : MlsLeg) : string
	if leg.drive <= 0 or leg.drive > leg.time then return nil end
	local atStations = leg.time - leg.drive
	return luaUtils.getTimeStr(leg.drive) .. " driving, "
		.. (atStations >= 1 and luaUtils.getTimeStr(atStations) or "0:00") .. " at stations"
end

local function legTooltip(leg : MlsLeg, isLast : boolean) : string
	if leg.time <= 0 then return "No time known for this leg yet." end
	local text = "Time to the next stop" .. (isLast and " (back to stop 1)" or "") .. ", including time at stations."
	local split = splitNote(leg)
	if split ~= nil then text = text .. "\n" .. split end
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
	local seconds = leg.drive > 0 and leg.drive or leg.time
	if leg.distance <= 0 or seconds <= 0 then return "?" end
	return api.util.formatSpeed(leg.distance / seconds)
end

local function journeyTooltip(journey : MlsLeg) : string
	if journey.time <= 0 then return "The journey time is unknown until every leg has a time." end
	local text = "One full round trip, including time at stations."
	local split = splitNote(journey)
	if split ~= nil then text = text .. "\n" .. split end
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

local function competingTimeTooltip(line : MlsCompetingLine) : string
	if line.time <= 0 then return "No time known for this line yet." end
	local text = "Time, including time at stations."
	if line.estimated then text = text .. "\nIncludes estimated legs, marked ~." end
	return text
end

-- "-0:30" faster, "+1:35" slower, "same", "(current)"; "" if either time
-- is unknown; "~" in front if either time includes an estimate.
local function differenceStr(line : MlsCompetingLine, dest : MlsDestination) : string
	if line.isThisLine then return "(current)" end
	if line.time <= 0 or dest.thisLineTime <= 0 then return "" end
	local difference = line.time - dest.thisLineTime
	if math.abs(difference) < 0.5 then return "same" end
	local prefix = (line.estimated or dest.thisLineEstimated) and "~" or ""
	return prefix .. (difference < 0 and "-" or "+") .. luaUtils.getTimeStr(math.abs(difference))
end

local function isFaster(line : MlsCompetingLine, dest : MlsDestination) : boolean
	return not line.isThisLine and line.time > 0 and dest.thisLineTime > 0
		and line.time < dest.thisLineTime - 0.5
end

local function differenceTooltip(line : MlsCompetingLine, dest : MlsDestination) : string
	if line.isThisLine then return "This line" end
	if line.time <= 0 or dest.thisLineTime <= 0 then
		return "No difference: one of the two times is unknown."
	end
	local difference = line.time - dest.thisLineTime
	if math.abs(difference) < 0.5 then return "Same time as this line." end
	local text = difference < 0 and "Faster than this line." or "Slower than this line."
	if line.estimated or dest.thisLineEstimated then
		text = text .. "\nOne of the times includes estimated legs."
	end
	return text
end

-- Station window: the difference against the fastest line to the destination
-- rather than against "this line".

-- "fastest" for every line within half a second of the best time, "+1:35"
-- behind it otherwise; "" if either time is unknown; "~" in front if either
-- time includes an estimate.
local function fastestDifferenceStr(line : MlsCompetingLine, dest : MlsStationDestination) : string
	if line.time <= 0 or dest.fastestTime <= 0 then return "" end
	if line.isFastest then return "fastest" end
	local prefix = (line.estimated or dest.fastestEstimated) and "~" or ""
	return prefix .. "+" .. luaUtils.getTimeStr(line.time - dest.fastestTime)
end

local function fastestDifferenceTooltip(line : MlsCompetingLine, dest : MlsStationDestination) : string
	if line.time <= 0 then return "No time known for this line yet." end
	if dest.fastestTime <= 0 then return "No line has a known time to this destination yet." end
	local text = line.isFastest and "Fastest to this station." or "Slower than the fastest line."
	if line.estimated or dest.fastestEstimated then
		text = text .. "\nOne of the times includes estimated legs."
	end
	return text
end

local exports : MlsFormatting = {
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
	fastestDifferenceStr = fastestDifferenceStr,
	fastestDifferenceTooltip = fastestDifferenceTooltip,
}
return exports
