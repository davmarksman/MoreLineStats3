-- Table pieces shared by the Passengers and Cargo tabs of the More Line
-- Stats window (lines_list_gui and cargo_lines_gui): number cells, the
-- colour and name cells, the sortable header row, the filter row, sorting,
-- filtering and the scrolling list. GUI thread; no recipes, no state, no
-- engine reads except in click handlers. Every node built here sits inside
-- the MlsLinesWindowContent recipe, so its stylesheet rules apply.
-- Types in tealdef/mls_def.d.tl (MlsListTable, MlsColumn, MlsSortState,
-- MlsFilterState, MlsKindFilter).

local react              = ug_require "::/gui/main/react.lua" as React
local builtin            = ug_require "::/gui/main/builtin.lua" as Builtin
local gui_react_util     = ug_require "::/gui/main/gui_react_util.tl" as GuiReactUtil
local line_react_util    = ug_require "::/gui/line_vehicle_mgmt/line_react_util.tl" as LineReactUtil

local WIDGETS : string = "bottle_more_line_stats::/gui/widgets.script.tl"
local widgets = require(WIDGETS) as MlsWidgets

local text = widgets.text

-- Sort direction markers (the game's own table arrows).
local ICON_SORT_ASC : string = "::/gui/component/table_arrow_up.tga"
local ICON_SORT_DESC : string = "::/gui/component/table_arrow_down.tga"

------------------------------------------------------------
-- CELLS
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

-- The colour swatch opens the game's own line window (the "selectEntity"
-- event is what the timetable mod fires for the same purpose).
local function colourButton(lineId : Engine.Entity) : TreeNodeId
	return builtin.Button{
		meta = { class = "mls-colour-btn", tooltip = "Open the game's line window" },
		content = line_react_util.ColorWidget{ entity = lineId },
		onClick = function()
			react.fireEvent(nil, "selectEntity", { entity = lineId, stack = true })
		end,
	}
end

local function lineName(lineId : Engine.Entity, onOpen : function(Engine.Entity), tooltip : string) : TreeNodeId
	return line_react_util.NameTextView{
		entity = lineId,
		onClickOverride = function(entity : Engine.Entity) onOpen(entity) end,
		tooltip = tooltip,
		styleClass = "mls-line-name",
	}
end

------------------------------------------------------------
-- HEADER
------------------------------------------------------------

-- A header cell: a chrome-less button that fills the whole cell (so the
-- hover highlight covers it, as in the game's own tables), holding the
-- label or icon and the sort arrow when this is the sorted column.
-- Right-aligned like the numbers below, except the Name header.
local function headerCell<R>(col : MlsColumn<R>, sort : MlsSortState, onSort : function(string)) : TreeNodeId
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

local function headerRow<R>(weights : {number}, columns : {MlsColumn<R>}, sort : MlsSortState, onSort : function(string)) : TreeNodeId
	local cells : {TreeNodeId} = { text("", "font-scale-annotation") }
	for _, col in ipairs(columns) do
		cells[#cells + 1] = headerCell(col, sort, onSort)
	end
	return widgets.tableRow(weights, cells, "mls-lines-header")
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
local function filterRow(tabKey : string, allTooltip : string, kinds : {MlsKindFilter}, filter : MlsFilterState,
		onKind : function(string), onSearch : function(string)) : TreeNodeId
	local children : {TreeNodeId} = {
		filterToggle(text("All", "font-scale-body"), allTooltip, filter.kind == "all",
			function() onKind("all") end),
	}
	for _, kindFilter in ipairs(kinds) do
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
		-- Keyed per tab: both tabs put a search box here, and without a key
		-- the switch would reuse it with the other tab's half-typed text.
		meta = { localKey = tabKey .. "-search", class = "mls-search", tooltip ="Show only lines whose name contains this text. Search several terms using commas, e.g. \"Line 1, Line 2\"." },
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

-- The kind and search filter as a test on a line's name and kind. The
-- search terms are split once, not per row.
local function matcher(filter : MlsFilterState) : function(name : string, kind : string) : boolean
	local terms = searchTerms(filter.search)
	return function(name : string, kind : string) : boolean
		if filter.kind ~= "all" and kind ~= filter.kind then return false end
		if #terms == 0 then return true end
		local lower = string.lower(name)
		for _, term in ipairs(terms) do
			if string.find(lower, term, 1, true) ~= nil then return true end
		end
		return false
	end
end

------------------------------------------------------------
-- SORTING
------------------------------------------------------------

-- The given rows in the chosen order (sorted in place). The name column
-- (no value function) sorts alphabetically; numbers tie-break by name, A to Z.
local function sortRows<R>(rows : {R}, columns : {MlsColumn<R>}, sort : MlsSortState, nameOf : function(R) : string) : {R}
	local col = columns[1]
	for _, candidate in ipairs(columns) do
		if candidate.key == sort.key then col = candidate end
	end
	local function byName(rowA : R, rowB : R) : boolean
		return string.lower(nameOf(rowA)) < string.lower(nameOf(rowB))
	end
	table.sort(rows, function(rowA : R, rowB : R) : boolean
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

-- A click on the sorted column reverses it; a click on another column
-- sorts by that, numbers largest first, the name A to Z.
local function nextSort(sort : MlsSortState, key : string) : MlsSortState
	if key == sort.key then
		return { key = key, ascending = not sort.ascending }
	end
	return { key = key, ascending = key == "name" }
end

------------------------------------------------------------
-- LIST AND TEXT
------------------------------------------------------------

-- The scrolling list box. It is always there, even with no rows (then it
-- holds `emptyMessage`), so the window keeps the same layout. The scroll
-- area stretches its content to the viewport width, so the rows sit in a
-- fixed-width box beside a spacer and keep their width at any text scale.
local function scrollList(tabKey : string, rowNodes : {TreeNodeId}, emptyMessage : string) : TreeNodeId
	local rows = rowNodes
	if #rows == 0 then rows = { text(emptyMessage, "font-scale-body") } end
	return builtin.ScrollArea{
		-- Keyed per tab, so a switch doesn't carry the scroll position over.
		meta = { localKey = tabKey .. "-list", class = "mls-lines-scrollarea" },
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

local function count(value : integer, singular : string, plural : string) : string
	return tostring(value) .. " " .. (value == 1 and singular or plural)
end

-- "3 cargo-only lines and 2 lines without vehicles not shown."; nil when
-- there is nothing to say.
local function footer(parts : {string}) : string
	if #parts == 0 then return nil end
	return table.concat(parts, " and ") .. " not shown."
end

local exports : MlsListTable = {
	num = num,
	iconNum = iconNum,
	colourButton = colourButton,
	lineName = lineName,
	headerRow = headerRow,
	filterRow = filterRow,
	matcher = matcher,
	sortRows = sortRows,
	nextSort = nextSort,
	scrollList = scrollList,
	footer = footer,
	count = count,
}
return exports
