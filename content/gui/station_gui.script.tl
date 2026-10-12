-- More Line Stats: the station-window card and the Competing Lines windows.
--
-- The card (registered by station_eow.res.lua on every station group's
-- window) has one button, Competing Lines, which opens a window for that
-- station: every other station that two or more of the player's passenger
-- lines reach from here, nearest first, and under each those lines fastest
-- first with the time behind the fastest. One window per station group,
-- keyed by its id, so several can be open side by side. Line names open
-- Line Details with the stop at this station selected; a destination's
-- name opens that station's own window.
--
-- Requires line_gui (for openLineDetails); line_gui never requires this
-- module, so there is no cycle. No engine reads happen in recipe bodies:
-- the window's data comes from useStepStateTimer and the card's one check
-- (has the station a passenger terminal?) from the one-shot useStepState.
-- Event handlers may read the engine.

local react              = ug_require "::/gui/main/react.lua" as React
local builtin            = ug_require "::/gui/main/builtin.lua" as Builtin
local engine_react_util  = ug_require "::/gui/main/engine_react_util.tl" as EngineReactUtil
local gui_react_util     = ug_require "::/gui/main/gui_react_util.tl" as GuiReactUtil
local button_react_util  = ug_require "::/gui/main/button_react_util.tl" as ButtonReactUtil
local game_react_globals = ug_require "::/gui/main/game_react_globals.tl" as GameReactGlobals
local content_card       = ug_require "::/gui/main/content_card.tl" as ContentCard
local station_group_eow  = ug_require "::/gui/entity_window/station_group/station_group_eow.script.tl" as StationGroupEow
local line_react_util    = ug_require "::/gui/line_vehicle_mgmt/line_react_util.tl" as LineReactUtil

-- Own modules go through a path constant and a cast to their record in
-- tealdef/mls_def.d.tl, because `tl check` can't resolve "<modId>::/" paths.
local STATIONS_HELPER : string = "bottle_more_line_stats::/scripts/stations_helper.script.tl"
local LUA_UTILS : string = "bottle_more_line_stats::/scripts/lua_utils.script.tl"
local FORMATTING : string = "bottle_more_line_stats::/gui/formatting.script.tl"
local WIDGETS : string = "bottle_more_line_stats::/gui/widgets.script.tl"
local LINE_GUI : string = "bottle_more_line_stats::/gui/line_gui.script.tl"
local stationsHelper = require(STATIONS_HELPER) as MlsStationsHelper
local luaUtils = require(LUA_UTILS) as MlsLuaUtils
local fmt = require(FORMATTING) as MlsFormatting
local widgets = require(WIDGETS) as MlsWidgets
local lineGui = require(LINE_GUI) as MlsLineGui

local text, tableRow, locateButton, sectionTitle = widgets.text, widgets.tableRow, widgets.locateButton, widgets.sectionTitle

local REFRESH_SECONDS : number = 10.0

-- Competing lines: time, colour, line, difference (as in Line Details).
local COMPETING_COLUMN_WEIGHTS : {number} = { 2, 1, 5, 3 }

local TITLE_TOOLTIP : string = "For each other station that two or more of your passenger lines reach from here: those lines, fastest first, and how far behind the fastest the others are."

------------------------------------------------------------
-- TYPES
------------------------------------------------------------

local record WindowParams
	stationGroup : Engine.Entity
	name : string      -- the station's name when the window opened (heading fallback while loading)
	title : string
	onClose : function()
end

local record CardParams
	stationGroup : Engine.Entity
end

------------------------------------------------------------
-- WINDOW STATE (GUI thread only)
------------------------------------------------------------

-- Station groups with an open Competing Lines window, so a second click
-- brings it to the front instead of opening a duplicate.
local openWindows : {Engine.Entity : boolean} = {}

-- Window keys share one container with the base game and the other MLS
-- windows; a duplicate key crashes the UI.
local function windowKey(stationGroup : Engine.Entity) : string
	return "mls_stationCompeting_" .. tostring(stationGroup)
end

------------------------------------------------------------
-- WIDGET HELPERS
------------------------------------------------------------

-- Shown instead of the list when there is nothing to list; nil otherwise.
local function messageFor(data : MlsStationCompeting) : string
	if data == nil then return "Loading..." end
	if data.kind == "error" then return "Could not read the competing lines: " .. tostring(data.error) end
	if data.kind == "missing" then return "This station no longer exists." end
	if data.lineCount == 0 then return "None of your passenger lines stop here." end
	if #data.destinations == 0 then
		return "No destination from " .. data.name .. " is served by more than one of your lines."
	end
	return nil
