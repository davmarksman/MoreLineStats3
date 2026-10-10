-- More Line Stats: the line-window card and the Line Details windows.
--
-- The card (registered by line_eow.res.lua) has a Show button that opens a
-- Line Details window for its line; each line gets its own window, keyed by
-- line id, so several can be open side by side. Line Details is master-detail:
-- the summary and stop list on the left, the competing lines for the selected
-- stop on the right.
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
local lineStatsHelper = require(LINE_STATS_HELPER) as MlsLineStatsHelper
local stationsHelper = require(STATIONS_HELPER) as MlsStationsHelper
local luaUtils = require(LUA_UTILS) as MlsLuaUtils
local fmt = require(FORMATTING) as MlsFormatting

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
local ICON_VEHICLES : string = "::/gui/entity_window/icons/relation_vehicle_train_bus.tga"
local ICON_LOCATE : string = "::/gui/line_vehicle_mgmt/icons/symbol_locate_20.tga"
-- Vehicle rows: standing at the station / on the way to the next one.
local ICON_AT_STATION : string = "::/gui/entity_window/icons/building_stations.tga"
local ICON_EN_ROUTE : string = "::/gui/construction/build_control/symbol_slope_0_20.tga"
-- One icon per vehicle kind (MlsVehicle.kind), for a section with a single
-- vehicle. Kinds not listed fall back to ICON_VEHICLES.
local ICON_BY_KIND : {string : string} = {
	train = "::/gui/hud/icons/vehicle_train.tga",
	bus = "::/gui/hud/icons/vehicle_bus.tga",
	tram = "::/gui/hud/icons/vehicle_tram.tga",
	truck = "::/gui/hud/icons/vehicle_truck.tga",
	ship = "::/gui/hud/icons/vehicle_ship.tga",
	aircraft = "::/gui/hud/icons/vehicle_airplane.tga",
	helicopter = "::/gui/hud/icons/vehicle_helicopter.tga",
}

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

-- Lines with an open Line Details window, so Show can bring it to the front.
local openWindows : {Engine.Entity : boolean} = {}

-- Window keys share one container with the base game. A pinned line window
-- is keyed by the bare entity id, and a duplicate key crashes the UI.
local function windowKey(lineId : Engine.Entity) : string
	return "mls_lineDetails_" .. tostring(lineId)
end

-- Forward declaration: defined after the window recipes it needs, used by
-- the competing panel above them.
local openLineDetails : function(lineId : Engine.Entity)

------------------------------------------------------------
-- WIDGET HELPERS
------------------------------------------------------------
-- UI tree rules, each learned from a crash:
--   * List children and TableLayout cells must be widgets or Components,
--     never bare layouts (wrap a layout in builtin.Component{ layout = ... }).
--   * A recipe must return a layout.
--   * Only Components and widgets take meta.class; a class on a layout is
--     ignored.

local function text(str : string, class : string, tooltip? : string) : TreeNodeId
	return builtin.TextView{ meta = { class = class, tooltip = tooltip }, text = str }
end

local function tableRow(weights : {number}, cells : {TreeNodeId}, class? : string) : TreeNodeId
	return builtin.Component{
		meta = { class = class },
		layout = builtin.TableLayout{
			columnWeights = weights,
			rows = { builtin.Row{ cells = cells } },
		},
	}
end

local function stopRow(cells : {TreeNodeId}) : TreeNodeId
	return tableRow(STOP_COLUMN_WEIGHTS, cells)
end

-- A 20 px icon (mls-icon in mls.css.lua) with a tooltip.
local function icon(path : string, tooltip : string) : TreeNodeId
	return builtin.ImageView{
		meta = { class = "mls-icon", tooltip = tooltip },
		path = path,
		scaling = builtin.type.ImageViewScaling.AutoFit,
	}
end

-- Moves the camera to a station group or a vehicle. Runs in an onClick
-- handler, on the GUI thread, so api.gui is allowed.
local function locate(entity : Engine.Entity)
	if entity ~= nil and api.engine.entityExists(entity) then
		api.gui.camera.followEntity(entity, true)
	end
end

