-- More Line Stats: the Cargo Details windows (the cargo counterpart of
-- line_gui's Line Details; the TF2 mod had cargoLineGui.lua in the same
-- role). Opened by the Cargo button on the line-window card (in line_gui).
-- One window per line, keyed by line id. Master-detail: summary and stop
-- list on the left; on the right the cargo types the line carries and the
-- vehicles on the selected section.
--
-- This module never requires line_gui (line_gui requires it), so there is
-- no cycle. No engine reads happen in recipe bodies: all data comes from
-- useStepStateTimer. Event handlers may read the engine.

local react              = ug_require "::/gui/main/react.lua" as React
local builtin            = ug_require "::/gui/main/builtin.lua" as Builtin
local engine_react_util  = ug_require "::/gui/main/engine_react_util.tl" as EngineReactUtil
local gui_react_util     = ug_require "::/gui/main/gui_react_util.tl" as GuiReactUtil
local button_react_util  = ug_require "::/gui/main/button_react_util.tl" as ButtonReactUtil
local game_react_globals = ug_require "::/gui/main/game_react_globals.tl" as GameReactGlobals
local lang_util          = ug_require "::/scripts/lang_util.tl" as LangUtil

-- Own modules go through a path constant and a cast to their record in
-- tealdef/mls_def.d.tl, because `tl check` can't resolve "<modId>::/" paths.
local CARGO_STATS_HELPER : string = "bottle_more_line_stats::/scripts/cargo_stats_helper.script.tl"
local LUA_UTILS : string = "bottle_more_line_stats::/scripts/lua_utils.script.tl"
local FORMATTING : string = "bottle_more_line_stats::/gui/formatting.script.tl"
local WIDGETS : string = "bottle_more_line_stats::/gui/widgets.script.tl"
local cargoStatsHelper = require(CARGO_STATS_HELPER) as MlsCargoStatsHelper
local luaUtils = require(LUA_UTILS) as MlsLuaUtils
local fmt = require(FORMATTING) as MlsFormatting
local widgets = require(WIDGETS) as MlsWidgets
-- The sortable header of the Lines window, for the section's Cargo table.
local LIST_TABLE : string = "bottle_more_line_stats::/gui/list_table.script.tl"
local listTable = require(LIST_TABLE) as MlsListTable
-- Where the window reopens.
local WINDOW_POSITION : string = "bottle_more_line_stats::/gui/window_position.script.tl"
local windowPosition = require(WINDOW_POSITION) as MlsWindowPosition
local WINDOW_KIND : string = "cargoDetails"

local text, tableRow, icon, iconCell = widgets.text, widgets.tableRow, widgets.icon, widgets.iconCell
local locateButton, stopLocateButton = widgets.locateButton, widgets.stopLocateButton
local styledColumn, sectionTitle, vehiclesCell = widgets.styledColumn, widgets.sectionTitle, widgets.vehiclesCell
local cargoIcon, vehicleRow = widgets.cargoIcon, widgets.vehicleRow
local legTimeStr, legTooltip, distanceStr, speedStr, journeyTooltip =
	fmt.legTimeStr, fmt.legTooltip, fmt.distanceStr, fmt.speedStr, fmt.journeyTooltip
local distanceTooltip, speedTooltip = fmt.distanceTooltip, fmt.speedTooltip

local REFRESH_SECONDS : number = 5.0

-- Column weights, shared by header and rows so the columns line up.
-- Stop list: #+pin, Stop, Loads, Waiting, On section, Vehicles, Distance, Speed, To next.
-- The 720 px left column gives about 29 px per weight unit (Waiting took a
-- unit each from Stop and Speed, 2026-11-11, then one more from Stop).
local STOP_COLUMN_WEIGHTS : {number} = { 2, 4, 3, 3, 2, 2, 3, 2, 3 }
-- Cargo on the selected section: icon, load, waiting, unhappy, line
-- capacity, wait ratio (no names, user 2026-11-12). The 412 px right column
-- gives about 27 px per unit.
local TYPE_COLUMN_WEIGHTS : {number} = { 1, 3, 3, 2, 3, 3 }
-- Summary: Load/capacity, Waiting, Rate, Unhappy, Length, Frequency, Journey.
local SUMMARY_COLUMN_WEIGHTS : {number} = { 3, 2, 2, 2, 2, 2, 2 }