end

-- "<pin> To Alford Station": the pin locates the station; the name is a
-- chrome-less button that opens the game's own window for it (the same
-- selectEntity event the colour swatches fire for lines; stack = true keeps
-- this window open). The text class keeps the label at body size and the
-- stylesheet adds a hover highlight so it reads as clickable.
local function destinationRow(dest : MlsStationDestination, fromName : string) : TreeNodeId
	local nameButton = button_react_util.makeTextButton("mls-heading-btn", "To " .. dest.name,
		function() react.fireEvent(nil, "selectEntity", { entity = dest.stationGroup, stack = true }) end,
		"Your lines that go from " .. fromName .. " to " .. dest.name .. ", fastest first.\n"
		.. "Click to open the station window for " .. dest.name .. ".",
		false, "font-scale-body")
	return builtin.Component{
		meta = { class = "mls-destination" },
		layout = builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = { locateButton(dest.stationGroup), nameButton },
		},
	}
end

-- "<time>  <colour> <line name>  <fastest | +difference>". The name opens
-- Line Details with this station's stop selected.
local function competingRow(line : MlsCompetingLine, dest : MlsStationDestination) : TreeNodeId
	local stopIndex = line.stopIndex
	local nameNode = line_react_util.NameTextView{
		entity = line.lineId,
		onClickOverride = function(entity : Engine.Entity) lineGui.openLineDetails(entity, stopIndex) end,
		tooltip = "Open Line Details",
		styleClass = "mls-line-name",
	}
	local diffClass = line.isFastest
		and "font-scale-body, mls-time, mls-faster"
		or "font-scale-body, mls-time"
	return tableRow(COMPETING_COLUMN_WEIGHTS, {
		text(fmt.competingTimeStr(line), "font-scale-body, mls-time", fmt.competingTimeTooltip(line)),
		line_react_util.ColorWidget{ entity = line.lineId },
		nameNode,
		text(fmt.fastestDifferenceStr(line, dest), diffClass, fmt.fastestDifferenceTooltip(line, dest)),
	}, "mls-compact-row")
end

------------------------------------------------------------
-- COMPETING LINES WINDOW
------------------------------------------------------------

