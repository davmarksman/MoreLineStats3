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

local text, tableRow, icon, iconCell = widgets.text, widgets.tableRow, widgets.icon, widgets.iconCell
local locateButton, stopLocateButton = widgets.locateButton, widgets.stopLocateButton
local styledColumn, sectionTitle, vehiclesCell = widgets.styledColumn, widgets.sectionTitle, widgets.vehiclesCell
local legTimeStr, legTooltip, distanceStr, speedStr, journeyTooltip =
	fmt.legTimeStr, fmt.legTooltip, fmt.distanceStr, fmt.speedStr, fmt.journeyTooltip

local REFRESH_SECONDS : number = 10.0

-- Column weights, shared by header and rows so the columns line up.
-- Stop list: #+pin, Stop, Loads, On section, Vehicles, Distance, Speed, To next.
local STOP_COLUMN_WEIGHTS : {number} = { 2, 6, 3, 2, 2, 3, 3, 2 }
-- Vehicles on the selected leg: pin, name, load, where.
local VEHICLE_COLUMN_WEIGHTS : {number} = { 1, 5, 3, 3 }
-- Cargo on Line: icon, name, load/capacity, unhappy.
local TYPE_COLUMN_WEIGHTS : {number} = { 1, 5, 3, 2 }
-- Summary: Load/capacity, Rate, Unhappy, Length, Frequency, Journey.
local SUMMARY_COLUMN_WEIGHTS : {number} = { 3, 2, 2, 2, 2, 2 }

-- At most this many icons in a Loads cell; the rest is "+n" (all names in
-- the tooltip). Two 20 px icons plus "+n" fit the column's ~88 px.
local MAX_LOAD_ICONS : integer = 2

