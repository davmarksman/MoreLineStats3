-- More Line Stats: the HUD button and the all-lines window.
--
-- The button (registered by lines_plugin.res.lua on the HUD's mod-button
-- area) is a toggle that opens one singleton window with two tabs,
-- Passengers and Cargo (the Cargo tab body is in cargo_lines_gui). A tab's
-- rows are computed when the window opens on it, when the user switches to
-- it and when Refresh is pressed, never on a timer: all three are event
-- handlers, where engine reads are allowed. Nothing reads the engine in a
-- recipe body.
--
-- The tab strip is a header only, as in the game's vehicle store and
-- industry windows: its tabs have empty items (their content box is hidden
-- in mls.css.lua) and the window draws the body of the selected tab below it. The sort and filter of each tab live
-- in the window's state, so they survive a tab switch and Refresh.

local react              = ug_require "::/gui/main/react.lua" as React
local builtin            = ug_require "::/gui/main/builtin.lua" as Builtin
local game_react_globals = ug_require "::/gui/main/game_react_globals.tl" as GameReactGlobals
local gui_react_util     = ug_require "::/gui/main/gui_react_util.tl" as GuiReactUtil
local button_react_util  = ug_require "::/gui/main/button_react_util.tl" as ButtonReactUtil
local main_mod_button_area = ug_require "::/gui/main/main_mod_button_area.tl" as MainModButtonArea

-- Own modules: path constant plus a cast to the record in tealdef/mls_def.d.tl.
local LINES_HELPER : string = "bottle_more_line_stats::/scripts/lines_helper.script.tl"
local LUA_UTILS : string = "bottle_more_line_stats::/scripts/lua_utils.script.tl"
local FORMATTING : string = "bottle_more_line_stats::/gui/formatting.script.tl"
local WIDGETS : string = "bottle_more_line_stats::/gui/widgets.script.tl"
local LIST_TABLE : string = "bottle_more_line_stats::/gui/list_table.script.tl"
local CARGO_LINES_GUI : string = "bottle_more_line_stats::/gui/cargo_lines_gui.script.tl"
local LINE_GUI : string = "bottle_more_line_stats::/gui/line_gui.script.tl"
local linesHelper = require(LINES_HELPER) as MlsLinesHelper
local luaUtils = require(LUA_UTILS) as MlsLuaUtils
local fmt = require(FORMATTING) as MlsFormatting
local widgets = require(WIDGETS) as MlsWidgets
local listTable = require(LIST_TABLE) as MlsListTable
local cargoLinesGui = require(CARGO_LINES_GUI) as MlsCargoLinesGui
local lineGui = require(LINE_GUI) as MlsLineGui

local text, sectionTitle = widgets.text, widgets.sectionTitle
local num, iconNum = listTable.num, listTable.iconNum

-- Dotted like the timetable mod's id: the stylesheet rule "Window#<id>"
-- that centres the window is keyed on it.
local WINDOW_ID : string = "mls.lines.window"

-- Tab values (the TabWidget is keyed by value, not index).
local TAB_PASSENGERS : string = "passengers"
local TAB_CARGO : string = "cargo"

-- Passengers tab columns: colour, line, demand, demand %, load/capacity,
-- waiting, unhappy, busiest stop, journey, length, speed, frequency. The
-- gap before the scrollbar comes from the row box being narrower than the
-- scroll area (mls.css.lua).
local COLUMN_WEIGHTS : {number} = { 0.8, 6.85, 2.35, 2.95, 2.5, 2.4, 2.4, 2.4, 2.5, 2.5, 2.5, 2 }

-- Base-game icons: the waiting-passenger marker in the rows and the
-- Unhappy column header.
local ICON_PASSENGERS : string = "::/cargos/passengers/passengers.tga"
local ICON_UNHAPPY : string = "::/gui/main/icons/symbol_emote_sad_colored.tga"

-- Carrier filter buttons: one per vehicle kind a passenger line can have
-- (MlsLineRow.kind), with the game's HUD icons. "all" has no icon.
local KIND_FILTERS : {MlsKindFilter} = {
	{ kind = "bus", iconPath = "::/gui/hud/icons/vehicle_bus.tga", tooltip = "Bus lines only" },
	{ kind = "tram", iconPath = "::/gui/hud/icons/vehicle_tram.tga", tooltip = "Tram lines only" },
	{ kind = "train", iconPath = "::/gui/hud/icons/vehicle_train.tga", tooltip = "Train lines only" },
	{ kind = "ship", iconPath = "::/gui/hud/icons/vehicle_ship.tga", tooltip = "Ship lines only" },
	{ kind = "aircraft", iconPath = "::/gui/hud/icons/vehicle_airplane.tga", tooltip = "Plane lines only" },
	{ kind = "helicopter", iconPath = "::/gui/hud/icons/vehicle_helicopter.tga", tooltip = "Helicopter lines only" },
}

