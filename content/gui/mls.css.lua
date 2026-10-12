-- Styles for the mod's windows and the line-window card, loaded by the game
-- from content/. Classes are set with meta.class in the gui scripts; only
-- Components and widgets take them. Margins and padding are
-- { top, right, bottom, left }. Selectors under a window recipe also reach
-- the recipes nested in it (the competing panel).
local ssu = require "::/gui/main/stylesheetutil.lua"

function data()
	local result = {}
	local add = ssu.makeAdder(result)

	-- The Line Details, Cargo Details and station Competing Lines windows
	-- share their classes, but a rule is keyed on the window recipe, so each
	-- rule is emitted once per recipe name.
	for _, recipeName in ipairs({ "MlsLineDetailsContent", "MlsCargoDetailsContent", "MlsStationCompetingContent" }) do

	-- Window body: both columns, or only the left one with the right column
	-- hidden (also the message-only body). The Component carries the
	-- minimum width.
	add("R::" .. recipeName .. " !mls-details", {
		minSize = { 1120, -1 },
		padding = { 8, 8, 8, 8 },
	})
	add("R::" .. recipeName .. " !mls-details-narrow", {
		minSize = { 708, -1 },
		padding = { 8, 8, 8, 8 },
	})

	-- Left column: summary + stop list. Right column: vehicles on section and
	-- competing lines (Line Details) or cargo on line (Cargo Details).
	add("R::" .. recipeName .. " !mls-left", {
		size = { 680, -1 },
		margin = { 0, 12, 0, 0 },
	})
	-- gravity { x, y }: 0, 0 pins the right column to the top of the row
	-- instead of centring it against the taller left column.
	add("R::" .. recipeName .. " !mls-right", {
		size = { 412, -1 },
		gravity = { 0, 0 },
	})

	-- The ScrollArea gives its content no width, so the rows need one
	-- (less than the column, leaving room for the scrollbar).
	add("R::" .. recipeName .. " !mls-scroll-content", {
		size = { 396, -1 },
	})

	-- The summary block above the stop list.
	add("R::" .. recipeName .. " !mls-journey", {
		margin = { 0, 0, 8, 0 },
	})

	-- The Vehicles on Section block (above the competing lines in Line
	-- Details, below the cargo types in Cargo Details).
	add("R::" .. recipeName .. " !mls-vehicles", {
		margin = { 0, 0, 16, 0 },
	})

	-- "Vehicles on Section" / "Competing Lines" / "Cargo on Line" title rows.
	add("R::" .. recipeName .. " !mls-section-title", {
		margin = { 0, 0, 4, 0 },
	})

	-- "To <station>" headings inside the competing list.
	add("R::" .. recipeName .. " !mls-destination", {
		margin = { 6, 0, 2, 0 },
	})

	-- Numbers: right-aligned, with a gap on the left from the previous column.
	add("R::" .. recipeName .. " !mls-time", {
		gravity = { 1, 0.5 },
		margin = { 0, 0, 0, 12 },
	})

	-- 20 px icons, right-aligned like the numbers.
	add("R::" .. recipeName .. " !mls-icon", {
		size = { 20, 20 },
		minSize = { 20, 20 },
		maxSize = { 20, 20 },
		gravity = { 1, 0.5 },
		margin = { 0, 0, 0, 12 },
	})

	-- The pin image inside a heading's locate button: no margin, no gravity
	-- (mls-icon's left margin pushed it out of the 24 px button).
	add("R::" .. recipeName .. " !mls-pin-icon", {
		size = { 20, 20 },
		minSize = { 20, 20 },
		maxSize = { 20, 20 },
	})

	-- Locate pin buttons (headings) and the stop number + pin button.
	add("R::" .. recipeName .. " !mls-locate", {
		size = { 24, 24 },
		minSize = { 24, 24 },
		maxSize = { 24, 24 },
		padding = { 2, 2, 2, 2 },
		margin = { 0, 4, 0, 0 },
	})
	add("R::" .. recipeName .. " !mls-stop-locate", {
		padding = { 0, 4, 0, 2 },
		margin = { 0, 0, 0, 0 },
	})

	add("R::" .. recipeName .. " !mls-summary-icons", {
		margin = { 4, 0, 4, 0 },
	})

	-- Compact rows (competing lines, vehicles, cargo types): the line-name
	-- widget is a button with its own padding, which made the rows tall.
	-- Zero its padding and cap the row.
	add("R::" .. recipeName .. " !mls-line-name", {
		padding = { 0, 0, 0, 0 },
		margin = { 0, 0, 0, 0 },
	})
	add("R::" .. recipeName .. " !mls-compact-row", {
		maxSize = { -1, 26 },
	})

	-- Highlights: faster competitor (green), busiest leg (amber), most
	-- unhappy stop (red).
	add("R::" .. recipeName .. " !mls-faster", {
		color = { 0.55, 0.9, 0.55, 1.0 },
	})
	add("R::" .. recipeName .. " !mls-busiest", {
		color = { 1.0, 0.8, 0.45, 1.0 },
	})
	add("R::" .. recipeName .. " !mls-unhappy", {
		color = { 1.0, 0.65, 0.6, 1.0 },
	})

	end -- per-recipe rules

	-- Cargo Details only: the Loads cell holds up to two small cargo icons
	-- side by side (no right gravity, a small gap), and the per-type rows of
	-- the Cargo on Line panel.
	add("R::MlsCargoDetailsContent !mls-cargo-icon", {
		size = { 20, 20 },
		minSize = { 20, 20 },
		maxSize = { 20, 20 },
		margin = { 0, 2, 0, 2 },
	})
	add("R::MlsCargoDetailsContent !mls-cargo-loads", {
		gravity = { 1, 0.5 },
		margin = { 0, 0, 0, 8 },
	})
	add("R::MlsCargoDetailsContent !mls-cargo-types", {
		margin = { 0, 0, 16, 0 },
	})

	-- The station Competing Lines window (station_gui.script.tl): one column.
	-- The body fits the 396 px scroll content plus the scrollbar and the
	-- 8 px padding; the list scrolls inside a fixed box, because with no
	-- left column nothing else bounds its height and a hub would grow the
	-- window off the screen.
	add("R::MlsStationCompetingContent !mls-station", {
		minSize = { 428, -1 },
		padding = { 8, 8, 8, 8 },
	})
	add("R::MlsStationCompetingContent ScrollArea!mls-station-scrollarea", {
		size = { 412, 520 },
		minSize = { 412, 520 },
		maxSize = { 412, 520 },
	})
	-- The "To <station>" heading is a chrome-less button (opens the station's
	-- window), with the same hover highlight as the lines window's header
	-- buttons so it reads as clickable.
	add("R::MlsStationCompetingContent Button!mls-heading-btn", {
		padding = { 0, 6, 0, 4 },
		margin = { 0, 0, 0, 0 },
	})
	add("R::MlsStationCompetingContent Button!mls-heading-btn:hover", {
		backgroundColor = { 1, 1, 1, 0.12 },
		backgroundColor1 = { 1, 1, 1, 0.12 },
	})

	-- The line-window card: a gap between the Passengers and Cargo buttons
	-- (the class is on the first button only).
	add("R::MlsCardContent Button!mls-card-btn", {
		margin = { 0, 8, 0, 0 },
	})

	-- Line Details, Cargo Details and the station window open centred. No size: the window
	-- takes the size of its content, as the game's own class-styled
	-- `Window!missing-res-window` does with the same two properties.
	add("Window!mls-details-window", {
		anchorPoint = { 0.5, 0.5 },
		gravity = { 0.5, 0.5 },
	})

	-- The HUD button (lines_list_gui.script.tl) and the all-lines window body.
	add("R::MlsLinesButton ToggleButton!mls-toolbar-btn", {
		padding = { 4, 8, 4, 8 },
		margin = { 1, 1, 2, 1 },
		gravity = { 0.5, 0.5 },
	})
	-- Opens centred on the screen (anchor and gravity, as the timetable mod
	-- does) at a fixed size.
	add("Window#mls.lines.window", {
		anchorPoint = { 0.5, 0.5 },
		gravity = { 0.5, 0.5 },
		size = { 1160, 790 },
	})
	-- Header cells are buttons without the button chrome (an empty file
	-- name clears the surface and contour images, as the game's own
	-- stylesheet does), filling the cell so the hover highlight covers it
	-- like the game's DataTable headers. The icon inside keeps the 20 px
	-- size without the right-gravity of mls-icon, and the sort arrow is a
	-- small marker after it.
	add("R::MlsLinesWindowContent Button!mls-header-btn", {
		padding = { 2, 0, 2, 0 },
		margin = { 0, 0, 0, 0 },
		gravity = { -1, -1 },
		maxSize = { -1, 30 },
		backgroundImage1 = { fileName = "" },
		borderImage = { fileName = "" },
	})
	-- Anchor the header content left (Name) or right (numbers); a button
	-- centres it otherwise. "> *" is the content node inside the button.
	add("R::MlsLinesWindowContent Button!mls-header-left > *", {
		gravity = { 0, 0.5 },
	})
	add("R::MlsLinesWindowContent Button!mls-header-right > *", {
		gravity = { 1, 0.5 },
	})
	add("R::MlsLinesWindowContent Button!mls-header-btn:hover", {
		backgroundColor = { 1, 1, 1, 0.12 },
		backgroundColor1 = { 1, 1, 1, 0.12 },
	})
	add("R::MlsLinesWindowContent Button!mls-header-btn:active", {
		backgroundColor = { 1, 1, 1, 0.2 },
		backgroundColor1 = { 1, 1, 1, 0.2 },
	})
	-- Filter row: "All" plus one toggle per vehicle kind, and the search box.
	add("R::MlsLinesWindowContent !mls-filter-row", {
		margin = { 0, 0, 6, 0 },
	})
	add("R::MlsLinesWindowContent ToggleButton!mls-filter-btn", {
		minSize = { 32, 32 },
		maxSize = { -1, 32 },
		padding = { 4, 6, 4, 6 },
		margin = { 0, 4, 0, 0 },
	})
	-- The search box; the spacer before it in the filter row takes the rest.
	add("R::MlsLinesWindowContent TextInputField!mls-search", {
		size = { 440, 32 },
		minSize = { 440, 32 },
		maxSize = { 440, 32 },
	})

	-- The colour swatch is a real button (opens the game's line window):
	-- keeps the default button chrome, with a little padding around the
	-- swatch so it reads as clickable.
	add("R::MlsLinesWindowContent Button!mls-colour-btn", {
		padding = { 2, 4, 2, 4 },
		margin = { 1, 6, 1, 0 },
	})
	add("R::MlsLinesWindowContent !mls-header-icon", {
		size = { 20, 20 },
		minSize = { 20, 20 },
		maxSize = { 20, 20 },
	})
	add("R::MlsLinesWindowContent !mls-sort-arrow", {
		size = { 12, 12 },
		minSize = { 12, 12 },
		maxSize = { 12, 12 },
		margin = { 0, 0, 0, 2 },
	})
	add("R::MlsLinesWindowContent !mls-lines", {
		minSize = { 1140, -1 },
		padding = { 8, 8, 8, 8 },
	})
	-- The header row is outside the scroll area; it has the same width as
	-- the row box (mls-lines-scroll), so the header columns sit exactly
	-- over the row columns.
	add("R::MlsLinesWindowContent !mls-lines-header", {
		size = { 1126, 30 },
		maxSize = { 1126, 30 },
	})
	-- The list scrolls inside a fixed box; its content needs its own width.
	-- As wide as the body, so the scrollbar sits at the window's edge; the
	-- rows are narrower, which leaves the gap between Freq. and the bar.
	add("R::MlsLinesWindowContent ScrollArea!mls-lines-scrollarea", {
		size = { 1144, 570 },
		minSize = { 1144, 570 },
		maxSize = { 1144, 570 },
	})
	-- Waiting and Unhappy cells: the number, then a 16 px icon after a
	-- small gap. The number keeps the usual 12 px gap from the previous
	-- column.
	add("R::MlsLinesWindowContent !mls-cell-num", {
		gravity = { 1, 0.5 },
		margin = { 0, 0, 0, 12 },
	})
	add("R::MlsLinesWindowContent !mls-cell-icon", {
		size = { 16, 16 },
		minSize = { 16, 16 },
		maxSize = { 16, 16 },
		gravity = { 1, 0.5 },
		margin = { 0, 0, 0, 4 },
	})
	-- Fixed, not just preferred, and narrower than the 1144 px scroll area:
	-- the rest is the gap before the scrollbar (a spacer beside the box
	-- takes it, so the scroll area can't stretch the rows).
	add("R::MlsLinesWindowContent !mls-lines-scroll", {
		size = { 1126, -1 },
		minSize = { 1126, -1 },
		maxSize = { 1126, -1 },
	})
	-- Same cell styles as Line Details (selectors are per window recipe).
	add("R::MlsLinesWindowContent !mls-time", {
		gravity = { 1, 0.5 },
		margin = { 0, 0, 0, 12 },
	})
	add("R::MlsLinesWindowContent !mls-line-name", {
		padding = { 0, 0, 0, 0 },
		margin = { 0, 0, 0, 0 },
	})
	add("R::MlsLinesWindowContent !mls-compact-row", {
		maxSize = { -1, 26 },
	})
	add("R::MlsLinesWindowContent !mls-section-title", {
		margin = { 0, 0, 4, 0 },
	})

	return result
end
