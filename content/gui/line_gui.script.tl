-- More Line Stats: the line-window card and the Line Details windows.
--
-- The card (registered by line_eow.res.lua) has two buttons: Passengers
-- opens a Line Details window for its line, Cargo opens a Cargo Details
-- window (cargo_gui). Each line gets its own window, keyed by line id, so
-- several can be open side by side. Line Details is master-detail: the
-- summary and stop list on the left; on the right, for the selected stop,
-- the vehicles on the way to the next stop and the competing lines.
--
-- No engine reads happen in recipe bodies: all data comes from
-- useStepStateTimer. Event handlers may read the engine.

local react              = ug_require "::/gui/main/react.lua" as React
local builtin            = ug_require "::/gui/main/builtin.lua" as Builtin
local engine_react_util  = ug_require "::/gui/main/engine_react_util.tl" as EngineReactUtil
local gui_react_util     = ug_require "::/gui/main/gui_react_util.tl" as GuiReactUtil
local button_react_util  = ug_require "::/gui/main/button_react_util.tl" as ButtonReactUtil
local game_react_globals = ug_require "::/gui/main/game_react_globals.tl" as GameReactGlobals
local content_card       = ug_require "::/gui/main/content_card.tl" as ContentCard
local line_eow           = ug_require "::/gui/entity_window/line/line_eow.script.tl" as LineEow
local line_react_util    = ug_require "::/gui/line_vehicle_mgmt/line_react_util.tl" as LineReactUtil

-- Own modules go through a path constant and a cast to their record in
-- tealdef/mls_def.d.tl, because `tl check` can't resolve "<modId>::/" paths.
local LINE_STATS_HELPER : string = "bottle_more_line_stats::/scripts/line_stats_helper.script.tl"
local STATIONS_HELPER : string = "bottle_more_line_stats::/scripts/stations_helper.script.tl"
local LUA_UTILS : string = "bottle_more_line_stats::/scripts/lua_utils.script.tl"
local FORMATTING : string = "bottle_more_line_stats::/gui/formatting.script.tl"
local WIDGETS : string = "bottle_more_line_stats::/gui/widgets.script.tl"
local lineStatsHelper = require(LINE_STATS_HELPER) as MlsLineStatsHelper
local stationsHelper = require(STATIONS_HELPER) as MlsStationsHelper
local luaUtils = require(LUA_UTILS) as MlsLuaUtils
local fmt = require(FORMATTING) as MlsFormatting
local widgets = require(WIDGETS) as MlsWidgets
-- The Cargo Details window, for the card's second button. cargo_gui never
-- requires this module, so there is no cycle.
local CARGO_GUI : string = "bottle_more_line_stats::/gui/cargo_gui.script.tl"
local cargoGui = require(CARGO_GUI) as MlsCargoGui

-- Widget helpers shared with the Cargo Details window (gui/widgets.script.tl).
local text, tableRow, icon, iconCell = widgets.text, widgets.tableRow, widgets.icon, widgets.iconCell
local locateButton, stopLocateButton, locateHeading = widgets.locateButton, widgets.stopLocateButton, widgets.locateHeading
local styledColumn, sectionTitle, vehiclesCell = widgets.styledColumn, widgets.sectionTitle, widgets.vehiclesCell

-- Text and tooltip builders (gui/formatting.script.tl).
local legTimeStr, legTooltip, distanceStr, speedStr = fmt.legTimeStr, fmt.legTooltip, fmt.distanceStr, fmt.speedStr
local journeyTooltip, demandStr = fmt.journeyTooltip, fmt.demandStr
local competingTimeStr, competingTimeTooltip = fmt.competingTimeStr, fmt.competingTimeTooltip
local differenceStr, differenceTooltip, isFaster = fmt.differenceStr, fmt.differenceTooltip, fmt.isFaster

local REFRESH_SECONDS : number = 10.0