local DEFAULT_SORT : MlsSortState = { key = "name", ascending = true }
local DEFAULT_FILTER : MlsFilterState = { kind = "all", search = "" }

------------------------------------------------------------
-- TYPES
------------------------------------------------------------

-- Whichever tab the window opens on has its table computed by the button's
-- click handler; the other one is nil until the user switches to it.
local record LinesWindowParams
	onClose : function()
	tab : string
	passengerTable : MlsLinesTable
	cargoTable : MlsCargoLinesTable
end

------------------------------------------------------------
-- PASSENGERS TAB
------------------------------------------------------------

-- Average speed as a number for sorting: length over driving time, the
-- total time without one; 0 if unknown.
local function speedOf(row : MlsLineRow) : number
	local seconds = row.journey.drive > 0 and row.journey.drive or row.journey.time
	if row.journey.distance <= 0 or seconds <= 0 then return 0 end
	return row.journey.distance / seconds
end

local function nameOf(row : MlsLineRow) : string
	return row.name
end

-- One entry per header cell after the colour swatch, in column order.
local COLUMNS : {MlsColumn<MlsLineRow>} = {
	{ key = "name", label = "Name", tooltip = "Click a line to open its Line Details window." },
	{ key = "demand", label = "Demand", tooltip = "Demand: passengers on the line now, in vehicles plus waiting at stops.",
		value = function(row : MlsLineRow) : number return row.demand end },
	{ key = "demandPct", label = "Demand %",
		tooltip = "Demand as a share of the line's passenger capacity. High values mean there may not be enough vehicles.",
		value = function(row : MlsLineRow) : number return row.demandPct end },
	{ key = "load", label = "Load", tooltip = "Load / capacity: passengers in the line's vehicles now, and the line's passenger capacity.",
		value = function(row : MlsLineRow) : number return row.onBoard end },
	{ key = "waiting", label = "Waiting", tooltip = "Waiting: passengers waiting for the line at all of its stops.",
		value = function(row : MlsLineRow) : number return row.waiting end },
	{ key = "unhappy", iconPath = ICON_UNHAPPY, tooltip = "Unhappy: passengers unhappy with the line, waiting or on board, by the game's own measure.",
		value = function(row : MlsLineRow) : number return row.unhappy end },
	{ key = "busiest", label = "Busiest",
		tooltip = "Busiest: passengers waiting at the line's busiest stop.",
		value = function(row : MlsLineRow) : number return row.busiest end },
	{ key = "journey", label = "Journey", tooltip = "Journey: one full round trip, including time at stations. ~ means a leg is still estimated.",
		value = function(row : MlsLineRow) : number return row.journey.time end },
	{ key = "length", label = "Length", tooltip = "Length: line length as the crow flies.",
		value = function(row : MlsLineRow) : number return row.journey.distance end },
	{ key = "speed", label = "Speed", tooltip = "Average speed: line length over driving time.", value = speedOf },
	{ key = "frequency", label = "Freq.", tooltip = "Frequency: time between two vehicles of the line.",
		value = function(row : MlsLineRow) : number return row.frequency end },
}

local function lineRow(row : MlsLineRow) : TreeNodeId
	local frequency = row.frequency > 0 and luaUtils.getTimeStr(row.frequency) or "?"
	return widgets.tableRow(COLUMN_WEIGHTS, {
		listTable.colourButton(row.lineId),
		listTable.lineName(row.lineId, function(entity : Engine.Entity) lineGui.openLineDetails(entity) end, "Open Line Details"),
		num(tostring(row.demand)),
		num(row.capacity > 0 and (tostring(row.demandPct) .. "%") or "?"),
		num(tostring(row.onBoard) .. "/" .. tostring(row.capacity)),
		iconNum(ICON_PASSENGERS, tostring(row.waiting)),
		iconNum(ICON_UNHAPPY, tostring(row.unhappy)),
		num(tostring(row.busiest)),
		num(fmt.legTimeStr(row.journey), fmt.journeyTooltip(row.journey)),
		num(fmt.distanceStr(row.journey.distance)),
		num(fmt.speedStr(row.journey)),
		num(frequency),
	}, "mls-compact-row")
end