local StationCompetingContent = react.RegisterRecipe(
	"MlsStationCompetingContent",
	function(params : WindowParams) : TreeNodeId
		local stationGroup : Engine.Entity = params.stationGroup

		react.useInputAction("IA_MENU_BACK", react.iaHandler(params.onClose))
		react.onMount(function()
			openWindows[stationGroup] = true
			luaUtils.debug("station window opened for station group " .. tostring(stationGroup))
		end)
		-- The window can be destroyed without onClose, so reset here too.
		react.onUnmount(function()
			openWindows[stationGroup] = nil
			luaUtils.debug("station window closed for station group " .. tostring(stationGroup))
		end)

		local state = engine_react_util.useStepStateTimer(function() : MlsStationCompeting
			return stationsHelper.getCompetingFromStation(stationGroup)
		end, REFRESH_SECONDS)
		local data = state:old()

		-- The name from the data once it is there (it follows renames), the
		-- one read at open while loading or when the station is gone.
		local stationName = (data ~= nil and data.kind == "ok") and data.name or params.name
		local children : {TreeNodeId} = {
			sectionTitle("Competing lines from " .. stationName, TITLE_TOOLTIP),
		}
		local message = messageFor(data)
		if message ~= nil then
			children[2] = text(message, "font-scale-body")
		else
			local rows : {TreeNodeId} = {}
			for _, dest in ipairs(data.destinations) do
				rows[#rows + 1] = destinationRow(dest, data.name)
				for _, line in ipairs(dest.lines) do
					rows[#rows + 1] = competingRow(line, dest)
				end
			end
			-- A ScrollArea rather than a List, so clicks don't highlight rows.
			-- Its content needs a fixed width (mls-scroll-content) or the rows
			-- shrink to their minimum and clip; the area itself has a fixed
			-- size (mls-station-scrollarea) so a hub can't grow the window.
			children[2] = builtin.ScrollArea{
				meta = { class = "mls-station-scrollarea" },
				content = builtin.Component{
					meta = { class = "mls-scroll-content" },
					layout = builtin.BoxLayout{
						orientation = builtin.type.Orientation.Vertical,
						children = rows,
					},
				},
				horizontalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
				verticalPolicy = builtin.type.ScrollBarPolicy.AsNeeded,
			}
		end

		return builtin.BoxLayout{
			child = builtin.Component{
				meta = { class = "mls-station" },
				layout = builtin.BoxLayout{
					orientation = builtin.type.Orientation.Vertical,
					children = children,
				},
			},
		}
	end)

local StationCompetingWindow = react.RegisterWrapperRecipe(
	"MlsStationCompetingWindow",
	builtin.Window,
	function(params : WindowParams) : TreeNodeId
		local win : builtin.WindowParam = {
			id = windowKey(params.stationGroup),
			title = params.title,
			onClose = params.onClose,
			closable = true,
			autoFocusOnBecomingVisible = true,
			content = StationCompetingContent(params),
		}
		-- Centred by the stylesheet through this class (see line_gui).
		(win as {string : any}).meta = { class = "mls-details-window" }
		return builtin.Window(win)
	end)

local function openStationCompeting(stationGroup : Engine.Entity)
	if stationGroup == nil or not api.engine.entityExists(stationGroup) then return end
	local winApi = game_react_globals.getDefaultWindowApi()
	local key = windowKey(stationGroup)
	if openWindows[stationGroup] then
		luaUtils.debug("window " .. key .. " already open, bringing to front")
		winApi.moveWindowToFront(StationCompetingWindow, key)
		return
	end
	-- The title is fixed when the window opens.
	local name : string = api.engine.util.getEntityName(stationGroup) or "?"
	luaUtils.debug("opening window " .. key)
	winApi.addWindow(StationCompetingWindow, key, {
		stationGroup = stationGroup,
		name = name,
		title = "From: " .. name,
		onClose = function()
			winApi.removeWindow(StationCompetingWindow, key)
			openWindows[stationGroup] = nil
		end,
	} as WindowParams)
	-- Marked open at once, not only in onMount, so a second click before
	-- the window has mounted brings it to the front instead of adding a
	-- duplicate key.
	openWindows[stationGroup] = true
end

------------------------------------------------------------
-- STATION WINDOW CARD
------------------------------------------------------------

-- One blue "primary" button. The card does no engine reads of its own and
-- has no timer, so it costs nothing while station windows are open. It is
-- shown on every station group with a passenger terminal (cargo-only
-- stations get none; user's decision), and the window says when none of
-- the player's lines stop there.
local MlsStationCardContent = react.RegisterRecipe(
	"MlsStationCardContent",
	function(params : CardParams) : TreeNodeId
		return builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = {
				button_react_util.makeTextButton(
					"primary",
					"Competing Lines",
					function() openStationCompeting(params.stationGroup) end,
					"Which of your passenger lines go from here to the same stations, and which gets there fastest."),
				gui_react_util.makeHorizontalSpacer(),
			},
		}
	end)

local MlsStationEowCard = react.RegisterPluginRecipe(
	station_group_eow.StationGroupEowExtensionPoint,
	"MlsStationEowCard",
	function(params : StationGroupEow.StationGroupWidgetPluginParams) : TreeNodeId
		-- Whether the station has a passenger terminal, read once on a worker
		-- thread by the game's one-shot step hook (the station window uses
		-- the same hook for its own state), so the recipe body itself reads
		-- nothing. Nil until the first step: render nothing until then.
		local stationGroup : Engine.Entity = params.entityId
		local passengerState = engine_react_util.useStepState(function() : boolean
			return stationsHelper.hasPassengerTerminal(stationGroup)
		end, nil, nil, nil, true)
		if not passengerState:old() then
			return builtin.BoxLayout{}
		end
		-- `any`: ContentCardParam doesn't declare meta.localKey. No title: the
		-- card sits near the top of the station window (the game fixes the
		-- plugin slot), so it is kept to one button row, as the game's own
		-- small cards (the waiting-hall bars) are.
		local cardParam : any = {
			meta = { localKey = "mlsStationCard" },
			initialCalloutTextPermanent = "",
			recipeAndParamPermanent = content_card.makeRecipeAndParam(MlsStationCardContent, { stationGroup = params.entityId } as CardParams),
			hasPermanentFocusables = true,
			gameCtx = params.gameCtx,
			showOnRightSide = params.showCalloutOnRightSide,
		}
		return builtin.BoxLayout{
			child = content_card.ContentCard(cardParam),
		}
	end)

luaUtils.debug("stationGui loaded")

return {
	MlsStationEowCard = MlsStationEowCard,
	openStationCompeting = openStationCompeting,
}