-- Column weights, shared by header and rows so the columns line up.
-- Stop list: #+pin, Stop, Waiting, Unhappy, Demand, Vehicles, Distance, Speed, To next.
local STOP_COLUMN_WEIGHTS : {number} = { 2, 6, 2, 2, 2, 2, 3, 3, 2 }
-- Competing lines: time, colour, line, difference.
local COMPETING_COLUMN_WEIGHTS : {number} = { 2, 1, 5, 3 }
-- Vehicles on the selected leg: pin, name, load, where.
local VEHICLE_COLUMN_WEIGHTS : {number} = { 1, 5, 3, 3 }
-- Summary: Demand, Load/capacity, Waiting, Unhappy, Length, Frequency, Journey.
local SUMMARY_COLUMN_WEIGHTS : {number} = { 3, 2, 2, 2, 2, 2, 2 }

-- Base-game icons. The game resolves the "@2x" files itself.
local ICON_DEMAND : string = "::/gui/entity_window/icons/passengers.tga"
local ICON_PASSENGERS : string = "::/cargos/passengers/passengers.tga"
local ICON_WAITING : string = "::/gui/entity_window/icons/building_stations.tga"
local ICON_UNHAPPY : string = "::/gui/main/icons/symbol_emote_sad_colored.tga"
local ICON_DISTANCE : string = "::/gui/game_bar/icons/statistics_line_26.tga"
local ICON_SPEED : string = "::/gui/entity_window/icons/symbol_speed.tga"
local ICON_TIME : string = "::/gui/main/icons/calendar_speed.tga"
local ICON_FREQUENCY : string = "::/gui/entity_window/icons/symbol_stop_watch.tga"
local ICON_VEHICLES : string = widgets.ICON_VEHICLES

local COMPETING_TITLE_TOOLTIP : string = "For each later station on this line: the other passenger lines that also go there from the selected stop, fastest first."
local MORE_TOOLTIP : string = "Show, for the selected stop, the vehicles on the way to the next stop and the other lines that go to the same stations."
local LESS_TOOLTIP : string = "Hide the vehicles and competing-lines panel to make the window smaller."

------------------------------------------------------------
-- TYPES
------------------------------------------------------------

local record WindowParams
	lineId : Engine.Entity
	title : string
	onClose : function()
	initialStop : integer  -- 1-based stop selected on open; nil = stop 1
end

local record CardParams
	lineId : Engine.Entity
end

-- meta.localKey changes with the selected stop; the remount restarts the
-- panel's timer for the new stop (a timer closure keeps its old values).
local record CompetingParams
	meta : Meta
	lineId : Engine.Entity
	stopIndex : integer
end

------------------------------------------------------------
-- WINDOW STATE (GUI thread only)
------------------------------------------------------------

-- Lines with an open Line Details window, so a second Passengers click
-- brings it to the front instead of opening a duplicate.
local openWindows : {Engine.Entity : boolean} = {}

-- Window keys share one container with the base game. A pinned line window
-- is keyed by the bare entity id, and a duplicate key crashes the UI.
local function windowKey(lineId : Engine.Entity) : string
	return "mls_lineDetails_" .. tostring(lineId)
end

-- Forward declaration: defined after the window recipes it needs, used by
-- the competing panel above them.
local openLineDetails : function(lineId : Engine.Entity, stopIndex? : integer)

------------------------------------------------------------
-- WIDGET HELPERS (the shared ones live in gui/widgets.script.tl)
------------------------------------------------------------

local function stopRow(cells : {TreeNodeId}) : TreeNodeId
	return tableRow(STOP_COLUMN_WEIGHTS, cells)
end

-- Shown instead of stats for lines that have none; nil for a passenger line.
local function messageFor(stats : MlsLineStats) : string
	if stats == nil then return "Loading..." end
	if stats.kind == "cargo" then return "This line carries no passengers. Use the Cargo button in the line window." end
	if stats.kind == "empty" then return "This line has no vehicles." end
	if stats.kind == "missing" then return "This line no longer exists." end
	if stats.kind == "error" then return "Could not read this line: " .. tostring(stats.error) end
	return nil
