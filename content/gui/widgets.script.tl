-- Widget helpers shared by the Line Details and Cargo Details windows
-- (GUI thread). No recipes are registered here, so loading the module from
-- several places is harmless; no engine reads except in click handlers.
--
-- UI tree rules, each learned from a crash (DESIGNv3 §4.1):
--   * List children and TableLayout cells must be widgets or Components,
--     never bare layouts (wrap a layout in builtin.Component{ layout = ... }).
--   * A recipe must return a layout.
--   * Only Components and widgets take meta.class; a class on a layout is
--     ignored.
-- Types in tealdef/mls_def.d.tl (MlsWidgets).

local builtin            = ug_require "::/gui/main/builtin.lua" as Builtin
local gui_react_util     = ug_require "::/gui/main/gui_react_util.tl" as GuiReactUtil
local button_react_util  = ug_require "::/gui/main/button_react_util.tl" as ButtonReactUtil

-- Base-game icons. The game resolves the "@2x" files itself.
local ICON_LOCATE : string = "::/gui/line_vehicle_mgmt/icons/symbol_locate_20.tga"
local ICON_VEHICLES : string = "::/gui/entity_window/icons/relation_vehicle_train_bus.tga"
local ICON_AT_STATION : string = "::/gui/entity_window/icons/building_stations.tga"
local ICON_EN_ROUTE : string = "::/gui/construction/build_control/symbol_slope_0_20.tga"
-- Generic cargo (the game's "mixed cargo" icon): stand-in for a cargo type
-- without an icon.
local ICON_CARGO : string = "::/cargos/icons/cargo_mixed.tga"
-- At most this many icons in a cargo types cell; the rest is "+n" (all
-- names in the tooltip). Two 20 px icons plus "+n" fit about 88 px.
local MAX_CARGO_ICONS : integer = 2
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

local function locateButton(entity : Engine.Entity) : TreeNodeId
	return builtin.Button{
		meta = { class = "mls-locate", tooltip = "Locate" },
		content = builtin.ImageView{
			meta = { class = "mls-pin-icon" },
			path = ICON_LOCATE,
			scaling = builtin.type.ImageViewScaling.AutoFit,
		},
		onClick = function() locate(entity) end,
	}
end

-- Stop number and locate pin as one button, so they share a column.
local function stopLocateButton(index : integer, stationGroup : Engine.Entity) : TreeNodeId
	return button_react_util.makeIconTextButton(
		"mls-stop-locate",
		ICON_LOCATE,
		tostring(index),
		function() locate(stationGroup) end,
		"Locate")
end

-- "<pin> To Alford Station", with an optional node pushed to the right end.
local function locateHeading(stationGroup : Engine.Entity, label : string, class : string, tooltip : string, trailing? : TreeNodeId) : TreeNodeId
	local children : {TreeNodeId} = {
		locateButton(stationGroup),
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

-- A section title with an optional button at the right end.
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

-- One of the base game's icon-and-label cells (the Basics card look).
local function iconCell(path : string, value : string, tooltip : string) : TreeNodeId
	local params : any = { iconPath = path, label = value, tooltip = tooltip }
	return gui_react_util.IconLabelIndicator(params as GuiReactUtil.IconLabelIndicatorParams)
end

-- The Vehicles cell of a stop row, one icon: the station icon when every
-- vehicle on the section stands at this stop; otherwise one vehicle's own
-- kind, or the column's train-and-bus icon for several (including a mix of
-- at-stop and en-route); a dash when the section is empty. The counts are
-- in the tooltip.
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

-- The kind of the one vehicle on the given leg (only meaningful when there is one).
local function kindOnLeg(vehicles : {MlsVehicle}, leg : integer) : string
	for _, vehicle in ipairs(vehicles) do
		if vehicle.leg == leg then return vehicle.kind end
	end
	return "other"
end

-- "At Station" / "En route" icon for a vehicle row.
local function whereIcon(atStation : boolean) : TreeNodeId
	return icon(atStation and ICON_AT_STATION or ICON_EN_ROUTE, atStation and "At Station" or "En route")
end

-- The window body: a horizontal row of columns inside a styled Component,
-- which carries the minimum width (without it the window shrinks until the
-- text is cut off).
local function windowBody(class : string, children : {TreeNodeId}) : TreeNodeId
	return builtin.BoxLayout{
		child = builtin.Component{
			meta = { class = class },
			layout = builtin.BoxLayout{
				orientation = builtin.type.Orientation.Horizontal,
				children = children,
			},
		},
	}
end

-- A cargo type's icon at 20 px, no right gravity (several sit side by side),
-- with a stand-in when the type has none (a load flag for an id the cargo
-- rep doesn't know, or a failed rep read).
local function cargoIcon(cargoType : MlsCargoType, tooltip : string) : TreeNodeId
	local path = ICON_CARGO
	if cargoType ~= nil and cargoType.icon ~= nil and cargoType.icon ~= "" then path = cargoType.icon end
	return builtin.ImageView{
		meta = { class = "mls-cargo-icon", tooltip = tooltip },
		path = path,
		scaling = builtin.type.ImageViewScaling.AutoFit,
	}
end

-- Cargo type icons: up to MAX_CARGO_ICONS, then "+n". The tooltip is the
-- heading and every name; a type no vehicle of the line carries is still
-- shown and called out. A dash when there are none.
local function cargoTypesCell(types : {MlsCargoType}, heading : string, emptyTooltip : string) : TreeNodeId
	if #types == 0 then
		return text("-", "font-scale-body, mls-time", emptyTooltip)
	end
	local names : {string} = {}
	for _, cargoType in ipairs(types) do
		names[#names + 1] = cargoType.name .. (cargoType.capacity > 0 and "" or " (no vehicle of this line carries it)")
	end
	local tooltip = heading .. "\n" .. table.concat(names, "\n")
	local children : {TreeNodeId} = {}
	for i, cargoType in ipairs(types) do
		if i > MAX_CARGO_ICONS then
			children[#children + 1] = text("+" .. tostring(#types - MAX_CARGO_ICONS), "font-scale-body", tooltip)
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

local exports : MlsWidgets = {
	ICON_VEHICLES = ICON_VEHICLES,
	text = text,
	tableRow = tableRow,
	icon = icon,
	iconCell = iconCell,
	locateButton = locateButton,
	stopLocateButton = stopLocateButton,
	locateHeading = locateHeading,
	styledColumn = styledColumn,
	sectionTitle = sectionTitle,
	vehiclesCell = vehiclesCell,
	kindOnLeg = kindOnLeg,
	whereIcon = whereIcon,
	windowBody = windowBody,
	cargoTypesCell = cargoTypesCell,
}
return exports
