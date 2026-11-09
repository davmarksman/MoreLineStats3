-- More Line Stats: the Cargo tab of the all-lines window (the window, the
-- tab strip and the Passengers tab are in lines_list_gui). One row per line
-- with cargo capacity; a mixed line is on both tabs. The rows come from
-- linesHelper.collectCargo in the window's event handlers; nothing here
-- reads the engine. A function that builds nodes, not a recipe: the sort
-- and filter live in the window's state, so they survive a tab switch.
-- Types in tealdef/mls_def.d.tl (MlsCargoLinesGui).

local gui_react_util     = ug_require "::/gui/main/gui_react_util.tl" as GuiReactUtil

local LUA_UTILS : string = "bottle_more_line_stats::/scripts/lua_utils.script.tl"
local FORMATTING : string = "bottle_more_line_stats::/gui/formatting.script.tl"
local WIDGETS : string = "bottle_more_line_stats::/gui/widgets.script.tl"
local LIST_TABLE : string = "bottle_more_line_stats::/gui/list_table.script.tl"
local CARGO_GUI : string = "bottle_more_line_stats::/gui/cargo_gui.script.tl"
local luaUtils = require(LUA_UTILS) as MlsLuaUtils
local fmt = require(FORMATTING) as MlsFormatting
local widgets = require(WIDGETS) as MlsWidgets
local listTable = require(LIST_TABLE) as MlsListTable
local cargoGui = require(CARGO_GUI) as MlsCargoGui

local text, sectionTitle = widgets.text, widgets.sectionTitle
local num, iconNum = listTable.num, listTable.iconNum

-- Columns: colour, line, cargo types, load/capacity, Utilization (Load %), unhappy, rate,
-- vehicles, journey, length, speed, frequency, balance. Same row width as
-- the Passengers tab (mls.css.lua); weights are relative.
local COLUMN_WEIGHTS : {number} = { 0.8, 6.85, 2.6, 2.5, 2.6, 2.4, 2.2, 2, 2.5, 2.5, 2.5, 2, 3.15 }

local ICON_UNHAPPY : string = "::/gui/main/icons/symbol_emote_sad_colored.tga"

-- Carrier filter buttons: one per vehicle kind a cargo line can have, with
-- the game's own filter names (statistic_lines.tl: trucks are road lines).
-- A function, not a table: the texts go through _() at use time, never at load.
local function kindFilters() : {MlsKindFilter}
	return {
		{ kind = "truck", iconPath = "::/gui/hud/icons/vehicle_truck.tga", tooltip = _("Show Road Lines") },
		{ kind = "tram", iconPath = "::/gui/hud/icons/vehicle_tram.tga", tooltip = _("Show Tram Lines") },
		{ kind = "train", iconPath = "::/gui/hud/icons/vehicle_train.tga", tooltip = _("Show Train Lines") },
		{ kind = "ship", iconPath = "::/gui/hud/icons/vehicle_ship.tga", tooltip = _("Show Ship Lines") },
		{ kind = "aircraft", iconPath = "::/gui/hud/icons/vehicle_airplane.tga", tooltip = _("Show Air Lines") },
	}
end

-- Average speed as a number for sorting: length over driving time, the
-- total time without one; 0 if unknown.
local function speedOf(row : MlsCargoLineRow) : number
	local seconds = row.journey.drive > 0 and row.journey.drive or row.journey.time
	if row.journey.distance <= 0 or seconds <= 0 then return 0 end
	return row.journey.distance / seconds
end

local function nameOf(row : MlsCargoLineRow) : string
	return row.name
end