local function locateButton(entity : Engine.Entity, name : string) : TreeNodeId
	return builtin.Button{
		meta = { class = "mls-locate", tooltip = "Locate " .. name },
		content = builtin.ImageView{
			meta = { class = "mls-pin-icon" },
			path = ICON_LOCATE,
			scaling = builtin.type.ImageViewScaling.AutoFit,
		},
		onClick = function() locate(entity) end,
	}
end

-- Stop number and locate pin as one button, so they share a column.
local function stopLocateButton(index : integer, stationGroup : Engine.Entity, name : string) : TreeNodeId
	return button_react_util.makeIconTextButton(
		"mls-stop-locate",
		ICON_LOCATE,
		tostring(index),
		function() locate(stationGroup) end,
		"Locate " .. name)
end

-- "<pin> To Alford Station", with an optional node pushed to the right end.
local function locateHeading(stationGroup : Engine.Entity, label : string, class : string, tooltip : string, trailing? : TreeNodeId) : TreeNodeId
	local children : {TreeNodeId} = {
		locateButton(stationGroup, label),
		text(label, class, tooltip),
	}
	if trailing ~= nil then
		children[#children + 1] = gui_react_util.makeHorizontalSpacer()
		children[#children + 1] = trailing
	end
	return builtin.Component{
		layout = builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = children,
		},
	}
end

-- A vertical block that takes a style class (for widths and margins).
local function styledColumn(class : string, children : {TreeNodeId}) : TreeNodeId
	return builtin.Component{
		meta = { class = class },
		layout = builtin.BoxLayout{
			orientation = builtin.type.Orientation.Vertical,
			children = children,
		},
	}
end

-- Shown instead of stats for lines that have none; nil for a passenger line.
local function messageFor(stats : MlsLineStats) : string
	if stats == nil then return "Loading..." end
	if stats.kind == "cargo" then return "Cargo line statistics are not available yet." end
	if stats.kind == "empty" then return "This line has no vehicles." end
	if stats.kind == "missing" then return "This line no longer exists." end
	if stats.kind == "error" then return "Could not read this line: " .. tostring(stats.error) end
	return nil
end

------------------------------------------------------------
-- STOP LIST (left)
------------------------------------------------------------

-- The Vehicles cell, one icon: the station icon when every vehicle on the
-- section stands at this stop; otherwise one vehicle's own kind, or the
-- column's train-and-bus icon for several (including a mix of at-stop and
-- en-route); a dash when the section is empty. The counts are in the tooltip.
local function vehiclesCell(count : integer, atStation : integer, kind : string) : TreeNodeId
	if count == 0 then
		return text("-", "font-scale-body, mls-time", "No vehicles on section")
	end
	local tooltip : string
	if atStation == count then
		tooltip = tostring(count) .. (count == 1 and " vehicle" or " vehicles") .. " at stop"
	else
		tooltip = tostring(count) .. (count == 1 and " vehicle" or " vehicles") .. " on section"
		if atStation > 0 then tooltip = tooltip .. " (" .. tostring(atStation) .. " at stop)" end
	end
	local path = ICON_VEHICLES
	if atStation == count then
		path = ICON_AT_STATION
	elseif count == 1 then
		path = ICON_BY_KIND[kind] or ICON_VEHICLES
	end
	return icon(path, tooltip)