-- Base-game icons. The game resolves the "@2x" files itself.
-- Generic cargo (the game's "mixed cargo" icon) for totals over all types,
-- and the line window's own Rate icon.
local ICON_CARGO : string = "::/cargos/icons/cargo_mixed.tga"
local ICON_RATE : string = "::/gui/entity_window/icons/symbol_cargo.tga"
local ICON_UNHAPPY : string = "::/gui/main/icons/symbol_emote_sad_colored.tga"
local ICON_DISTANCE : string = "::/gui/game_bar/icons/statistics_line_26.tga"
local ICON_SPEED : string = "::/gui/entity_window/icons/symbol_speed.tga"
local ICON_TIME : string = "::/gui/main/icons/calendar_speed.tga"
local ICON_FREQUENCY : string = "::/gui/entity_window/icons/symbol_stop_watch.tga"

local MORE_TOOLTIP : string = "Show, for the selected stop, the vehicles on the way to the next stop, and the cargo types this line carries."
local LESS_TOOLTIP : string = "Hide the vehicles and cargo-types panel to make the window smaller."

------------------------------------------------------------
-- TYPES
------------------------------------------------------------

local record WindowParams
	lineId : Engine.Entity
	title : string
	onClose : function()
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

-- A cargo type's icon path, with a stand-in when the type has none (a load
-- flag for an id the cargo rep doesn't know, or a failed rep read).
local function iconPathOf(cargoType : MlsCargoType) : string
	if cargoType == nil or cargoType.icon == nil or cargoType.icon == "" then return ICON_CARGO end
	return cargoType.icon
end

-- A cargo type's icon at 20 px, no right gravity (several sit side by side).
local function cargoIcon(cargoType : MlsCargoType, tooltip : string) : TreeNodeId
	return builtin.ImageView{
		meta = { class = "mls-cargo-icon", tooltip = tooltip },
		path = iconPathOf(cargoType),
		scaling = builtin.type.ImageViewScaling.AutoFit,
	}
end

-- Shown instead of stats for lines that have none; nil for a cargo line.
local function messageFor(stats : MlsCargoStats) : string
	if stats == nil then return "Loading..." end
	if stats.kind == "nocargo" then return "This line carries no cargo. Use the Passengers button for passengers." end
	if stats.kind == "empty" then return "This line has no vehicles." end
	if stats.kind == "missing" then return "This line no longer exists." end
	if stats.kind == "error" then return "Could not read this line: " .. tostring(stats.error) end
	return nil
end

------------------------------------------------------------
-- STOP LIST (left)
------------------------------------------------------------

-- The Loads cell: the icons of the types this stop is configured to load,
-- up to MAX_LOAD_ICONS, then "+n". A type no vehicle of the line carries is
-- still shown and called out in the tooltip. A dash when nothing is loaded.
local function loadsCell(loads : {MlsCargoType}) : TreeNodeId
	if #loads == 0 then
		return text("-", "font-scale-body, mls-time", "No cargo is loaded at this stop.")
	end
	local names : {string} = {}
	for _, cargoType in ipairs(loads) do
		names[#names + 1] = cargoType.name .. (cargoType.capacity > 0 and "" or " (no vehicle of this line carries it)")
	end
	local tooltip = "Loaded here:\n" .. table.concat(names, "\n")
	local children : {TreeNodeId} = {}
	for i, cargoType in ipairs(loads) do
		if i > MAX_LOAD_ICONS then
			children[#children + 1] = text("+" .. tostring(#loads - MAX_LOAD_ICONS), "font-scale-body", tooltip)
			break
		end
		children[#children + 1] = cargoIcon(cargoType, tooltip)
	end
	return builtin.Component{
		meta = { class = "mls-cargo-loads", tooltip = tooltip },
		layout = builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = children,
		},
	}
end

local function stopList(stats : MlsCargoStats, selected : integer, onSelect : function(integer)) : TreeNodeId
	local rows : {TreeNodeId} = {}
	local count = #stats.stops
	-- The legs carrying the most cargo are highlighted; ties are all highlighted.
	local maxLoad = 0
	for i = 1, count do maxLoad = math.max(maxLoad, stats.legLoad[i] or 0) end
	for i = 1, count do
		local leg = stats.legs[i] or { time = 0, drive = 0, estimated = false, distance = 0 }
		local name = stats.stopNames[i] or "?"
		local onLeg = stats.legLoad[i] or 0
		local vehicles = stats.legVehicles[i] or 0
		local atStation = stats.legAtStation[i] or 0
		local kind = widgets.kindOnLeg(stats.vehicles, i)

		local busiest = onLeg > 0 and onLeg == maxLoad
		local loadTip = "Cargo on the vehicles from this stop to the next one (vehicles loading here included)."
		if stats.legLoadByType[i] ~= nil and stats.legLoadByType[i] ~= "" then
			loadTip = loadTip .. "\n" .. stats.legLoadByType[i]
		end
		if busiest then loadTip = loadTip .. "\nThe fullest section of this line." end

		local distanceTip = leg.distance > 0
			and "Distance to the next stop as the crow flies."
			or "No position known for one of the two stations."
		local speedTip = "Crow-flies distance over "
			.. (leg.drive > 0 and "the driving time (time at stations left out)." or "the whole leg time (no driving time known).")

		rows[i] = stopRow({
			stopLocateButton(i, stats.stops[i]),
			text(name, "font-scale-body"),
			loadsCell(stats.stopLoads[i] or {}),
			text(tostring(onLeg), busiest and "font-scale-body, mls-time, mls-busiest" or "font-scale-body, mls-time", loadTip),
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
-- and the More/Less toggle, then one row of icon-and-label cells. Totals
-- over all types carry the generic cargo icon (a line carrying grain and
-- coal showed only the grain icon once, which misled).
local function summaryBlock(stats : MlsCargoStats, lineWindow : TreeNodeId, toggle : TreeNodeId) : TreeNodeId
	local frequency = stats.frequency > 0 and luaUtils.getTimeStr(stats.frequency) or "?"
	local perType : {string} = {}
	for _, cargoType in ipairs(stats.types) do
		perType[#perType + 1] = cargoType.name .. ": " .. tostring(cargoType.onBoard) .. "/" .. tostring(cargoType.capacity)
	end
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
			iconCell(ICON_CARGO, tostring(stats.onBoard) .. "/" .. tostring(stats.capacity),
				"Load / capacity: cargo in this line's vehicles now, and the line's cargo capacity, all types together.\n"
				.. table.concat(perType, "\n")),
			iconCell(ICON_RATE, tostring(stats.rate),
				"Rate: the game's own line rate, as shown in the line window."),
			iconCell(ICON_UNHAPPY, tostring(stats.unhappy),
				"Unhappy: cargo on board that the game counts as badly served (its own measure, as in the line window)."),
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
-- VEHICLES ON THE SELECTED LEG (right, top)
------------------------------------------------------------

-- "<pin> <name>  12/96  <station or arrow icon>". The pin follows the vehicle.
local function vehicleRow(vehicle : MlsVehicle) : TreeNodeId
	return tableRow(VEHICLE_COLUMN_WEIGHTS, {
		locateButton(vehicle.id),
		text(vehicle.name, "font-scale-body"),
		text(tostring(vehicle.load) .. "/" .. tostring(vehicle.capacity), "font-scale-body, mls-time", "Cargo on board / capacity."),
		widgets.whereIcon(vehicle.atStation),
	}, "mls-compact-row")
end

-- The vehicles between the selected stop and the next one. Reads the same
-- 10 s data as the stop list, so no timer of its own.
local function vehiclesPanel(stats : MlsCargoStats, selected : integer) : TreeNodeId
	local count = #stats.stops
	local name = stats.stopNames[selected] or "?"
	local nextName = stats.stopNames[(selected % count) + 1] or "?"
	local rows : {TreeNodeId} = {}
	for _, vehicle in ipairs(stats.vehicles) do
		if vehicle.leg == selected then rows[#rows + 1] = vehicleRow(vehicle) end
	end
	local children : {TreeNodeId} = {
		sectionTitle("Vehicles on Section"),
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
-- CARGO ON LINE (right, below the vehicles)
------------------------------------------------------------

local function typeRow(cargoType : MlsCargoType) : TreeNodeId
	local loadTip = "On board / capacity for this type."
	local unhappyTip = "Cargo of this type on board that the game counts as badly served."
	return tableRow(TYPE_COLUMN_WEIGHTS, {
		cargoIcon(cargoType, cargoType.name),
		text(cargoType.name, "font-scale-body", cargoType.name),
		text(tostring(cargoType.onBoard) .. "/" .. tostring(cargoType.capacity), "font-scale-body, mls-time", loadTip),
		text(tostring(cargoType.unhappy), cargoType.unhappy > 0 and "font-scale-body, mls-time, mls-unhappy" or "font-scale-body, mls-time", unhappyTip),
	}, "mls-compact-row")
end

-- One row per cargo type the line carries, largest capacity first. Top of
-- the right column, so it carries the Hide button for the whole column.
local function cargoTypesPanel(stats : MlsCargoStats, onHide : function()) : TreeNodeId
	local hide = button_react_util.makeTextButton("primary", "Hide", onHide, LESS_TOOLTIP)
	local rows : {TreeNodeId} = {
		tableRow(TYPE_COLUMN_WEIGHTS, {
			text("", "font-scale-annotation"),
			text("Cargo", "font-scale-annotation"),
			text("Load", "font-scale-annotation, mls-time", "On board / capacity for this type."),
			icon(ICON_UNHAPPY, "Unhappy: cargo of this type on board that the game counts as badly served."),
		}),
	}
	for _, cargoType in ipairs(stats.types) do rows[#rows + 1] = typeRow(cargoType) end
	return builtin.Component{
		meta = { class = "mls-cargo-types" },
		layout = builtin.BoxLayout{
			orientation = builtin.type.Orientation.Vertical,
			children = {
				sectionTitle("Cargo on Line", "The cargo types this line's vehicles are set up to carry, with the load of each.", hide),
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
			return cargoStatsHelper.collect(lineId)
		end, REFRESH_SECONDS)
		local stats = statsState:old()

		-- Selected stop, 1-based; stop 1 on open.
		local selState = react.useState(1) as ReactStateT<integer>
		-- The right column is shown until the user hides it.
		local showState = react.useState(true) as ReactStateT<boolean>

		local message = messageFor(stats)
		if message ~= nil then
			return widgets.windowBody("mls-details-narrow", { text(message, "font-scale-body") })
		end

		-- Clamp in case the line lost stops since the selection was made.
		local count = #stats.stops
		local selected : integer = selState:old()
		if selected == nil or selected < 1 or selected > count then selected = 1 end

		local shown : boolean = showState:old() ~= false
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
				text("Loads", "font-scale-annotation, mls-cargo-loads", "Loads: the cargo types this stop is set to load onto the line."),
				icon(ICON_CARGO, "On section: cargo on the vehicles between this stop and the next one now "
					.. "(vehicles loading at this stop included). The fullest section is highlighted."),
				icon(widgets.ICON_VEHICLES, "Vehicles standing at this stop or on the way from it to the next one."),
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

		local right = styledColumn("mls-right", {
			cargoTypesPanel(stats, function() showState:set(false) end),
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
		}
		-- Centred by the stylesheet through this class (see line_gui).
		(win as {string : any}).meta = { class = "mls-details-window" }
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
		title = "Cargo Details: " .. name,
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