end

------------------------------------------------------------
-- STOP LIST (left)
------------------------------------------------------------

local function stopList(stats : MlsLineStats, selected : integer, onSelect : function(integer)) : TreeNodeId
	local rows : {TreeNodeId} = {}
	local count = #stats.stops
	-- The stops with the most unhappy passengers and the legs with the most
	-- demand are highlighted; ties are all highlighted.
	local maxUnhappy, maxDemand = 0, 0
	for i = 1, count do
		maxUnhappy = math.max(maxUnhappy, stats.unhappyWaiting[i] or 0)
		maxDemand = math.max(maxDemand, stats.legDemand[i] or 0)
	end
	for i = 1, count do
		local leg = stats.legs[i] or { time = 0, drive = 0, estimated = false, distance = 0 }
		local name = stats.stopNames[i] or "?"
		local waiting = stats.waiting[i] or 0
		local unhappy = stats.unhappyWaiting[i] or 0
		local demand = stats.legDemand[i] or 0
		local vehicles = stats.legVehicles[i] or 0

		local unhappyTip = "Waiting passengers unhappy with the wait (the game's own measure)."

		local busiest = demand > 0 and demand == maxDemand
		local demandTip = "Passengers travelling from this stop to the next one now (waiting + on board)."
		if busiest then demandTip = demandTip .. "\nThe busiest leg of this line." end

		local atStation = stats.legAtStation[i] or 0
		-- The kind of the one vehicle on this section (only used when there is one).
		local kind = widgets.kindOnLeg(stats.vehicles, i)

		local distanceTip = leg.distance > 0
			and "Distance to the next stop as the crow flies."
			or "No position known for one of the two stations."
		local speedTip = "Crow-flies distance over "
			.. (leg.drive > 0 and "the driving time (time at stations left out)." or "the whole leg time (no driving time known).")

		rows[i] = stopRow({
			stopLocateButton(i, stats.stops[i]),
			text(name, "font-scale-body"),
			text(tostring(waiting), "font-scale-body, mls-time", "Passengers waiting at this stop for this line."),
			text(tostring(unhappy), (unhappy > 0 and unhappy == maxUnhappy) and "font-scale-body, mls-time, mls-unhappy" or "font-scale-body, mls-time", unhappyTip),
			text(tostring(demand), busiest and "font-scale-body, mls-time, mls-busiest" or "font-scale-body, mls-time", demandTip),
			vehiclesCell(vehicles, atStation, kind),
			text(distanceStr(leg.distance), "font-scale-body, mls-time", distanceTip),
			text(speedStr(leg), "font-scale-body, mls-time", speedTip),
			text(legTimeStr(leg), "font-scale-body, mls-time", legTooltip(leg, i == count)),
		})
	end
	return builtin.List{
		children = rows,
		selectionIndex = selected,
		deselectAllowed = false,
		cycle = false,
		keepSelectedVisible = true,
		horizontalScrollBarPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
		verticalScrollBarPolicy = builtin.type.ScrollBarPolicy.AsNeeded,
		onSelect = onSelect,
	}
end

