-- More Line Stats: the HUD button and the all-lines window.
--
-- The button (registered by lines_plugin.res.lua on the HUD's mod-button
-- area) is a toggle that opens one singleton window listing every passenger
-- line. The list is computed when the window opens and when Refresh is
-- pressed, never on a timer: both are event handlers, where engine reads
-- are allowed. Nothing reads the engine in a recipe body.

local react              = ug_require "::/gui/main/react.lua" as React
local builtin            = ug_require "::/gui/main/builtin.lua" as Builtin
local game_react_globals = ug_require "::/gui/main/game_react_globals.tl" as GameReactGlobals
local gui_react_util     = ug_require "::/gui/main/gui_react_util.tl" as GuiReactUtil
local button_react_util  = ug_require "::/gui/main/button_react_util.tl" as ButtonReactUtil
local line_react_util    = ug_require "::/gui/line_vehicle_mgmt/line_react_util.tl" as LineReactUtil
local main_mod_button_area = ug_require "::/gui/main/main_mod_button_area.tl" as MainModButtonArea

-- Own modules: path constant plus a cast to the record in tealdef/mls_def.d.tl.
local LINES_HELPER : string = "bottle_more_line_stats::/scripts/lines_helper.script.tl"
local LUA_UTILS : string = "bottle_more_line_stats::/scripts/lua_utils.script.tl"
local FORMATTING : string = "bottle_more_line_stats::/gui/formatting.script.tl"
local WIDGETS : string = "bottle_more_line_stats::/gui/widgets.script.tl"
local LINE_GUI : string = "bottle_more_line_stats::/gui/line_gui.script.tl"
local linesHelper = require(LINES_HELPER) as MlsLinesHelper
local luaUtils = require(LUA_UTILS) as MlsLuaUtils
local fmt = require(FORMATTING) as MlsFormatting
local widgets = require(WIDGETS) as MlsWidgets
local lineGui = require(LINE_GUI) as MlsLineGui

local text, sectionTitle = widgets.text, widgets.sectionTitle

-- Dotted like the timetable mod's id: the stylesheet rule "Window#<id>"
-- that centres the window is keyed on it.
local WINDOW_ID : string = "mls.lines.window"

-- Columns: colour, line, demand, demand %, load/capacity, waiting, unhappy,
-- busiest stop, journey, length, speed, frequency. The gap before the
-- scrollbar comes from the row box being narrower than the scroll area
-- (mls.css.lua).
local COLUMN_WEIGHTS : {number} = { 0.8, 6.85, 2.35, 2.95, 2.5, 2.4, 2.4, 2.4, 2.5, 2.5, 2.5, 2 }

-- Base-game icons: the waiting-passenger marker in the rows and the
-- Unhappy column header.
local ICON_PASSENGERS : string = "::/cargos/passengers/passengers.tga"
local ICON_UNHAPPY : string = "::/gui/main/icons/symbol_emote_sad_colored.tga"
-- Sort direction markers (the game's own table arrows).
local ICON_SORT_ASC : string = "::/gui/component/table_arrow_up.tga"
local ICON_SORT_DESC : string = "::/gui/component/table_arrow_down.tga"

-- Carrier filter buttons: one per vehicle kind a passenger line can have
-- (MlsLineRow.kind), with the game's HUD icons. "all" has no icon.
local record KindFilter
	kind : string
	iconPath : string
	tooltip : string
end
local KIND_FILTERS : {KindFilter} = {
	{ kind = "bus", iconPath = "::/gui/hud/icons/vehicle_bus.tga", tooltip = "Bus lines only" },
	{ kind = "tram", iconPath = "::/gui/hud/icons/vehicle_tram.tga", tooltip = "Tram lines only" },
	{ kind = "train", iconPath = "::/gui/hud/icons/vehicle_train.tga", tooltip = "Train lines only" },
	{ kind = "ship", iconPath = "::/gui/hud/icons/vehicle_ship.tga", tooltip = "Ship lines only" },
	{ kind = "aircraft", iconPath = "::/gui/hud/icons/vehicle_airplane.tga", tooltip = "Plane lines only" },
	{ kind = "helicopter", iconPath = "::/gui/hud/icons/vehicle_helicopter.tga", tooltip = "Helicopter lines only" },
}

------------------------------------------------------------
-- TYPES
------------------------------------------------------------

local record LinesWindowParams
	onClose : function()
	table : MlsLinesTable   -- computed by the button's click handler
end

-- Which column the list is sorted by. Lives in the window's state, so
-- Refresh keeps it.
local record SortState
	key : string
	ascending : boolean
end

-- Which rows are shown: one vehicle kind or "all", and a name search.
-- Lives in the window's state, so Refresh keeps it.
local record FilterState
	kind : string
	search : string
end

-- A sortable column: a text header (label) or an icon header (iconPath),
-- and the value to sort by (nil for the name, which sorts alphabetically).
local record Column
	key : string
	label : string
	iconPath : string
	tooltip : string
	value : function(MlsLineRow) : number
end

------------------------------------------------------------
-- WIDGET HELPERS (the shared ones live in gui/widgets.script.tl)
------------------------------------------------------------

local function num(str : string, tooltip? : string) : TreeNodeId
	return text(str, "font-scale-body, mls-time", tooltip)
end

-- A number with a small icon after it (Waiting and Unhappy), right-aligned
-- like the plain numbers.
local function iconNum(path : string, str : string, tooltip? : string) : TreeNodeId
	return builtin.Component{
		layout = builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = {
				gui_react_util.makeHorizontalSpacer(),
				text(str, "font-scale-body, mls-cell-num", tooltip),
				builtin.ImageView{
					meta = { class = "mls-cell-icon", tooltip = tooltip },
					path = path,
					scaling = builtin.type.ImageViewScaling.AutoFit,
				},
			},
		},
	}
