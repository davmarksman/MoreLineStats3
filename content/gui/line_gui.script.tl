-- More Line Stats: the line-window card and the Line Details windows.
--
-- The card (registered by line_eow.res.lua) shows one row of the line's
-- headline figures (passenger figures, or load, length, journey and speed
-- for a cargo line) above two buttons: Passengers opens a Line Details
-- window for its line, Cargo opens a Cargo Details window (cargo_gui).
-- Each line gets its own window, keyed by line id, so
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
local lang_util          = ug_require "::/scripts/lang_util.tl" as LangUtil

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
-- The cargo collector, for the card's row on a cargo line.
local CARGO_STATS_HELPER : string = "bottle_more_line_stats::/scripts/cargo_stats_helper.script.tl"
local cargoStatsHelper = require(CARGO_STATS_HELPER) as MlsCargoStatsHelper
-- Where the window reopens.
local WINDOW_POSITION : string = "bottle_more_line_stats::/gui/window_position.script.tl"
local windowPosition = require(WINDOW_POSITION) as MlsWindowPosition
local WINDOW_KIND : string = "lineDetails"

-- Widget helpers shared with the Cargo Details window (gui/widgets.script.tl).
local text, tableRow, icon, iconCell = widgets.text, widgets.tableRow, widgets.icon, widgets.iconCell
local stopLocateButton, locateHeading = widgets.stopLocateButton, widgets.locateHeading
local styledColumn, sectionTitle, vehiclesCell = widgets.styledColumn, widgets.sectionTitle, widgets.vehiclesCell
local vehicleRow = widgets.vehicleRow

-- Text and tooltip builders (gui/formatting.script.tl).
local legTimeStr, legTooltip, distanceStr, speedStr = fmt.legTimeStr, fmt.legTooltip, fmt.distanceStr, fmt.speedStr
local journeyTooltip, demandStr = fmt.journeyTooltip, fmt.demandStr
local distanceTooltip, speedTooltip = fmt.distanceTooltip, fmt.speedTooltip
local competingTimeStr, competingTimeTooltip = fmt.competingTimeStr, fmt.competingTimeTooltip
local differenceStr, differenceTooltip, isFaster = fmt.differenceStr, fmt.differenceTooltip, fmt.isFaster

-- The window's figures and the line-window card: 5 s (user, 2026-11-11).
local REFRESH_SECONDS : number = 5.0
-- The Competing Lines panel stays at 10 s, as the station window's list.
local COMPETING_REFRESH_SECONDS : number = 10.0

-- Column weights, shared by header and rows so the columns line up.
-- Stop list: #+pin, Stop, Waiting, Unhappy, Demand, Vehicles, Distance, Speed, To next.
-- The 720 px left column gives about 29 px per weight unit.
local STOP_COLUMN_WEIGHTS : {number} = { 2, 6, 2, 2, 2, 2, 3, 3, 3 }
-- Competing lines: time, colour, line, difference.
local COMPETING_COLUMN_WEIGHTS : {number} = { 2, 1, 5, 3 }
-- Summary: Demand, Load/capacity, Waiting, Unhappy, Length, Frequency, Journey.
local SUMMARY_COLUMN_WEIGHTS : {number} = { 3, 2, 2, 2, 2, 2, 2 }
-- Line-window card, passenger line: Demand, Waiting, Unhappy, Length,
-- Journey, Speed. Cargo line: Load %, Waiting, Length, Journey, Speed.
local CARD_PASSENGER_WEIGHTS : {number} = { 3, 2, 2, 2, 2, 2 }
local CARD_CARGO_WEIGHTS : {number} = { 2, 2, 2, 2, 2 }

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
-- The game's "mixed cargo" icon, for the cargo line's load cell (as in Cargo Details).
local ICON_CARGO : string = "::/cargos/icons/cargo_mixed.tga"