-- The children of the Passengers tab body: title, filters, header, list,
-- spacer, footer.
local function passengerBody(linesTable : MlsLinesTable, view : MlsListView) : {TreeNodeId}
	local children : {TreeNodeId} = {}
	if linesTable == nil then
		children[1] = text("Loading...", "font-scale-body")
		return children
	end
	if linesTable.error ~= nil then
		children[1] = sectionTitle("Could not read the lines", nil, view.refresh)
		children[2] = text(tostring(linesTable.error), "font-scale-body")
		return children
	end

	local total = #linesTable.rows
	local matches = listTable.matcher(view.filter)
	local shown : {MlsLineRow} = {}
	for _, row in ipairs(linesTable.rows) do
		if matches(row.name, row.kind) then shown[#shown + 1] = row end
	end
	local title = listTable.count(total, "passenger line", "passenger lines")
	if #shown ~= total then title = tostring(#shown) .. " of " .. title end
	children[1] = sectionTitle(title, "Figures as they were when the list was computed; press Refresh for current ones.", view.refresh)
	if total == 0 then
		children[2] = text("You have no passenger lines with vehicles.", "font-scale-body")
	else
		children[2] = listTable.filterRow(TAB_PASSENGERS, "All passenger lines", KIND_FILTERS, view.filter, view.onKind, view.onSearch)
		children[3] = listTable.headerRow(COLUMN_WEIGHTS, COLUMNS, view.sort, view.onSort)
		local rows : {TreeNodeId} = {}
		for _, row in ipairs(listTable.sortRows(shown, COLUMNS, view.sort, nameOf)) do
			rows[#rows + 1] = lineRow(row)
		end
		children[4] = listTable.scrollList(TAB_PASSENGERS, rows, "No line matches the filter.")
	end
	-- The window has a fixed height; the spacer takes the leftover room so
	-- the parts above pack together and the footer stays at the bottom.
	children[#children + 1] = gui_react_util.makeVerticalSpacer()
	local parts : {string} = {}
	if linesTable.otherLines > 0 then
		parts[#parts + 1] = listTable.count(linesTable.otherLines, "line", "lines") .. " without vehicles"
	end
	local note = listTable.footer(parts)
	if note ~= nil then children[#children + 1] = text(note, "font-scale-annotation") end
	return children
end

------------------------------------------------------------
-- WINDOW
------------------------------------------------------------

-- GUI thread only. The tab the window last showed, so it opens there again
-- (until the game is restarted).
local lastTab : string = TAB_PASSENGERS

-- One tab of the strip; the item is empty because the window draws the body.
local function tabChild(value : string, label : string, tooltip : string) : TreeNodeId
	return builtin.TabWidgetChild{
		localKey = "mls-lines-tab-" .. value,
		value = value,
		indicator = builtin.TextView{
			meta = { class = "font-scale-tab-widget-indicator", tooltip = tooltip },
			text = label,
		},
		item = builtin.Component{},
	}
end

-- A sort and a filter state for one tab, and the view handed to its body.
local function useListView(refresh : TreeNodeId) : MlsListView
	local sortState = react.useState(DEFAULT_SORT) as ReactStateT<MlsSortState>
	local filterState = react.useState(DEFAULT_FILTER) as ReactStateT<MlsFilterState>
	local sort : MlsSortState = sortState:old() or DEFAULT_SORT
	local filter : MlsFilterState = filterState:old() or DEFAULT_FILTER
	return {
		sort = sort,
		filter = filter,
		onSort = function(key : string) sortState:set(listTable.nextSort(sort, key)) end,
		onKind = function(kind : string) filterState:set({ kind = kind, search = filter.search } as MlsFilterState) end,
		onSearch = function(search : string) filterState:set({ kind = filter.kind, search = search or "" } as MlsFilterState) end,
		refresh = refresh,
	}
end

local LinesWindowContent = react.RegisterRecipe(
	"MlsLinesWindowContent",
	function(params : LinesWindowParams) : TreeNodeId
		react.useInputAction("IA_MENU_BACK", react.iaHandler(params.onClose))

		-- The tables live in state so a tab switch and Refresh can replace
		-- them. The first values are what the button's click handler computed.
		local tabState = react.useState(params.tab) as ReactStateT<string>
		local passengerState = react.useState(params.passengerTable) as ReactStateT<MlsLinesTable>
		local cargoState = react.useState(params.cargoTable) as ReactStateT<MlsCargoLinesTable>
		local tab : string = tabState:old() or TAB_PASSENGERS

		-- Event handlers: engine reads are allowed here.
		-- The debug line times the read: it runs on the GUI thread (DESIGNv3 §6.4).
		local function compute(which : string)
			local started = os.clock()
			if which == TAB_CARGO then
				cargoState:set(linesHelper.collectCargo())
			else
				passengerState:set(linesHelper.collectAll())
			end
			luaUtils.debug(string.format("lines window %s computed in %.0f ms", which, (os.clock() - started) * 1000))
		end
		local function onTab(newTab : string)
			if newTab == nil or newTab == tab then return end
			compute(newTab)
			tabState:set(newTab)
			lastTab = newTab
			luaUtils.debug("lines window tab " .. newTab)
		end

		local refresh = button_react_util.makeTextButton("primary", "Refresh",
			function() compute(tab) end,
			"Read all lines again. The list does not refresh by itself.")

		-- Both tabs' sort and filter, whichever is shown (hooks must run in
		-- the same order on every render).
		local passengerView = useListView(refresh)
		local cargoView = useListView(refresh)

		-- Q/E (or the gamepad shoulder buttons) switch tabs, as in the
		-- game's own tabbed windows.
		local tabWidgetRef = react.useNodeRef(builtin.TabWidget)
		react.useInputAction("IA_TABLEFT", react.iaForward(tabWidgetRef))
		react.useInputAction("IA_TABRIGHT", react.iaForward(tabWidgetRef))

		local children : {TreeNodeId} = {
			builtin.TabWidget(react.ref(tabWidgetRef), {
				meta = { class = "mls-lines-tabs" },
				orientation = builtin.type.TabOrientation.North,
				deselectAllowed = false,
				value = tab,
				onValueChange = function(newValue : string) onTab(newValue) end,
				tabs = {
					tabChild(TAB_PASSENGERS, "Passengers", "Lines that carry passengers, mixed lines included."),
					tabChild(TAB_CARGO, "Cargo", "Lines that carry cargo, mixed lines included."),
				},
			}),
		}
		local bodyChildren : {TreeNodeId}
		if tab == TAB_CARGO then
			bodyChildren = cargoLinesGui.body(cargoState:old(), cargoView)
		else
			bodyChildren = passengerBody(passengerState:old(), passengerView)
		end
		for _, child in ipairs(bodyChildren) do children[#children + 1] = child end

		return builtin.BoxLayout{
			child = builtin.Component{
				meta = { class = "mls-lines" },
				layout = builtin.BoxLayout{
					orientation = builtin.type.Orientation.Vertical,
					children = children,
				},
			},
		}
	end)

local LinesWindow = react.RegisterWrapperRecipe(
	"MlsLinesWindow",
	builtin.Window,
	function(params : LinesWindowParams) : TreeNodeId
		return builtin.Window{
			id = WINDOW_ID,
			title = "More Line Stats",
			onClose = params.onClose,
			closable = true,
			autoFocusOnBecomingVisible = true,
			content = LinesWindowContent(params),
		}
	end)

------------------------------------------------------------
-- HUD BUTTON
------------------------------------------------------------

-- GUI thread only. Whether the singleton window is open, so the toggle
-- button can follow it whichever way it was closed (X, Escape, toggle).
local windowIsOpen : boolean = false

local LinesButton = react.RegisterPluginRecipe(
	main_mod_button_area.MainModButtonAreaExtension,
	"MlsLinesButton",
	function() : TreeNodeId
		local openState = react.useState(false) as ReactStateT<boolean>

		local function onClose()
			local winApi = game_react_globals.getDefaultWindowApi()
			if winApi ~= nil then winApi.removeAllWindows(LinesWindow) end
			windowIsOpen = false
			openState:set(false)
			luaUtils.debug("lines window closed")
		end

		-- Click handler: engine reads are allowed here, so the shown tab's
		-- list is computed before the window opens and handed over as a
		-- parameter.
		local function open()
			local winApi = game_react_globals.getDefaultWindowApi()
			if winApi == nil then return end
			local params : LinesWindowParams = { onClose = onClose, tab = lastTab }
			if lastTab == TAB_CARGO then
				params.cargoTable = linesHelper.collectCargo()
				luaUtils.debug("lines window opened on Cargo with " .. tostring(#params.cargoTable.rows) .. " rows")
			else
				params.passengerTable = linesHelper.collectAll()
				luaUtils.debug("lines window opened on Passengers with " .. tostring(#params.passengerTable.rows) .. " rows")
			end
			winApi.addSingletonWindow(LinesWindow, params)
			windowIsOpen = true
			openState:set(true)
		end

		return builtin.BoxLayout{
			children = {
				builtin.ToggleButton{
					meta = { tooltip = "Statistics for all of your passenger and cargo lines.", class = "mls-toolbar-btn" },
					content = text("More Line Stats", "font-scale-body"),
					value = (openState:old() == true) and 1 or 0,
					onValueChange = function(value : integer)
						if value == 1 and not windowIsOpen then
							open()
						elseif value == 0 and windowIsOpen then
							onClose()
						else
							-- The window was closed another way; re-sync the toggle.
							openState:set(windowIsOpen)
						end
					end,
				},
			},
		}
	end)

luaUtils.debug("linesListGui loaded")

return {
	MlsLinesButton = LinesButton,
}