-- Base-game icons. The game resolves the "@2x" files itself.
-- Generic cargo (the game's "mixed cargo" icon) for totals over all types,
-- and the line window's own Rate icon.
local ICON_CARGO : string = "::/cargos/icons/cargo_mixed.tga"
local ICON_RATE : string = "::/gui/entity_window/icons/symbol_cargo.tga"
-- Waiting: the station icon passenger Waiting uses (user's pick, 2026-11-12).
local ICON_WAITING : string = "::/gui/entity_window/icons/building_stations.tga"
local ICON_UNHAPPY : string = "::/gui/main/icons/symbol_emote_sad_colored.tga"
local ICON_DISTANCE : string = "::/gui/game_bar/icons/statistics_line_26.tga"
local ICON_SPEED : string = "::/gui/entity_window/icons/symbol_speed.tga"
local ICON_TIME : string = "::/gui/main/icons/calendar_speed.tga"
local ICON_FREQUENCY : string = "::/gui/entity_window/icons/symbol_stop_watch.tga"

-- Texts used in more than one place. Functions, not constants: _() runs at
-- use time, never at load.
local function moreTooltip() : string
	return _("Show, for the selected stop, the vehicles on the way to the next stop, and the cargo types this line carries.")
end
local function onSectionTooltip() : string
	return _("On section: cargo on the vehicles between this stop and the next one now (vehicles loading at this stop included).")
end
local function lineCapacityTooltip() : string
	return _("Capacity: the line's total capacity for this type.")
end
local function waitRatioTooltip() : string
	return _("Wait ratio: the cargo waiting at this stop divided by the line's capacity for this type.")
end
local function waitingTooltip() : string
	return _("Waiting: the cargo this stop loads, in the stocks of the industries and warehouses it reaches.") .. "\n"
		.. _("Shared with every line that reaches them.")
end

------------------------------------------------------------
-- TYPES
------------------------------------------------------------

local record WindowParams
	lineId : Engine.Entity
	title : string
	onClose : function()
	spot : MlsWindowSpot   -- where the window opens; nil = centred
end

------------------------------------------------------------
-- WINDOW STATE (GUI thread only)
------------------------------------------------------------

-- Lines with an open Cargo Details window, so the button can bring it to
-- the front instead of opening a duplicate.
local openWindows : {Engine.Entity : boolean} = {}

-- Window keys share one container with the base game and with Line
-- Details; a duplicate key crashes the UI.
local function windowKey(lineId : Engine.Entity) : string
	return "mls_cargoDetails_" .. tostring(lineId)
end

------------------------------------------------------------
-- WIDGET HELPERS
------------------------------------------------------------

local function stopRow(cells : {TreeNodeId}) : TreeNodeId
	return tableRow(STOP_COLUMN_WEIGHTS, cells)
end

-- Shown instead of stats for lines that have none; nil for a cargo line.
local function messageFor(stats : MlsCargoStats) : string
	if stats == nil then return _("Loading...") end
	if stats.kind == "nocargo" then return _("This line carries no cargo.") end
	if stats.kind == "empty" then return _("This line has no vehicles.") end
	if stats.kind == "missing" then return _("This line no longer exists.") end
	if stats.kind == "error" then return fmt.couldNotRead(stats.error) end
	return nil
end

------------------------------------------------------------
-- STOP LIST (left)
------------------------------------------------------------

-- The Loads cell: the icons of the types this stop is configured to load
-- (shared with the lines window's Cargo column).
local function loadsCell(loads : {MlsCargoType}) : TreeNodeId
	return widgets.cargoTypesCell(loads, _("Loaded here:"), _("No cargo is loaded at this stop."))
end

local function stopList(stats : MlsCargoStats, selected : integer, onSelect : function(integer)) : TreeNodeId
	local rows : {TreeNodeId} = {}
	local count = #stats.stops
	-- The legs carrying the most cargo are highlighted; ties are all highlighted.
	local maxLoad = 0
	for i = 1, count do maxLoad = math.max(maxLoad, stats.legLoad[i] or 0) end
	-- So is the stop with the most waiting.
	local maxWaiting = 0
	for i = 1, count do maxWaiting = math.max(maxWaiting, stats.stopWaiting[i] or -1) end
	local onSectionTip = onSectionTooltip()
	local fullestNote = _("The fullest section of this line.")
	local speedTip = speedTooltip()
	local waitingTip = waitingTooltip()
	for i = 1, count do
		local leg = stats.legs[i] or { time = 0, drive = 0, estimated = false, distance = 0 }
		local name = stats.stopNames[i] or "?"
		local onLeg = stats.legLoad[i] or 0
		local vehicles = stats.legVehicles[i] or 0
		local atStation = stats.legAtStation[i] or 0
		local kind = widgets.kindOnLeg(stats.vehicles, i)

		local busiest = onLeg > 0 and onLeg == maxLoad
		local loadTip = onSectionTip
		if stats.legLoadByType[i] ~= nil and stats.legLoadByType[i] ~= "" then
			loadTip = loadTip .. "\n" .. stats.legLoadByType[i]
		end
		if busiest then loadTip = loadTip .. "\n" .. fullestNote end

		-- "-" when the stop loads nothing or reaches no stock.
		local waiting = stats.stopWaiting[i] or -1
		local waitingCellTip = waitingTip
		if stats.stopWaitingByType[i] ~= nil and stats.stopWaitingByType[i] ~= "" then
			waitingCellTip = waitingCellTip .. "\n" .. stats.stopWaitingByType[i]
		end

		local distanceTip = leg.distance > 0
			and distanceTooltip()
			or _("No position known for one of the two stations.")

		rows[i] = stopRow({
			stopLocateButton(i, stats.stops[i]),
			text(name, "font-scale-body"),
			loadsCell(stats.stopLoads[i] or {}),
			text(waiting >= 0 and tostring(waiting) or "-",
				(waiting > 0 and waiting == maxWaiting) and "font-scale-body, mls-time, mls-busiest" or "font-scale-body, mls-time",
				waitingCellTip),
			text(tostring(onLeg), busiest and "font-scale-body, mls-time, mls-busiest" or "font-scale-body, mls-time", loadTip),
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
-- 2026-11-11; the locate pin is in the title bar), then one row of
-- icon-and-label cells. Totals over all types carry the generic cargo icon.
local function summaryBlock(stats : MlsCargoStats, lineWindow : TreeNodeId, lineManager : TreeNodeId, toggle : TreeNodeId) : TreeNodeId
	local frequency = stats.frequency > 0 and luaUtils.getTimeStr(stats.frequency) or "?"
	-- "Coal: 12/40" per type: names and numbers only, nothing to translate.
	local perType : {string} = {}
	for _, cargoType in ipairs(stats.types) do
		perType[#perType + 1] = cargoType.name .. ": " .. tostring(cargoType.onBoard) .. "/" .. tostring(cargoType.capacity)
	end
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
			iconCell(ICON_CARGO, tostring(stats.onBoard) .. "/" .. tostring(stats.capacity),
				fmt.loadCapacityTooltip() .. "\n"
				.. table.concat(perType, "\n")),
			iconCell(ICON_WAITING, fmt.waitingStr(stats.waiting), fmt.cargoWaitingTooltip()),
			iconCell(ICON_RATE, tostring(stats.rate),
				_("Rate: the game's own line rate.")),
			iconCell(ICON_UNHAPPY, tostring(stats.unhappy),
				fmt.delayedTooltip()),
			iconCell(ICON_DISTANCE, distanceStr(stats.journey.distance),
				_("Length: line length as the crow flies.")),
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
-- VEHICLES ON THE SELECTED LEG (right, below the cargo table)
------------------------------------------------------------

-- The vehicles between the selected stop and the next one. Reads the same
-- 5 s data as the stop list, so no timer of its own.
local function vehiclesPanel(stats : MlsCargoStats, selected : integer) : TreeNodeId
	local rows : {TreeNodeId} = {}
	for _, vehicle in ipairs(stats.vehicles) do
		if vehicle.leg == selected then rows[#rows + 1] = vehicleRow(vehicle) end
	end
	local children : {TreeNodeId} = {
		sectionTitle(_("Vehicles")),
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
-- CARGO ON THE SELECTED SECTION (right, above the vehicles)
------------------------------------------------------------

-- Per-type figures of the section from the selected stop to the next one.
-- waiting -1 = the stop doesn't load the type or reaches no stock ("-");
-- unhappy -1 = a vehicle's quality could not be read ("?"); waitRatio -1 =
-- no waiting figure or no capacity ("-").
local record SectionRow
	cargoType : MlsCargoType
	load : integer
	waiting : integer
	unhappy : integer
	capacity : integer
	waitRatio : number
end

-- "0.4x", "2.5x" below 10, "10x", "23x" from there (rounded as shown, so
-- the highlight and the sort match what is read).
local function roundRatio(ratio : number) : number
	if ratio < 9.95 then return math.floor(ratio * 10 + 0.5) / 10 end
	return math.floor(ratio + 0.5)
end
local function ratioStr(ratio : number) : string
	if ratio < 0 then return "-" end
	if ratio < 10 then return string.format("%.1fx", ratio) end
	return string.format("%dx", math.floor(ratio))
end

local function sectionRowOf(stats : MlsCargoStats, cargoType : MlsCargoType, selected : integer) : SectionRow
	local stopWaiting = stats.stopTypeWaiting[selected]
	local waiting = stopWaiting ~= nil and stopWaiting[cargoType.id] or -1
	local waitRatio : number = -1
	if waiting >= 0 and cargoType.capacity > 0 then
		waitRatio = roundRatio(waiting / cargoType.capacity)
	end
	return {
		cargoType = cargoType,
		load = (stats.legTypeLoad[selected] or {})[cargoType.id] or 0,
		waiting = waiting,
		unhappy = stats.sectionUnhappyRead and ((stats.legTypeUnhappy[selected] or {})[cargoType.id] or 0) or -1,
		capacity = cargoType.capacity,
		waitRatio = waitRatio,
	}
end

-- The table's columns after the icon, sortable by a header click.
local function sectionColumns() : {MlsColumn<SectionRow>}
	return {
		-- The game's noun "Load" (its tables use the same context key).
		{ key = "load", label = pGetText("noun", "Load"), tooltip = onSectionTooltip(),
			value = function(row : SectionRow) : number return row.load end },
		{ key = "waiting", label = _("Waiting"), tooltip = waitingTooltip(),
			value = function(row : SectionRow) : number return row.waiting end },
		{ key = "unhappy", iconPath = ICON_UNHAPPY, tooltip = fmt.delayedTooltip(),
			value = function(row : SectionRow) : number return row.unhappy end },
		{ key = "capacity", label = _("Capacity"), tooltip = lineCapacityTooltip(),
			value = function(row : SectionRow) : number return row.capacity end },
		{ key = "waitRatio", label = _("Wait ratio"), tooltip = waitRatioTooltip(),
			value = function(row : SectionRow) : number return row.waitRatio end },
	}
end

-- The class of a number cell: the column's top figure (above 0; ties all)
-- highlighted, amber as the stop list's fullest section, red for Unhappy.
local function numClass(value : number, top : number, highlight : string) : string
	if value > 0 and value == top then return "font-scale-body, mls-time, " .. highlight end
	return "font-scale-body, mls-time"
end

local function typeRow(row : SectionRow, top : SectionRow, columns : {MlsColumn<SectionRow>}) : TreeNodeId
	return tableRow(TYPE_COLUMN_WEIGHTS, {
		cargoIcon(row.cargoType, row.cargoType.name),
		-- 0 on Load and Unhappy shows as "-" (user, 2026-11-12), so the figures stand out.
		text(row.load > 0 and tostring(row.load) or "-", numClass(row.load, top.load, "mls-busiest"), columns[1].tooltip),
		text(fmt.waitingStr(row.waiting), numClass(row.waiting, top.waiting, "mls-busiest"), columns[2].tooltip),
		text(row.unhappy > 0 and tostring(row.unhappy) or (row.unhappy == 0 and "-" or "?"),numClass(row.unhappy, top.unhappy, "mls-unhappy"), columns[3].tooltip),
		text(tostring(row.capacity), numClass(row.capacity, top.capacity, "mls-busiest"), columns[4].tooltip),
		text(ratioStr(row.waitRatio), numClass(row.waitRatio, top.waitRatio, "mls-busiest"), columns[5].tooltip),
	}, "mls-compact-row")
end

-- One row per cargo type some stop is set to load, even when
-- the section has none of it (the rows stay put between stops), in the chosen order (largest
-- capacity first until a header is clicked). Top of the right column, so it
-- carries the Hide button for the whole column.
local function cargoTypesPanel(stats : MlsCargoStats, selected : integer, sort : MlsSortState,
		onSort : function(string), onHide : function()) : TreeNodeId
	local hide = button_react_util.makeTextButton("primary", _("<- Less"), onHide, nil)
	local columns = sectionColumns()
	local sectionRows : {SectionRow} = {}
	local top : SectionRow = { load = 0, waiting = 0, unhappy = 0, capacity = 0, waitRatio = 0 }
	-- The types the stops are set to load, each once (user, 2026-11-14),
	-- whether or not the vehicles have capacity for them at the moment: a
	-- vehicle that carries steel one way and machines the other reports
	-- capacity only for what it is set to now, and both rows must stay.
	local listed : {integer : boolean} = {}
	for _, loads in ipairs(stats.stopLoads) do
		for _, cargoType in ipairs(loads) do
			if not listed[cargoType.id] then
				listed[cargoType.id] = true
				local row = sectionRowOf(stats, cargoType, selected)
				sectionRows[#sectionRows + 1] = row
				top.load = math.max(top.load, row.load)
				top.waiting = math.max(top.waiting, row.waiting)
				top.unhappy = math.max(top.unhappy, row.unhappy)
				top.capacity = math.max(top.capacity, row.capacity)
				top.waitRatio = math.max(top.waitRatio, row.waitRatio)
			end
		end
	end
	listTable.sortRows(sectionRows, columns, sort, function(row : SectionRow) : string return row.cargoType.name end)
	local rows : {TreeNodeId} = {
		listTable.headerRow(TYPE_COLUMN_WEIGHTS, columns, sort, onSort),
	}
	for _, row in ipairs(sectionRows) do rows[#rows + 1] = typeRow(row, top, columns) end
	-- "From -> To": station names and a symbol, nothing to translate.
	local count = #stats.stops
	local nextIndex = selected < count and selected + 1 or 1
	-- "<pin> From  ->  <pin> To", each pin locating its station.
	local sectionTip = onSectionTooltip()
	local section = builtin.Component{
		layout = builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = {
				locateButton(stats.stops[selected]),
				text(stats.stopNames[selected] or "?", "font-scale-body", sectionTip),
				text("->", "font-scale-body, mls-section-arrow", sectionTip),
				locateButton(stats.stops[nextIndex]),
				text(stats.stopNames[nextIndex] or "?", "font-scale-body", sectionTip),
			},
		},
	}
	return builtin.Component{
		meta = { class = "mls-cargo-types" },
		layout = builtin.BoxLayout{
			orientation = builtin.type.Orientation.Vertical,
			children = {
				-- No tooltip: the section line below and the column headers say it.
				sectionTitle(_("Cargo"), nil, hide),
				section,
				builtin.Component{
					layout = builtin.BoxLayout{
						orientation = builtin.type.Orientation.Vertical,
						children = rows,
					},
				},
			},
		},
	}
end

------------------------------------------------------------
-- CARGO DETAILS WINDOW
------------------------------------------------------------

local CargoDetailsContent = react.RegisterRecipe(
	"MlsCargoDetailsContent",
	function(params : WindowParams) : TreeNodeId
		local lineId : Engine.Entity = params.lineId

		react.useInputAction("IA_MENU_BACK", react.iaHandler(params.onClose))
		windowPosition.usePoll(WINDOW_KIND, windowKey(lineId), params.spot)
		react.onMount(function()
			openWindows[lineId] = true
			luaUtils.debug("cargo window opened for line " .. tostring(lineId))
		end)
		-- The window can be destroyed without onClose, so reset here too.
		react.onUnmount(function()
			openWindows[lineId] = nil
			luaUtils.debug("cargo window closed for line " .. tostring(lineId))
		end)

		local statsState = engine_react_util.useStepStateTimer(function() : MlsCargoStats
			return cargoStatsHelper.collect(lineId, true, nil, true)
		end, REFRESH_SECONDS)
		local stats = statsState:old()

		-- Selected stop, 1-based; stop 1 on open.
		local selState = react.useState(1) as ReactStateT<integer>
		-- The right column is closed until the user opens it (user, 2026-11-11).
		local showState = react.useState(false) as ReactStateT<boolean>
		-- The Cargo table's order; kept while the window is open.
		local sortState = react.useState({ key = "capacity", ascending = false }) as ReactStateT<MlsSortState>

		local message = messageFor(stats)
		if message ~= nil then
			return widgets.windowBody("mls-details-narrow", { text(message, "font-scale-body") })
		end

		-- Clamp in case the line lost stops since the selection was made.
		local count = #stats.stops
		local selected : integer = selState:old()
		if selected == nil or selected < 1 or selected > count then selected = 1 end

		local shown : boolean = showState:old() == true
		-- Closed, the label names the panel with the game's own words
		-- ("Vehicles", "Cargo"), so no new translation.
		local toggle = button_react_util.makeTextButton(
			"primary, mls-summary-btn",
			shown and _("<- Less") or (_("Vehicles") .. "/" .. _("Cargo") .. " ->"),
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
				text(_("Loads"), "font-scale-annotation, mls-cargo-loads", fmt.loadsTooltip()),
				text(_("Waiting"), "font-scale-annotation, mls-time", waitingTooltip()),
				icon(ICON_CARGO, onSectionTooltip() .. "\n" .. _("The fullest section is highlighted.")),
				icon(widgets.ICON_VEHICLES, _("Vehicles standing at this stop or on the way from it to the next one.")),
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

		local right = styledColumn("mls-right", {
			cargoTypesPanel(stats, selected, sortState:old(),
				function(key : string) sortState:set(listTable.nextSort(sortState:old(), key)) end,
				function() showState:set(false) end),
			vehiclesPanel(stats, selected),
		})
		return widgets.windowBody("mls-details", { left, right })
	end)

local CargoDetailsWindow = react.RegisterWrapperRecipe(
	"MlsCargoDetailsWindow",
	builtin.Window,
	function(params : WindowParams) : TreeNodeId
		local win : builtin.WindowParam = {
			id = windowKey(params.lineId),
			title = params.title,
			onClose = params.onClose,
			closable = true,
			autoFocusOnBecomingVisible = true,
			content = CargoDetailsContent(params),
			-- The title-bar pin, as the game's line window has (see line_gui).
			locateVisible = true,
			onLocate = function()
				if api.engine.entityExists(params.lineId) then api.gui.camera.followEntity(params.lineId, true) end
			end,
		}
		-- Centred, or where the last one was left (window_position).
		windowPosition.place(win, params.spot)
		return builtin.Window(win)
	end)

local function openCargoDetails(lineId : Engine.Entity)
	if lineId == nil or not api.engine.entityExists(lineId) then return end
	local winApi = game_react_globals.getDefaultWindowApi()
	local key = windowKey(lineId)
	if openWindows[lineId] then
		luaUtils.debug("window " .. key .. " already open, bringing to front")
		winApi.moveWindowToFront(CargoDetailsWindow, key)
		return
	end
	-- The title is fixed when the window opens.
	local name : string = api.engine.util.getEntityName(lineId) or "?"
	luaUtils.debug("opening window " .. key)
	winApi.addWindow(CargoDetailsWindow, key, {
		lineId = lineId,
		title = lang_util.format(_("Cargo Details: {name}"), { name = name }),
		spot = windowPosition.spotFor(WINDOW_KIND),
		onClose = function()
			winApi.removeWindow(CargoDetailsWindow, key)
			openWindows[lineId] = nil
		end,
	} as WindowParams)
	-- Marked open at once, not only in onMount, so a second click before
	-- the window has mounted brings it to the front instead of adding a
	-- duplicate key.
	openWindows[lineId] = true
end

luaUtils.debug("cargoGui loaded")

local exports : MlsCargoGui = {
	openCargoDetails = openCargoDetails,
}
return exports
