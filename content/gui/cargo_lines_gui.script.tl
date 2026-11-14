-- More Line Stats: the Cargo tab of the all-lines window (the window, the
-- tab strip and the Passengers tab are in lines_list_gui). One row per line
-- with cargo capacity; a mixed line is on both tabs. The rows come from
-- linesHelper.collectCargo in the window's event handlers; nothing here
-- reads the engine. A function that builds nodes, not a recipe: the sort
-- and filter live in the window's state, so they survive a tab switch.
-- Types in tealdef/mls_def.d.tl (MlsCargoLinesGui).

local gui_react_util     = ug_require "::/gui/main/gui_react_util.tl" as GuiReactUtil
local lang_util          = ug_require "::/scripts/lang_util.tl" as LangUtil

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

-- Columns: colour, line, cargo types, load/capacity, Utilization (Load %),
-- waiting, unhappy, rate, vehicles, journey, length, speed, frequency,
-- balance. Same row width as the Passengers tab (mls.css.lua); weights are
-- relative. Waiting (2026-11-11) took 1.2 from Name and 0.5 each from
-- Length and Speed, so the others keep their width.
-- Speed (2026-11-13) took 0.3 from Vehicles: "km/h" was cropped.
local COLUMN_WEIGHTS : {number} = { 0.8, 5.65, 2.6, 2.5, 2.6, 2.2, 2.4, 2.2, 1.7, 2.5, 2, 2.3, 2, 3.15 }

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
		{ key = "name", label = _("Name"), tooltip = _("Open Cargo Details") },
		{ key = "types", label = _("Cargo"), tooltip = fmt.loadsTooltip(),
			value = function(row : MlsCargoLineRow) : number return #row.types end },
		{ key = "load", label = pGetText("noun", "Load"), tooltip = fmt.loadCapacityTooltip(),
			value = function(row : MlsCargoLineRow) : number return row.onBoard end },
		{ key = "loadPct", label = _("Utilization"), tooltip = _("Utilization"),
			value = function(row : MlsCargoLineRow) : number return row.loadPct end },
		{ key = "waiting", label = _("Waiting"),
			tooltip = fmt.cargoWaitingTooltip(),
			value = function(row : MlsCargoLineRow) : number return row.waiting end },
		{ key = "unhappy", iconPath = ICON_UNHAPPY, tooltip = fmt.delayedTooltip(),
			value = function(row : MlsCargoLineRow) : number return row.unhappy end },
		{ key = "rate", label = _("Rate"), tooltip = _("Rate: the game's own line rate."),
			value = function(row : MlsCargoLineRow) : number return row.rate end },
		{ key = "vehicles", iconPath = widgets.ICON_VEHICLES, tooltip = _("Vehicles: the number of vehicles on the line."),
			value = function(row : MlsCargoLineRow) : number return row.numVehicles end },
		{ key = "journey", label = _("Journey"),
			tooltip = _("Journey: one full round trip, including time at stations.") .. "\n" .. _("Includes estimated legs, marked ~."),
			value = function(row : MlsCargoLineRow) : number return row.journey.time end },
		{ key = "length", label = _("Length"), tooltip = _("Length: line length as the crow flies."),
			value = function(row : MlsCargoLineRow) : number return row.journey.distance end },
		{ key = "speed", label = _("Speed"), tooltip = _("Average speed"), value = speedOf },
		{ key = "frequency", label = _("Freq."),
			value = function(row : MlsCargoLineRow) : number return row.frequency end },
		{ key = "balance", label = _("Balance"),
			value = function(row : MlsCargoLineRow) : number return row.balance end },
	}
end

local function lineRow(row : MlsCargoLineRow, waitingTip : string) : TreeNodeId
	local frequency = row.frequency > 0 and luaUtils.getTimeStr(row.frequency) or "?"
	-- Each row stays with its line across a sort or filter; the tab is in
	-- the key because a mixed line has a row in both tabs.
	local key = "cargo-row-" .. tostring(row.lineId)
	return widgets.tableRow(COLUMN_WEIGHTS, {
		listTable.colourButton(row.lineId),
		listTable.lineName(row.lineId, function(entity : Engine.Entity) cargoGui.openCargoDetails(entity) end, _("Open Cargo Details")),
		widgets.cargoTypesCell(row.types, _("Cargo") .. ":", _("No stop is set to load cargo.")),
		num(tostring(row.onBoard) .. "/" .. tostring(row.capacity)),
		num(row.capacity > 0 and (tostring(row.loadPct) .. "%") or "?"),
		-- "-" when no stop loads from an industry or warehouse; the tooltip
		-- splits it by stop (station names and numbers, nothing to translate).
		-- Always a tooltip (the column's own without a split): a cell with
		-- one is a different kind of node from a cell without.
		num(row.waiting >= 0 and tostring(row.waiting) or "-", row.waitingByStop ~= "" and row.waitingByStop or waitingTip),
		iconNum(ICON_UNHAPPY, tostring(row.unhappy)),
		num(tostring(row.rate)),
		num(tostring(row.numVehicles)),
		num(fmt.legTimeStr(row.journey), fmt.journeyTooltip(row.journey)),
		num(fmt.distanceStr(row.journey.distance)),
		num(fmt.speedStr(row.journey)),
		num(frequency),
		listTable.money(row.balance, nil, key .. "-balance"),
	}, "mls-compact-row", key)
end

local function body(linesTable : MlsCargoLinesTable, view : MlsListView) : {TreeNodeId}
	local children : {TreeNodeId} = {}
	if linesTable == nil then
		children[1] = text(_("Loading..."), "font-scale-body")
		return children
	end
	if linesTable.error ~= nil then
		children[1] = sectionTitle(fmt.couldNotRead(linesTable.error), nil, view.refresh)
		return children
	end

	local total = #linesTable.rows
	local matches = listTable.matcher(view.filter)
	local shown : {MlsCargoLineRow} = {}
	for _, row in ipairs(linesTable.rows) do
		if matches(row.name, row.kind) then shown[#shown + 1] = row end
	end
	-- "Lines: 12" or "Lines: 5 of 12", as on the Passengers tab.
	local count = tostring(total)
	if #shown ~= total then
		count = lang_util.format(_("{shown} of {total}"), { shown = tostring(#shown), total = tostring(total) })
	end
	local title = _("Lines") .. ": " .. count
	local titleTooltip = _("Figures as they were when the list was computed; press Refresh for current ones.")
	if total == 0 then
		children[1] = sectionTitle(title, titleTooltip, view.refresh)
		children[2] = text(_("No lines with vehicles."), "font-scale-body")
	else
		-- Title, filters, search and Refresh share one row (more room for the list).
		local columns = cargoColumns()
		children[1] = listTable.filterRow("cargo", title, titleTooltip, _("All lines"), kindFilters(),
			view.filter, view.onKind, view.onSearch, view.refresh)
		children[2] = listTable.headerRow(COLUMN_WEIGHTS, columns, view.sort, view.onSort)
		local rows : {TreeNodeId} = {}
		local waitingTip = fmt.cargoWaitingTooltip()
		for _, row in ipairs(listTable.sortRows(shown, columns, view.sort, nameOf)) do
			rows[#rows + 1] = lineRow(row, waitingTip)
		end
		children[3] = listTable.scrollList("cargo", rows, _("No line matches the filter."))
	end
	-- The window has a fixed height; the spacer takes the leftover room so
	-- the parts above pack together.
	children[#children + 1] = gui_react_util.makeVerticalSpacer()
	return children
end

local exports : MlsCargoLinesGui = {
	body = body,
}
return exports