end

local function tableRow(cells : {TreeNodeId}, class? : string) : TreeNodeId
	return widgets.tableRow(COLUMN_WEIGHTS, cells, class)
end

------------------------------------------------------------
-- TABLE
------------------------------------------------------------

-- Average speed as a number for sorting: length over driving time, the
-- total time without one; 0 if unknown.
local function speedOf(row : MlsLineRow) : number
	local seconds = row.journey.drive > 0 and row.journey.drive or row.journey.time
	if row.journey.distance <= 0 or seconds <= 0 then return 0 end
	return row.journey.distance / seconds
end

-- One entry per header cell after the colour swatch, in column order.
local COLUMNS : {Column} = {
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

-- A header cell: a chrome-less button that fills the whole cell (so the
-- hover highlight covers it, as in the game's own tables), holding the
-- label or icon and the sort arrow when this is the sorted column.
-- Right-aligned like the numbers below, except the Name header.
local function headerCell(col : Column, sort : SortState, onSort : function(string)) : TreeNodeId
	local tooltip = col.tooltip .. "\nClick to sort by this column; click again to reverse."
	-- The button centres its content by default; the two classes anchor it
	-- left (Name) or right (the numbers) in the stylesheet.
	local left = col.key == "name"
	local content : {TreeNodeId} = {}
	if col.label ~= nil then
		content[#content + 1] = text(col.label, "font-scale-annotation", tooltip)
	else
		content[#content + 1] = builtin.ImageView{
			meta = { class = "mls-header-icon", tooltip = tooltip },
			path = col.iconPath,
			scaling = builtin.type.ImageViewScaling.AutoFit,
		}
	end
	if sort.key == col.key then
		content[#content + 1] = builtin.ImageView{
			meta = { class = "mls-sort-arrow", tooltip = tooltip },
			path = sort.ascending and ICON_SORT_ASC or ICON_SORT_DESC,
			scaling = builtin.type.ImageViewScaling.AutoFit,
		}
	end
	return builtin.Button{
		meta = { class = left and "mls-header-btn, mls-header-left" or "mls-header-btn, mls-header-right", tooltip = tooltip },
		content = builtin.Component{
			layout = builtin.BoxLayout{
				orientation = builtin.type.Orientation.Horizontal,
				children = content,
			},
		},
		onClick = function() onSort(col.key) end,
	}
end

local function headerRow(sort : SortState, onSort : function(string)) : TreeNodeId
	local cells : {TreeNodeId} = { text("", "font-scale-annotation") }
	for _, col in ipairs(COLUMNS) do
		cells[#cells + 1] = headerCell(col, sort, onSort)
	end
	return tableRow(cells, "mls-lines-header")
end

local function lineRow(row : MlsLineRow) : TreeNodeId
	local nameNode = line_react_util.NameTextView{
		entity = row.lineId,
		onClickOverride = function(entity : Engine.Entity) lineGui.openLineDetails(entity) end,
		tooltip = "Open Line Details",
		styleClass = "mls-line-name",
	}
	local frequency = row.frequency > 0 and luaUtils.getTimeStr(row.frequency) or "?"
	-- The colour swatch opens the game's own line window (the "selectEntity"
	-- event is what the timetable mod fires for the same purpose).
	local colourButton = builtin.Button{
		meta = { class = "mls-colour-btn", tooltip = "Open the game's line window" },
		content = line_react_util.ColorWidget{ entity = row.lineId },
		onClick = function()
			react.fireEvent(nil, "selectEntity", { entity = row.lineId, stack = true })
		end,
	}
	return tableRow({
		colourButton,
		nameNode,
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

------------------------------------------------------------
-- FILTERS
------------------------------------------------------------

local function filterToggle(content : TreeNodeId, tooltip : string, checked : boolean, onPress : function()) : TreeNodeId
	return builtin.ToggleButton{
		meta = { class = "mls-filter-btn", tooltip = tooltip },
		content = content,
		value = checked and 1 or 0,
		onValueChange = function(value : integer)
			-- Pressing the active button again keeps it active: the
			-- filter always has exactly one choice.
			if value == 1 or checked then onPress() end
		end,
	}
end

-- "All" and one button per vehicle kind, then the search box.
local function filterRow(filter : FilterState, onKind : function(string), onSearch : function(string)) : TreeNodeId
	local children : {TreeNodeId} = {
		filterToggle(text("All", "font-scale-body"), "All passenger lines", filter.kind == "all",
			function() onKind("all") end),
	}
	for _, kindFilter in ipairs(KIND_FILTERS) do
		local kind = kindFilter.kind
		children[#children + 1] = filterToggle(
			builtin.ImageView{
				meta = { class = "mls-header-icon" },
				path = kindFilter.iconPath,
				scaling = builtin.type.ImageViewScaling.AutoFit,
			},
			kindFilter.tooltip, filter.kind == kind, function() onKind(kind) end)
	end
	children[#children + 1] = gui_react_util.makeHorizontalSpacer()
	children[#children + 1] = builtin.TextInputField{
		meta = { class = "mls-search", tooltip = "Show only lines whose name contains this text. Search several terms using commas, e.g. \"Line 1, Line 2\"." },
		value = filter.search,
		placeholderText = "Search lines. Search several terms using commas, e.g. \"Line 1, Line 2\".",
		onTyping = onSearch,
		onValueChange = onSearch,
		acceptOnFocusLoss = true,
	}
	return builtin.Component{
		meta = { class = "mls-filter-row" },
		layout = builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = children,
		},
	}
end

-- The search text as lower-case terms: split on commas, blanks trimmed,
-- empty terms dropped. "Line 1, Line 2" matches either name.
local function searchTerms(search : string) : {string}
	local terms : {string} = {}
	for part in string.gmatch(string.lower(search or ""), "[^,]+") do
		local term = string.match(part, "^%s*(.-)%s*$")
		if term ~= "" then terms[#terms + 1] = term end
	end
	return terms
end

local function nameMatches(name : string, terms : {string}) : boolean
	if #terms == 0 then return true end
	local lower = string.lower(name)
	for _, term in ipairs(terms) do
		if string.find(lower, term, 1, true) ~= nil then return true end
	end
	return false
end

-- Rows that pass the kind and search filters.
local function filteredRows(linesTable : MlsLinesTable, filter : FilterState) : {MlsLineRow}
	local terms = searchTerms(filter.search)
	local rows : {MlsLineRow} = {}
	for _, row in ipairs(linesTable.rows) do
		if (filter.kind == "all" or row.kind == filter.kind) and nameMatches(row.name, terms) then
			rows[#rows + 1] = row
		end
	end
	return rows
end

local function columnByKey(key : string) : Column
	for _, col in ipairs(COLUMNS) do
		if col.key == key then return col end
	end
	return COLUMNS[1]
end

-- The given rows in the chosen order (sorted in place). Numbers tie-break
-- by name, A to Z.
local function sortRows(rows : {MlsLineRow}, sort : SortState) : {MlsLineRow}
	local col = columnByKey(sort.key)
	local function byName(rowA : MlsLineRow, rowB : MlsLineRow) : boolean
		return string.lower(rowA.name) < string.lower(rowB.name)
	end
	table.sort(rows, function(rowA : MlsLineRow, rowB : MlsLineRow) : boolean
		if col.value == nil then
			if sort.ascending then return byName(rowA, rowB) end
			return byName(rowB, rowA)
		end
		local valueA, valueB = col.value(rowA), col.value(rowB)
		if valueA == valueB then return byName(rowA, rowB) end
		if sort.ascending then return valueA < valueB end
		return valueA > valueB
	end)
	return rows
end

-- The scrolling list box. It is always there, even with no rows (then it
-- holds `emptyMessage`), so the window keeps the same layout. The scroll
-- area stretches its content to the viewport width, so the rows sit in a
-- fixed-width box beside a spacer and keep their width at any text scale.
local function linesList(shown : {MlsLineRow}, sort : SortState, emptyMessage : string) : TreeNodeId
	local rows : {TreeNodeId} = {}
	for _, row in ipairs(sortRows(shown, sort)) do
		rows[#rows + 1] = lineRow(row)
	end
	if #rows == 0 then rows[1] = text(emptyMessage, "font-scale-body") end
	return builtin.ScrollArea{
		meta = { class = "mls-lines-scrollarea" },
		content = builtin.Component{
			layout = builtin.BoxLayout{
				orientation = builtin.type.Orientation.Horizontal,
				children = {
					builtin.Component{
						meta = { class = "mls-lines-scroll" },
						layout = builtin.BoxLayout{
							orientation = builtin.type.Orientation.Vertical,
							children = rows,
						},
					},
					gui_react_util.makeHorizontalSpacer(),
				},
			},
		},
		horizontalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
		-- The rows sit in a fixed-width box (see above), so the bar can
		-- come and go without moving them.
		verticalPolicy = builtin.type.ScrollBarPolicy.AsNeeded,
	}
end

local function footer(linesTable : MlsLinesTable) : string
	local parts : {string} = {}
	if linesTable.cargoLines > 0 then
		parts[#parts + 1] = tostring(linesTable.cargoLines) .. (linesTable.cargoLines == 1 and " cargo line" or " cargo lines")
	end
	if linesTable.otherLines > 0 then
		parts[#parts + 1] = tostring(linesTable.otherLines) .. (linesTable.otherLines == 1 and " line" or " lines") .. " without vehicles"
	end
	if #parts == 0 then return nil end
	return table.concat(parts, " and ") .. " not shown."
end

------------------------------------------------------------
-- WINDOW
------------------------------------------------------------

local LinesWindowContent = react.RegisterRecipe(
	"MlsLinesWindowContent",
	function(params : LinesWindowParams) : TreeNodeId
		react.useInputAction("IA_MENU_BACK", react.iaHandler(params.onClose))

		-- The rows live in state so Refresh can replace them. The first
		-- value is what the button's click handler computed.
		local tableState = react.useState(params.table) as ReactStateT<MlsLinesTable>
		local linesTable : MlsLinesTable = tableState:old()

		-- Name A to Z on open. A click on the sorted column reverses it; a
		-- click on another column sorts by that, numbers largest first.
		local sortState = react.useState({ key = "name", ascending = true } as SortState) as ReactStateT<SortState>
		local sort : SortState = sortState:old() or { key = "name", ascending = true }
		local function onSort(key : string)
			if key == sort.key then
				sortState:set({ key = key, ascending = not sort.ascending } as SortState)
			else
				sortState:set({ key = key, ascending = key == "name" } as SortState)
			end
		end

		-- All lines, no search, on open.
		local filterState = react.useState({ kind = "all", search = "" } as FilterState) as ReactStateT<FilterState>
		local filter : FilterState = filterState:old() or { kind = "all", search = "" }
		local function onKind(kind : string)
			filterState:set({ kind = kind, search = filter.search } as FilterState)
		end
		local function onSearch(search : string)
			filterState:set({ kind = filter.kind, search = search or "" } as FilterState)
		end

		local refresh = button_react_util.makeTextButton("primary", "Refresh",
			function() tableState:set(linesHelper.collectAll()) end,
			"Read all lines again. The list does not refresh by itself.")

		local children : {TreeNodeId} = {}
		if linesTable == nil then
			children[1] = text("Loading...", "font-scale-body")
		elseif linesTable.error ~= nil then
			children[1] = sectionTitle("Could not read the lines", nil, refresh)
			children[2] = text(tostring(linesTable.error), "font-scale-body")
		else
			local count = #linesTable.rows
			local shown = filteredRows(linesTable, filter)
			local title = tostring(count) .. (count == 1 and " passenger line" or " passenger lines")
			if #shown ~= count then title = tostring(#shown) .. " of " .. title end
			children[1] = sectionTitle(title, "Figures as they were when the list was computed; press Refresh for current ones.", refresh)
			if count == 0 then
				children[2] = text("You have no passenger lines with vehicles.", "font-scale-body")
			else
				children[2] = filterRow(filter, onKind, onSearch)
				children[3] = headerRow(sort, onSort)
				children[4] = linesList(shown, sort, "No line matches the filter.")
			end
			-- The window has a fixed height; the spacer takes the leftover
			-- room so the parts above pack together instead of spreading
			-- out, and the footer stays at the bottom.
			children[#children + 1] = gui_react_util.makeVerticalSpacer()
			local note = footer(linesTable)
			if note ~= nil then children[#children + 1] = text(note, "font-scale-annotation") end
		end

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

		-- Click handler: engine reads are allowed here, so the list is
		-- computed before the window opens and handed over as a parameter.
		local function open()
			local winApi = game_react_globals.getDefaultWindowApi()
			if winApi == nil then return end
			local linesTable = linesHelper.collectAll()
			winApi.addSingletonWindow(LinesWindow, { onClose = onClose, table = linesTable } as LinesWindowParams)
			windowIsOpen = true
			openState:set(true)
			luaUtils.debug("lines window opened with " .. tostring(#linesTable.rows) .. " rows")
		end

		return builtin.BoxLayout{
			children = {
				builtin.ToggleButton{
					meta = { tooltip = "Statistics for all of your passenger lines.", class = "mls-toolbar-btn" },
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
