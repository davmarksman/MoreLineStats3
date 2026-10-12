-- Formatting and logging helpers. No engine calls, so safe anywhere.
-- Types live in tealdef/mls_def.d.tl (MlsLuaUtils).

-- Set to false for a release build: only errors are logged then.
local DEBUG : boolean = false

-- Always logged: errors a user's log should show.
local function logAlways(message : string)
	debugPrint("[MLS] " .. message)
end

-- Logged only while DEBUG is true: traces for development.
local function logDebug(message : string)
	if DEBUG then debugPrint("[MLS] " .. message) end
end

-- "m:ss" under an hour, "h:mm:ss" from an hour. Unknown (0 or less) is "?".
local function getTimeStr(seconds : number) : string
	if seconds == nil or seconds <= 0 then return "?" end
	local total : integer = math.floor(seconds + 0.5) as integer
	-- math.floor rather than //, which needs Lua 5.3.
	local hours : integer = math.floor(total / 3600) as integer
	local minutes : integer = math.floor((total % 3600) / 60) as integer
	local remainderSeconds : integer = total % 60
	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, minutes, remainderSeconds)
	end
	return string.format("%d:%02d", minutes, remainderSeconds)
end

local exports : MlsLuaUtils = {
	DEBUG = DEBUG,
	log = logAlways,
	debug = logDebug,
	getTimeStr = getTimeStr,
}
return exports