-- Summary above the stop list: a title row with the Open Line Window button
-- and the More/Less toggle, then one row of the base game's icon-and-label
-- cells (the Basics card look).
local function summaryBlock(stats : MlsLineStats, lineWindow : TreeNodeId, toggle : TreeNodeId) : TreeNodeId
	local frequency = stats.frequency > 0 and luaUtils.getTimeStr(stats.frequency) or "?"
	local rows : {TreeNodeId} = {
		builtin.Component{
			layout = builtin.BoxLayout{
				orientation = builtin.type.Orientation.Horizontal,
				children = {
					text("Summary", "font-scale-body", "Figures for the whole line, refreshed every 10 seconds."),
					gui_react_util.makeHorizontalSpacer(),
					lineWindow,
					toggle,
				},
			},
		},
		tableRow(SUMMARY_COLUMN_WEIGHTS, {
			iconCell(ICON_DEMAND, demandStr(stats),
				"Demand: passengers on this line now, in vehicles plus waiting at stops.\n"
				.. "The percentage is demand as a share of the line's passenger capacity; "
				.. "high values mean there may not be enough vehicles."),
			iconCell(ICON_PASSENGERS, tostring(stats.onBoard) .. "/" .. tostring(stats.capacity),
				"Load / capacity: passengers in this line's vehicles now, and the line's passenger capacity."),
			iconCell(ICON_WAITING, tostring(stats.waitingTotal),
				"Waiting: passengers waiting for this line at all of its stops."),
			iconCell(ICON_UNHAPPY, tostring(stats.unhappyWaitingTotal + stats.unhappyOnBoard),
				"Unhappy: passengers unhappy with this line, by the game's own measure: "
				.. tostring(stats.unhappyWaitingTotal) .. " waiting at stops, "
				.. tostring(stats.unhappyOnBoard) .. " on board."),
			iconCell(ICON_DISTANCE, distanceStr(stats.journey.distance),
				"Length: Line length as the crow flies. \"?\" if a station's position is unknown."),
			iconCell(ICON_FREQUENCY, frequency,
				"Frequency: time between two vehicles of this line, as in the line window."
				.. (stats.journey.estimated and " Includes estimated legs." or "")),
			iconCell(ICON_TIME, legTimeStr(stats.journey), "Journey: " .. journeyTooltip(stats.journey)),
		}, "mls-summary-icons"),
	}
	return builtin.Component{
		meta = { class = "mls-journey" },
		layout = builtin.BoxLayout{
			orientation = builtin.type.Orientation.Vertical,
			children = rows,
		},
	}
end

------------------------------------------------------------
-- VEHICLES ON THE SELECTED LEG (right, above the competing lines)
------------------------------------------------------------

-- "<pin> <name>  12/96  <station or arrow icon>". The pin follows the vehicle.
local function vehicleRow(vehicle : MlsVehicle) : TreeNodeId
	return tableRow(VEHICLE_COLUMN_WEIGHTS, {
		locateButton(vehicle.id),
		text(vehicle.name, "font-scale-body"),
		text(tostring(vehicle.load) .. "/" .. tostring(vehicle.capacity), "font-scale-body, mls-time", "Passengers on board / seats."),
		widgets.whereIcon(vehicle.atStation),
	}, "mls-compact-row")
end