end

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
		local nextName = stats.stopNames[(i % count) + 1] or "?"

		local unhappyTip = tostring(unhappy) .. " of the " .. tostring(waiting) .. " passengers waiting at " .. name
			.. " are unhappy with the wait (the game's own measure, as in the station window)."

		local busiest = demand > 0 and demand == maxDemand
		local demandTip = tostring(demand) .. " passengers travel between " .. name .. " and " .. nextName
			.. " on this line now (waiting + on board)."
		if busiest then demandTip = demandTip .. "\nThe busiest leg of this line." end

		local atStation = stats.legAtStation[i] or 0
		-- The kind of the one vehicle on this section (only used when there is one).
		local kind = "other"
		for _, v in ipairs(stats.vehicles) do
			if v.leg == i then kind = v.kind break end
		end

		local distanceTip = leg.distance > 0
			and ("Distance from " .. name .. " to " .. nextName .. " as the crow flies: " .. distanceStr(leg.distance) .. ".")
			or "No position known for one of the two stations."
		local speedTip = "Average speed from " .. name .. " to " .. nextName .. ": the crow-flies distance over "
			.. (leg.drive > 0 and "the driving time (time at stations left out)." or "the whole leg time (no driving time known).")

		rows[i] = stopRow({
			stopLocateButton(i, stats.stops[i], name),
			text(name, "font-scale-body"),
			text(tostring(waiting), "font-scale-body, mls-time",
				tostring(waiting) .. " passengers waiting at " .. name .. " for this line."),
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

-- Summary above the stop list: a title row with the More/Less toggle, then
-- one row of the base game's icon-and-label cells (the Basics card look).
local function summaryBlock(stats : MlsLineStats, toggle : TreeNodeId) : TreeNodeId
	local function iconCell(path : string, value : string, tooltip : string) : TreeNodeId
		local p : any = { iconPath = path, label = value, tooltip = tooltip }
		return gui_react_util.IconLabelIndicator(p as GuiReactUtil.IconLabelIndicatorParams)
	end
	local frequency = stats.frequency > 0 and luaUtils.getTimeStr(stats.frequency) or "?"
	local rows : {TreeNodeId} = {
		builtin.Component{
			layout = builtin.BoxLayout{
				orientation = builtin.type.Orientation.Horizontal,
				children = {
					text("Summary", "font-scale-body", "Figures for the whole line, refreshed every 10 seconds."),
					gui_react_util.makeHorizontalSpacer(),
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

-- A section title with an optional button at the right end (the Summary row
-- on the left uses the same shape).
local function sectionTitle(label : string, tooltip? : string, trailing? : TreeNodeId) : TreeNodeId
	local children : {TreeNodeId} = { text(label, "font-scale-body", tooltip) }
	if trailing ~= nil then
		children[2] = gui_react_util.makeHorizontalSpacer()
		children[3] = trailing
	end
	return builtin.Component{
		meta = { class = "mls-section-title" },
		layout = builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = children,
		},
	}
end

-- "<pin> <name>  12/96  <station or arrow icon>". The pin follows the vehicle.
local function vehicleRow(v : MlsVehicle) : TreeNodeId
	local loadTip = tostring(v.load) .. " of " .. tostring(v.capacity) .. " seats taken on " .. v.name .. "."
	local whereTip = v.atStation and "At Station" or "En route"
	return tableRow(VEHICLE_COLUMN_WEIGHTS, {
		locateButton(v.id, v.name),
		text(v.name, "font-scale-body", "Locate " .. v.name .. " with the pin."),
		text(tostring(v.load) .. "/" .. tostring(v.capacity), "font-scale-body, mls-time", loadTip),
		icon(v.atStation and ICON_AT_STATION or ICON_EN_ROUTE, whereTip),
	}, "mls-competing-row")
end

-- The vehicles between the selected stop and the next one. Reads the same
-- 10 s data as the stop list, so no timer of its own. Not scrolled: a leg
-- holds a handful of vehicles. Carries the Hide button for the whole column.
local function vehiclesPanel(stats : MlsLineStats, selected : integer, onHide : function()) : TreeNodeId
	local count = #stats.stops
	local name = stats.stopNames[selected] or "?"
	local nextName = stats.stopNames[(selected % count) + 1] or "?"
	local rows : {TreeNodeId} = {}
	for _, v in ipairs(stats.vehicles) do
		if v.leg == selected then rows[#rows + 1] = vehicleRow(v) end
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
		"Lines that go from the selected stop to " .. dest.name .. ", fastest first.")
end

-- "<time>  <colour> <line name>  <difference>". Every name is a NameTextView
-- so the rows share one height; this line's click does nothing, the others
-- open their own window.
local function competingRow(line : MlsCompetingLine, data : MlsCompeting, dest : MlsDestination) : TreeNodeId
	local nameNode = line_react_util.NameTextView{
		entity = line.lineId,
		onClickOverride = line.isThisLine
			and function(_ : Engine.Entity) end
			or function(e : Engine.Entity) openLineDetails(e) end,
		tooltip = line.isThisLine and "The line this window is about." or ("Open Line Details for " .. line.name),
		styleClass = "mls-line-name",
	}
	local diffClass = isFaster(line, dest)
		and "font-scale-body, mls-time, mls-faster"
		or "font-scale-body, mls-time"
	return tableRow(COMPETING_COLUMN_WEIGHTS, {
		text(competingTimeStr(line), "font-scale-body, mls-time", competingTimeTooltip(line, data, dest)),
		line_react_util.ColorWidget{ entity = line.lineId },
		nameNode,
		text(differenceStr(line, dest), diffClass, differenceTooltip(line, dest)),
	}, "mls-competing-row")
end

local CompetingPanel = react.RegisterRecipe(
	"MlsCompetingPanel",
	function(p : CompetingParams) : TreeNodeId
		local lineId : Engine.Entity = p.lineId
		local stopIndex : integer = p.stopIndex

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
						rows[#rows + 1] = competingRow(line, data, dest)
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

-- The window body. The styled Component carries the minimum width; without
-- it the window shrinks until the text is cut off.
local function detailsBody(children : {TreeNodeId}, class? : string) : TreeNodeId
	return builtin.BoxLayout{
		child = builtin.Component{
			meta = { class = class or "mls-details" },
			layout = builtin.BoxLayout{
				orientation = builtin.type.Orientation.Horizontal,
				children = children,
			},
		},
	}
end

local LineDetailsContent = react.RegisterRecipe(
	"MlsLineDetailsContent",
	function(p : WindowParams) : TreeNodeId
		local lineId : Engine.Entity = p.lineId

		react.useInputAction("IA_MENU_BACK", react.iaHandler(p.onClose))
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

		-- Selected stop, 1-based; stop 1 on open.
		local selState = react.useState(1) as ReactStateT<integer>
		-- Whether the competing-lines panel is shown. nil until the user
		-- presses More/Less; until then it follows whether the line has any
		-- competition at all. Hidden, the panel's recipe is not mounted, so
		-- its timer stops and the window can be narrower.
		local showState = react.useState(nil) as ReactStateT<boolean>

		local message = messageFor(stats)
		if message ~= nil then
			return detailsBody({ text(message, "font-scale-body") })
		end

		-- Clamp in case the line lost stops since the selection was made.
		local count = #stats.stops
		local selected : integer = selState:old()
		if selected == nil or selected < 1 or selected > count then selected = 1 end

		local choice = showState:old()
		local shown : boolean = choice ~= nil and choice or (choice == nil and stats.hasCompetition)
		local toggle = button_react_util.makeTextButton(
			"primary",
			shown and "<- Less" or "-> More",
			function() showState:set(not shown) end,
			shown and LESS_TOOLTIP or MORE_TOOLTIP)

		local left = styledColumn("mls-left", {
			summaryBlock(stats, toggle),
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
			stopList(stats, selected, function(i : integer)
				if i >= 1 then selState:set(i) end
			end),
		})

		if not shown then
			return detailsBody({ left }, "mls-details-narrow")
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

		return detailsBody({ left, right })
	end)

local LineDetailsWindow = react.RegisterWrapperRecipe(
	"MlsLineDetailsWindow",
	builtin.Window,
	function(p : WindowParams) : TreeNodeId
		return builtin.Window{
			id = windowKey(p.lineId),
			title = p.title,
			onClose = p.onClose,
			closable = true,
			autoFocusOnBecomingVisible = true,
			content = LineDetailsContent(p),
		}
	end)

openLineDetails = function(lineId : Engine.Entity)
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
		onClose = function()
			winApi.removeWindow(LineDetailsWindow, key)
			openWindows[lineId] = nil
		end,
	} as WindowParams)
end

------------------------------------------------------------
-- LINE WINDOW CARD
------------------------------------------------------------

-- Just the Show button, in the base game's blue "primary" style. No engine
-- reads and no timer, so the card costs nothing while line windows are open.
local MlsCardContent = react.RegisterRecipe(
	"MlsCardContent",
	function(p : CardParams) : TreeNodeId
		return builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = {
				button_react_util.makeTextButton(
					"primary",
					"Show",
					function() openLineDetails(p.lineId) end,
					"Show the time between stops and the competing lines for this line"),
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
}