-- Texts used in more than one place. Functions, not constants: _() runs at
-- use time, never at load.
local function moreTooltip() : string
	return _("Show, for the selected stop, the vehicles on the way to the next stop and the other lines that go to the same stations.")
end
-- The Lines list's column sentences, also the card's and the summary's tooltips.
local function demandTooltip() : string
	return _("Demand: passengers on the line now, in vehicles plus waiting at stops.") .. "\n"
		.. _("Demand as a share of the line's passenger capacity. High values mean there may not be enough vehicles.")
end
-- The game's own words, so its catalog translates them (sim_person_eow).
local function waitingTooltip() : string
	return _("Waiting at Station")
end
-- The game's own words, so its catalog translates them (station_group.tl:146).
local function unhappyTooltip() : string
	return _("Unhappy Passengers")
end
local function lengthTooltip() : string
	return _("Length: line length as the crow flies.")
end
-- The stop list's header and cell sentences.
local function stopDemandTooltip() : string
	return _("Demand: passengers travelling between this stop and the next one on this line now (waiting + on board).")
end

------------------------------------------------------------
-- TYPES
------------------------------------------------------------

local record WindowParams
	lineId : Engine.Entity
	title : string
	onClose : function()
	initialStop : integer  -- 1-based stop selected on open; nil = stop 1
	spot : MlsWindowSpot   -- where the window opens; nil = centred
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
	if stats == nil then return _("Loading...") end
	if stats.kind == "cargo" then return _("This line carries no passengers.") end
	if stats.kind == "empty" then return _("This line has no vehicles.") end
	if stats.kind == "missing" then return _("This line no longer exists.") end
	if stats.kind == "error" then return fmt.couldNotRead(stats.error) end
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
	-- The cell tooltips repeat the header icons' sentences word for word,
	-- so each is one translation key.
	local waitingTip = waitingTooltip()
	local unhappyTip = unhappyTooltip()
	local demandBaseTip = stopDemandTooltip()
	local busiestNote = _("The busiest leg of this line.")
	local speedTip = speedTooltip()
	for i = 1, count do
		local leg = stats.legs[i] or { time = 0, drive = 0, estimated = false, distance = 0 }
		local name = stats.stopNames[i] or "?"
		local waiting = stats.waiting[i] or 0
		local unhappy = stats.unhappyWaiting[i] or 0
		local demand = stats.legDemand[i] or 0
		local vehicles = stats.legVehicles[i] or 0

		local busiest = demand > 0 and demand == maxDemand
		local demandTip = demandBaseTip
		if busiest then demandTip = demandTip .. "\n" .. busiestNote end

		local atStation = stats.legAtStation[i] or 0
		-- The kind of the one vehicle on this section (only used when there is one).
		local kind = widgets.kindOnLeg(stats.vehicles, i)

		local distanceTip = leg.distance > 0
			and distanceTooltip()
			or _("No position known for one of the two stations.")

		rows[i] = stopRow({
			stopLocateButton(i, stats.stops[i]),
			text(name, "font-scale-body"),
			text(tostring(waiting), "font-scale-body, mls-time", waitingTip),
			text(tostring(unhappy), (unhappy > 0 and unhappy == maxUnhappy) and "font-scale-body, mls-time, mls-unhappy" or "font-scale-body, mls-time", unhappyTip),
			text(tostring(demand), busiest and "font-scale-body, mls-time, mls-busiest" or "font-scale-body, mls-time", demandTip),
			vehiclesCell(vehicles, atStation, kind),
			text(distanceStr(leg.distance), "font-scale-body, mls-time", distanceTip),
			text(speedStr(leg), "font-scale-body, mls-time", speedTip),
			text(legTimeStr(leg), "font-scale-body, mls-time", legTooltip(leg)),
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

-- Summary above the stop list: a button row (Open Line Window and Manage
-- Line on the left, the side-panel toggle on the right; no title, user
-- 2026-11-11; the locate pin is in the title bar), then one row of the
-- base game's icon-and-label cells (the Basics card look).
local function summaryBlock(stats : MlsLineStats, lineWindow : TreeNodeId, lineManager : TreeNodeId, toggle : TreeNodeId) : TreeNodeId
	local frequency = stats.frequency > 0 and luaUtils.getTimeStr(stats.frequency) or "?"
	local rows : {TreeNodeId} = {
		builtin.Component{
			layout = builtin.BoxLayout{
				orientation = builtin.type.Orientation.Horizontal,
				children = {
					lineWindow,
					lineManager,
					gui_react_util.makeHorizontalSpacer(),
					toggle,
				},
			},
		},
		tableRow(SUMMARY_COLUMN_WEIGHTS, {
			-- The same sentences as the Lines list's column tooltips, so each
			-- is one translation key.
			iconCell(ICON_DEMAND, demandStr(stats), demandTooltip()),
			iconCell(ICON_PASSENGERS, tostring(stats.onBoard) .. "/" .. tostring(stats.capacity),
				fmt.loadCapacityTooltip()),
			iconCell(ICON_WAITING, tostring(stats.waitingTotal), waitingTooltip()),
			iconCell(ICON_UNHAPPY, tostring(stats.unhappyWaitingTotal + stats.unhappyOnBoard), unhappyTooltip()),
			iconCell(ICON_DISTANCE, distanceStr(stats.journey.distance), lengthTooltip()),
			iconCell(ICON_FREQUENCY, frequency, nil),
			iconCell(ICON_TIME, legTimeStr(stats.journey), journeyTooltip(stats.journey)),
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

-- The vehicles between the selected stop and the next one. Reads the same
-- 5 s data as the stop list, so no timer of its own. Not scrolled: a leg
-- holds a handful of vehicles. Carries the Hide button for the whole column.
local function vehiclesPanel(stats : MlsLineStats, selected : integer, onHide : function()) : TreeNodeId
	local rows : {TreeNodeId} = {}
	for _, vehicle in ipairs(stats.vehicles) do
		if vehicle.leg == selected then rows[#rows + 1] = vehicleRow(vehicle) end
	end
	local hide = button_react_util.makeTextButton("primary", _("<- Less"), onHide, nil)
	-- No station names in the empty text: the selected stop is highlighted
	-- in the stop list, and a static sentence is one translation key.
	local children : {TreeNodeId} = {
		sectionTitle(_("Vehicles"), nil, hide),
		widgets.fixedScrollBox("mls-vehicles-scrollarea", rows,_("No vehicle at this stop or on the way to the next one.")),
	}
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
	-- The game's own "To", as in the station window's headings.
	return locateHeading(dest.stationGroup, _("To") .. " " .. dest.name, "font-scale-body, mls-destination",
		_("Lines from here to this station, fastest first."))
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
		tooltip = line.isThisLine and _("This line") or _("Open Line Details"),
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
		end, COMPETING_REFRESH_SECONDS)
		local data = state:old()

		local children : {TreeNodeId} = {
			sectionTitle(_("Competing Lines"),
				_("For each later station on this line: the other passenger lines that also go there from the selected stop, fastest first.")),
		}
		-- No "From <station>" heading: the selected stop is highlighted in
		-- the stop list already. A fixed box of about eight rows (user,
		-- 2026-11-12), the messages inside it, so the height never changes.
		local rows : {TreeNodeId} = {}
		local message : string
		if data == nil then
			message = _("Loading...")
		elseif data.error ~= nil then
			message = fmt.couldNotRead(data.error)
		elseif #data.destinations == 0 then
			message = _("No competing lines from this stop.")
		else
			for _, dest in ipairs(data.destinations) do
				rows[#rows + 1] = destinationRow(dest)
				for _, line in ipairs(dest.lines) do
					rows[#rows + 1] = competingRow(line, dest)
				end
			end
		end
		children[2] = widgets.fixedScrollBox("mls-competing-scrollarea", rows, message)

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
		windowPosition.usePoll(WINDOW_KIND, windowKey(lineId), params.spot)
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
		-- Whether the right column (vehicles and competing lines) is shown:
		-- closed by default (user's choice, 2026-11-11; open from 2026-10-17),
		-- the toggle opens it. Hidden, the panel's recipe is not mounted, so
		-- its timer stops and the window is narrower.
		local showState = react.useState(false) as ReactStateT<boolean>

		local message = messageFor(stats)
		if message ~= nil then
			return widgets.windowBody("mls-details-narrow", { text(message, "font-scale-body") })
		end

		-- Clamp in case the line lost stops since the selection was made.
		local count = #stats.stops
		local selected : integer = selState:old()
		if selected == nil or selected < 1 or selected > count then selected = 1 end

		local shown : boolean = showState:old() == true
		-- Closed, the label names the panel: the game's "Vehicles" and our
		-- "Competing Lines" keys, so no new translation.
		local toggle = button_react_util.makeTextButton(
			"primary, mls-summary-btn",
			shown and _("<- Less") or (_("Vehicles") .. "/" .. _("Competing Lines") .. " ->"),
			function() showState:set(not shown) end,
			(not shown) and moreTooltip() or nil)

		-- The game's own line window, via the same UI event the timetable
		-- mod fires; stack = true keeps this window open behind it. No
		-- tooltip: the label says it all.
		local lineWindow = button_react_util.makeTextButton("primary, mls-summary-btn", _("Open Line Window"),
			function() react.fireEvent(nil, "selectEntity", { entity = lineId, stack = true }) end,
			nil)

		-- The line manager on this line, as the game's own Manage Line button.
		local lineManager = widgets.manageLineButton(lineId)

		local left = styledColumn("mls-left", {
			summaryBlock(stats, lineWindow, lineManager, toggle),
			stopRow({
				text("#", "font-scale-annotation"),
				text(_("Stop"), "font-scale-annotation"),
				icon(ICON_PASSENGERS, waitingTooltip()),
				icon(ICON_UNHAPPY, unhappyTooltip()),
				icon(ICON_DEMAND, stopDemandTooltip() .. "\n" .. _("The busiest leg is highlighted.")),
				icon(ICON_VEHICLES, _("Vehicles standing at this stop or on the way from it to the next one.")),
				icon(ICON_DISTANCE, distanceTooltip()),
				icon(ICON_SPEED, speedTooltip()),
				icon(ICON_TIME, _("To next: average time from this stop to the next one, including time at stations.")),
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
			-- The title-bar pin, as the game's line window has (view_manager.tl:291-293):
			-- the camera follows the line (followEntity, the line window's own locate).
			locateVisible = true,
			onLocate = function()
				if api.engine.entityExists(params.lineId) then api.gui.camera.followEntity(params.lineId, true) end
			end,
		}
		-- Centred, or where the last one was left (window_position).
		windowPosition.place(win, params.spot)
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
		title = lang_util.format(_("Line Details: {name}"), { name = name }),
		initialStop = stopIndex,
		spot = windowPosition.spotFor(WINDOW_KIND),
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

-- The card's own, narrower passenger test: the line has passenger capacity
-- or passengers waiting. A line that is "passenger" only because a vehicle
-- is configured for passengers gets the cargo row (if it has cargo).
local function cardShowsPassengers(passenger : MlsLineStats) : boolean
	return passenger.kind == "passenger" and (passenger.capacity > 0 or passenger.waitingTotal > 0)
end

-- The card's figures: the passenger collector for every line, and the
-- cargo collector too, with Waiting, for a line that gets no passenger row
-- (about a millisecond each). Timer thread: engine reads only, plain tables
-- out.
local function collectCard(lineId : Engine.Entity) : MlsCardStats
	local passenger = lineStatsHelper.collect(lineId)
	local cargo : MlsCargoStats = nil
	if passenger.kind == "cargo" or (passenger.kind == "passenger" and not cardShowsPassengers(passenger)) then
		cargo = cargoStatsHelper.collect(lineId, true)
	end
	return { passenger = passenger, cargo = cargo }
end

-- One row of icon-and-number cells, the Line Details summary figures for
-- a passenger line, load and journey figures for a cargo line; nil for a
-- line with nothing to show (no vehicles, missing, not yet read).
local function cardRow(stats : MlsCardStats) : TreeNodeId
	if stats == nil then return nil end
	local passenger = stats.passenger
	if cardShowsPassengers(passenger) then
		return tableRow(CARD_PASSENGER_WEIGHTS, {
			iconCell(ICON_DEMAND, demandStr(passenger), demandTooltip()),
			iconCell(ICON_WAITING, tostring(passenger.waitingTotal), waitingTooltip()),
			iconCell(ICON_UNHAPPY, tostring(passenger.unhappyWaitingTotal + passenger.unhappyOnBoard), unhappyTooltip()),
			iconCell(ICON_DISTANCE, distanceStr(passenger.journey.distance), lengthTooltip()),
			iconCell(ICON_TIME, legTimeStr(passenger.journey), journeyTooltip(passenger.journey)),
			iconCell(ICON_SPEED, speedStr(passenger.journey), _("Average speed")),
		}, "mls-card-icons")
	end
	local cargo = stats.cargo
	if cargo ~= nil and cargo.kind == "cargo" then
		-- The Cargo tab's Load % figure: load as a share of capacity, rounded.
		local loadPct : string = "?"
		if cargo.capacity > 0 then
			loadPct = tostring(math.floor(cargo.onBoard * 100 / cargo.capacity + 0.5)) .. "%"
		end
		return tableRow(CARD_CARGO_WEIGHTS, {
			iconCell(ICON_CARGO, loadPct, _("Utilization")),
			iconCell(ICON_WAITING, fmt.waitingStr(cargo.waiting), fmt.cargoWaitingTooltip()),
			iconCell(ICON_DISTANCE, distanceStr(cargo.journey.distance), lengthTooltip()),
			iconCell(ICON_TIME, legTimeStr(cargo.journey), journeyTooltip(cargo.journey)),
			iconCell(ICON_SPEED, speedStr(cargo.journey), _("Average speed")),
		}, "mls-card-icons")
	end
	return nil
end

-- The figures row (when there is one) above two blue "primary" buttons,
-- always both. The row's data comes from a 5 s timer, as in the windows;
-- the first read runs at mount. A line without passengers or without cargo
-- gets a message in the window instead.
local MlsCardContent = react.RegisterRecipe(
	"MlsCardContent",
	function(params : CardParams) : TreeNodeId
		local lineId : Engine.Entity = params.lineId
		local statsState = engine_react_util.useStepStateTimer(function() : MlsCardStats
			return collectCard(lineId)
		end, REFRESH_SECONDS)
		local row = cardRow(statsState:old())

		local buttons = builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = {
				-- A second class (comma-joined, as the game does) gives the
				-- first button a right margin, so the two don't touch.
				button_react_util.makeTextButton(
					"primary,mls-card-btn",
					_("Passengers"),
					function() openLineDetails(params.lineId) end,
					_("Open Line Details")),
				button_react_util.makeTextButton(
					"primary",
					_("Cargo"),
					function() cargoGui.openCargoDetails(params.lineId) end,
					_("Open Cargo Details")),
				gui_react_util.makeHorizontalSpacer(),
			},
		}
		-- The row is a Component (a table row), the buttons a layout: both
		-- are allowed as children of a BoxLayout.
		local children : {TreeNodeId} = {}
		if row ~= nil then children[#children + 1] = row end
		children[#children + 1] = buttons
		return builtin.BoxLayout{
			orientation = builtin.type.Orientation.Vertical,
			children = children,
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