-- One entry per header cell after the colour swatch, in column order. A
-- function, not a table: the labels the game translates itself (its Lines
-- statistics headers; "Load" is its context key) go through _() at use
-- time, never at load. "Freq." stays short: the column is too narrow for
-- the game's "Frequency".
local function cargoColumns() : {MlsColumn<MlsCargoLineRow>}
	return {
		{ key = "name", label = _("Name"), tooltip = "Open Cargo Details" },
		{ key = "types", label = _("Cargo"), tooltip = "Cargo: the types the line's vehicles carry, largest capacity first.",
			value = function(row : MlsCargoLineRow) : number return #row.types end },
		{ key = "load", label = pGetText("noun", "Load"), tooltip = "Load / capacity: cargo in the line's vehicles now, and the line's cargo capacity, all types.",
			value = function(row : MlsCargoLineRow) : number return row.onBoard end },
		{ key = "loadPct", label = _("Utilization"), tooltip = _("Utilization"),
			value = function(row : MlsCargoLineRow) : number return row.loadPct end },
		{ key = "unhappy", iconPath = ICON_UNHAPPY, tooltip = "Delayed Deliveries: cargo on board that the game counts as delayed.",
			value = function(row : MlsCargoLineRow) : number return row.unhappy end },
		{ key = "rate", label = _("Rate"), tooltip = "Rate: the game's own line rate.",
			value = function(row : MlsCargoLineRow) : number return row.rate end },
		{ key = "vehicles", iconPath = widgets.ICON_VEHICLES, tooltip = "Vehicles: the number of vehicles on the line.",
			value = function(row : MlsCargoLineRow) : number return row.numVehicles end },
		{ key = "journey", label = "Journey", tooltip = "Journey: one full round trip, including time at stations.\nIncludes estimated legs, marked ~.",
			value = function(row : MlsCargoLineRow) : number return row.journey.time end },
		{ key = "length", label = _("Length"), tooltip = "Length: line length as the crow flies.",
			value = function(row : MlsCargoLineRow) : number return row.journey.distance end },
		{ key = "speed", label = _("Speed"), tooltip = "Average speed", value = speedOf },
		{ key = "frequency", label = "Freq.",
			value = function(row : MlsCargoLineRow) : number return row.frequency end },
		{ key = "balance", label = _("Balance"),
			value = function(row : MlsCargoLineRow) : number return row.balance end },
	}
end

local function lineRow(row : MlsCargoLineRow) : TreeNodeId
	local frequency = row.frequency > 0 and luaUtils.getTimeStr(row.frequency) or "?"
	return widgets.tableRow(COLUMN_WEIGHTS, {
		listTable.colourButton(row.lineId),
		listTable.lineName(row.lineId, function(entity : Engine.Entity) cargoGui.openCargoDetails(entity) end, "Open Cargo Details"),
		widgets.cargoTypesCell(row.types, "Carried:", "No cargo capacity"),
		num(tostring(row.onBoard) .. "/" .. tostring(row.capacity)),
		num(row.capacity > 0 and (tostring(row.loadPct) .. "%") or "?"),
		iconNum(ICON_UNHAPPY, tostring(row.unhappy)),
		num(tostring(row.rate)),
		num(tostring(row.numVehicles)),
		num(fmt.legTimeStr(row.journey), fmt.journeyTooltip(row.journey)),
		num(fmt.distanceStr(row.journey.distance)),
		num(fmt.speedStr(row.journey)),
		num(frequency),
		listTable.money(row.balance),
	}, "mls-compact-row")
end

local function body(linesTable : MlsCargoLinesTable, view : MlsListView) : {TreeNodeId}
	local children : {TreeNodeId} = {}
	if linesTable == nil then
		children[1] = text(_("Loading..."), "font-scale-body")
		return children
	end
	if linesTable.error ~= nil then
		children[1] = sectionTitle("Could not read: " .. tostring(linesTable.error), nil, view.refresh)
		return children
	end

	local total = #linesTable.rows
	local matches = listTable.matcher(view.filter)
	local shown : {MlsCargoLineRow} = {}
	for _, row in ipairs(linesTable.rows) do
		if matches(row.name, row.kind) then shown[#shown + 1] = row end
	end
	-- "Lines: 12" or "Lines: 5 of 12", as on the Passengers tab.
	local title = _("Lines") .. ": " .. tostring(total)
	if #shown ~= total then title = _("Lines") .. ": " .. tostring(#shown) .. " of " .. tostring(total) end
	local titleTooltip = "Figures as they were when the list was computed; press Refresh for current ones."
	if total == 0 then
		children[1] = sectionTitle(title, titleTooltip, view.refresh)
		children[2] = text("No lines with vehicles.", "font-scale-body")
	else
		-- Title, filters, search and Refresh share one row (more room for the list).
		local columns = cargoColumns()
		children[1] = listTable.filterRow("cargo", title, titleTooltip, "All lines", kindFilters(),
			view.filter, view.onKind, view.onSearch, view.refresh)
		children[2] = listTable.headerRow(COLUMN_WEIGHTS, columns, view.sort, view.onSort)
		local rows : {TreeNodeId} = {}
		for _, row in ipairs(listTable.sortRows(shown, columns, view.sort, nameOf)) do
			rows[#rows + 1] = lineRow(row)
		end
		children[3] = listTable.scrollList("cargo", rows, "No line matches the filter.")
	end
	-- The window has a fixed height; the spacer takes the leftover room so
	-- the parts above pack together and the footer stays at the bottom.
	children[#children + 1] = gui_react_util.makeVerticalSpacer()
	local parts : {string} = {}
	if linesTable.otherLines > 0 then
		parts[#parts + 1] = tostring(linesTable.otherLines) .. " without vehicles"
	end
	local note = listTable.footer(parts)
	if note ~= nil then children[#children + 1] = text(note, "font-scale-annotation") end
	return children
end

local exports : MlsCargoLinesGui = {
	body = body,
}
return exports