-- The vehicles between the selected stop and the next one. Reads the same
-- 10 s data as the stop list, so no timer of its own. Not scrolled: a leg
-- holds a handful of vehicles. Carries the Hide button for the whole column.
local function vehiclesPanel(stats : MlsLineStats, selected : integer, onHide : function()) : TreeNodeId
	local count = #stats.stops
	local name = stats.stopNames[selected] or "?"
	local nextName = stats.stopNames[(selected % count) + 1] or "?"
	local rows : {TreeNodeId} = {}
	for _, vehicle in ipairs(stats.vehicles) do
		if vehicle.leg == selected then rows[#rows + 1] = vehicleRow(vehicle) end
	end
	local hide = button_react_util.makeTextButton("primary", "Hide", onHide, LESS_TOOLTIP)
	local children : {TreeNodeId} = {
		sectionTitle("Vehicles on Section", nil, hide),
	}
	if #rows == 0 then
		children[2] = text("No vehicle at " .. name .. " or on the way to " .. nextName .. " right now.", "font-scale-body")
	else
		children[2] = builtin.Component{
			layout = builtin.BoxLayout{
				orientation = builtin.type.Orientation.Vertical,
				children = rows,
			},
		}
	end
	return builtin.Component{
		meta = { class = "mls-vehicles" },
		layout = builtin.BoxLayout{
			orientation = builtin.type.Orientation.Vertical,
			children = children,
		},
	}
end

------------------------------------------------------------
-- COMPETING LINES (right)
------------------------------------------------------------

local function destinationRow(dest : MlsDestination) : TreeNodeId
	return locateHeading(dest.stationGroup, "To " .. dest.name, "font-scale-body, mls-destination",
		"Lines from the selected stop to this station, fastest first.")
end

-- "<time>  <colour> <line name>  <difference>". Every name is a NameTextView
-- so the rows share one height; this line's click does nothing, the others
-- open their own window.
local function competingRow(line : MlsCompetingLine, dest : MlsDestination) : TreeNodeId
	local nameNode = line_react_util.NameTextView{
		entity = line.lineId,
		onClickOverride = line.isThisLine
			and function(_ : Engine.Entity) end
			or function(entity : Engine.Entity) openLineDetails(entity) end,
		tooltip = line.isThisLine and "This line" or "Open Line Details",
		styleClass = "mls-line-name",
	}
	local diffClass = isFaster(line, dest)
		and "font-scale-body, mls-time, mls-faster"
		or "font-scale-body, mls-time"
	return tableRow(COMPETING_COLUMN_WEIGHTS, {
		text(competingTimeStr(line), "font-scale-body, mls-time", competingTimeTooltip(line)),
		line_react_util.ColorWidget{ entity = line.lineId },
		nameNode,
		text(differenceStr(line, dest), diffClass, differenceTooltip(line, dest)),
	}, "mls-compact-row")
end

local CompetingPanel = react.RegisterRecipe(
	"MlsCompetingPanel",
	function(params : CompetingParams) : TreeNodeId
		local lineId : Engine.Entity = params.lineId
		local stopIndex : integer = params.stopIndex

		local state = engine_react_util.useStepStateTimer(function() : MlsCompeting
			return stationsHelper.getCompeting(lineId, stopIndex)
		end, REFRESH_SECONDS)
		local data = state:old()

		local children : {TreeNodeId} = {
			sectionTitle("Competing Lines", COMPETING_TITLE_TOOLTIP),
		}
		-- No "From <station>" heading: the selected stop is highlighted in
		-- the stop list already.
		if data == nil then
			children[2] = text("Loading...", "font-scale-body")
		else
			if data.error ~= nil then
				children[2] = text("Could not read the competing lines: " .. tostring(data.error), "font-scale-body")
			elseif #data.destinations == 0 then
				children[2] = text("No competing lines from " .. data.fromName .. ".", "font-scale-body",
					"No other passenger line of yours goes from this stop to any later stop on this line.")
			else
				local rows : {TreeNodeId} = {}
				for _, dest in ipairs(data.destinations) do
					rows[#rows + 1] = destinationRow(dest)
					for _, line in ipairs(dest.lines) do
						rows[#rows + 1] = competingRow(line, dest)
					end
				end
				-- A ScrollArea rather than a List, so clicks don't highlight
				-- rows. Its content needs a fixed width (mls-scroll-content),
				-- or the rows shrink to their minimum and clip.
				children[2] = builtin.ScrollArea{
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
		end

		return builtin.BoxLayout{
			orientation = builtin.type.Orientation.Vertical,
			children = children,
		}
	end)

------------------------------------------------------------
-- LINE DETAILS WINDOW
------------------------------------------------------------

local LineDetailsContent = react.RegisterRecipe(
	"MlsLineDetailsContent",
	function(params : WindowParams) : TreeNodeId
		local lineId : Engine.Entity = params.lineId

		react.useInputAction("IA_MENU_BACK", react.iaHandler(params.onClose))
		react.onMount(function()
			openWindows[lineId] = true
			luaUtils.debug("window opened for line " .. tostring(lineId))
		end)
		-- The window can be destroyed without onClose, so reset here too.
		react.onUnmount(function()
			openWindows[lineId] = nil
			luaUtils.debug("window closed for line " .. tostring(lineId))
		end)

		local statsState = engine_react_util.useStepStateTimer(function() : MlsLineStats
			return lineStatsHelper.collect(lineId)
		end, REFRESH_SECONDS)
		local stats = statsState:old()

		-- Selected stop, 1-based; stop 1 on open unless the opener asked for
		-- another (the station window preselects the stop at its station).
		local selState = react.useState(params.initialStop or 1) as ReactStateT<integer>
		-- Whether the competing-lines panel is shown. nil until the user
		-- presses More/Less; until then it follows whether the line has any
		-- competition at all. Hidden, the panel's recipe is not mounted, so
		-- its timer stops and the window can be narrower.
		local showState = react.useState(nil) as ReactStateT<boolean>

		local message = messageFor(stats)
		if message ~= nil then
			return widgets.windowBody("mls-details-narrow", { text(message, "font-scale-body") })
		end

		-- Clamp in case the line lost stops since the selection was made.
		local count = #stats.stops
		local selected : integer = selState:old()
		if selected == nil or selected < 1 or selected > count then selected = 1 end

		local choice = showState:old()
		local shown : boolean = stats.hasCompetition
		if choice ~= nil then shown = choice end
		local toggle = button_react_util.makeTextButton(
			"primary",
			shown and "<- Less" or "-> More",
			function() showState:set(not shown) end,
			shown and LESS_TOOLTIP or MORE_TOOLTIP)

		-- The game's own line window, via the same UI event the timetable
		-- mod fires; stack = true keeps this window open behind it.
		local lineWindow = button_react_util.makeTextButton("primary", "Open Line Window",
			function() react.fireEvent(nil, "selectEntity", { entity = lineId, stack = true }) end,
			"Open the game's own window for this line.")

		local left = styledColumn("mls-left", {
			summaryBlock(stats, lineWindow, toggle),
			stopRow({
				text("#", "font-scale-annotation"),
				text("Stop", "font-scale-annotation"),
				icon(ICON_PASSENGERS, "Waiting: passengers waiting at the stop for this line."),
				icon(ICON_UNHAPPY, "Unhappy: waiting passengers unhappy with the wait, by the game's own measure."),
				icon(ICON_DEMAND, "Demand: passengers travelling between this stop and the next one on this line now "
					.. "(waiting + on board). The busiest leg is highlighted."),
				icon(ICON_VEHICLES, "Vehicles standing at this stop or on the way from it to the next one."),
				icon(ICON_DISTANCE, "Distance to the next stop as the crow flies."),
				icon(ICON_SPEED, "Speed: average speed to the next stop, crow-flies distance over driving time where known."),
				icon(ICON_TIME, "To next: average time from this stop to the next one, including time at stations."),
			}),
			stopList(stats, selected, function(index : integer)
				if index >= 1 then selState:set(index) end
			end),
		})

		if not shown then
			return widgets.windowBody("mls-details-narrow", { left })
		end

		-- Keyed by stop index and station group, so the panel remounts if
		-- the line's stops change under the selected index.
		local right = styledColumn("mls-right", {
			vehiclesPanel(stats, selected, function() showState:set(false) end),
			CompetingPanel({
				meta = { localKey = "stop" .. tostring(selected) .. "_" .. tostring(stats.stops[selected]) },
				lineId = lineId,
				stopIndex = selected,
			} as CompetingParams),
		})

		return widgets.windowBody("mls-details", { left, right })
	end)

local LineDetailsWindow = react.RegisterWrapperRecipe(
	"MlsLineDetailsWindow",
	builtin.Window,
	function(params : WindowParams) : TreeNodeId
		local win : builtin.WindowParam = {
			id = windowKey(params.lineId),
			title = params.title,
			onClose = params.onClose,
			closable = true,
			autoFocusOnBecomingVisible = true,
			content = LineDetailsContent(params),
		}
		-- Style class so the stylesheet can centre the window
		-- (`Window!mls-details-window`); the game's entity window sets
		-- meta.class the same way, WindowParam just doesn't declare it.
		(win as {string : any}).meta = { class = "mls-details-window" }
		return builtin.Window(win)
	end)

-- `stopIndex` (optional, 1-based) is selected when the window opens; an
-- already open window is only brought to the front (user's decision).
openLineDetails = function(lineId : Engine.Entity, stopIndex? : integer)
	if lineId == nil or not api.engine.entityExists(lineId) then return end
	local winApi = game_react_globals.getDefaultWindowApi()
	local key = windowKey(lineId)
	if openWindows[lineId] then
		luaUtils.debug("window " .. key .. " already open, bringing to front")
		winApi.moveWindowToFront(LineDetailsWindow, key)
		return
	end
	-- The title is fixed when the window opens.
	local name : string = api.engine.util.getEntityName(lineId) or "?"
	luaUtils.debug("opening window " .. key)
	winApi.addWindow(LineDetailsWindow, key, {
		lineId = lineId,
		title = "Line Details: " .. name,
		initialStop = stopIndex,
		onClose = function()
			winApi.removeWindow(LineDetailsWindow, key)
			openWindows[lineId] = nil
		end,
	} as WindowParams)
	-- Marked open at once, not only in onMount, so a second click before
	-- the window has mounted brings it to the front instead of adding a
	-- duplicate key.
	openWindows[lineId] = true
end

------------------------------------------------------------
-- LINE WINDOW CARD
------------------------------------------------------------

-- Two blue "primary" buttons, always both: the card does no engine reads
-- and has no timer, so it costs nothing while line windows are open. A line
-- without passengers or without cargo gets a message in the window instead.
local MlsCardContent = react.RegisterRecipe(
	"MlsCardContent",
	function(params : CardParams) : TreeNodeId
		return builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = {
				-- A second class (comma-joined, as the game does) gives the
				-- first button a right margin, so the two don't touch.
				button_react_util.makeTextButton(
					"primary,mls-card-btn",
					"Passengers",
					function() openLineDetails(params.lineId) end,
					"Passengers on this line: waiting and unhappy per stop, demand per section, "
					.. "times and speeds between stops, vehicles on each section and the competing lines."),
				button_react_util.makeTextButton(
					"primary",
					"Cargo",
					function() cargoGui.openCargoDetails(params.lineId) end,
					"Cargo on this line: what each stop loads, cargo on each section, "
					.. "times and speeds between stops, vehicles on each section and the cargo types carried."),
				gui_react_util.makeHorizontalSpacer(),
			},
		}
	end)

local MlsLineEowCard = react.RegisterPluginRecipe(
	line_eow.LineEowExtensionPoint,
	"MlsLineEowCard",
	function(params : LineEow.LineWidgetPluginParams) : TreeNodeId
		if not line_eow.conditionPlayerOwned(params) then
			return builtin.BoxLayout{}
		end
		-- `any`: ContentCardParam doesn't declare meta.localKey.
		local cardParam : any = {
			meta = { localKey = "mlsCard" },
			title = "More Line Stats",
			initialCalloutTextPermanent = "",
			recipeAndParamPermanent = content_card.makeRecipeAndParam(MlsCardContent, { lineId = params.entityId } as CardParams),
			hasPermanentFocusables = true,
			gameCtx = params.gameCtx,
			showOnRightSide = params.showCalloutOnRightSide,
		}
		return builtin.BoxLayout{
			child = content_card.ContentCard(cardParam),
		}
	end)

luaUtils.debug("lineGui loaded")

return {
	MlsLineEowCard = MlsLineEowCard,
	-- For lines_list_gui.script.tl (the all-lines window).
	openLineDetails = openLineDetails,
}
