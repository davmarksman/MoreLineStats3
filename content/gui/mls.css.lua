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
		minSize = { 1160, -1 },
		padding = { 8, 8, 8, 8 },
	})
	add("R::" .. recipeName .. " !mls-details-narrow", {
		minSize = { 748, -1 },
		padding = { 8, 8, 8, 8 },
	})

	-- Left column: summary + stop list. Right column: vehicles on section and
	-- competing lines (Line Details) or cargo on line (Cargo Details).
	-- 720 px (was 680, 2026-10-17): the extra 40 px went to the To next
	-- column, whose weight rose by one, so "~20:40" is no longer cropped.
	add("R::" .. recipeName .. " !mls-left", {
		size = { 720, -1 },
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

	-- The side panel's lists (widgets.fixedScrollBox): fixed boxes that
	-- scroll beyond their rows, so the window keeps its height from stop to
	-- stop (2026-11-12). Vehicles: four 26 px rows. Competing Lines (Line
	-- Details; reached through the nested recipe): eight.
	add("R::" .. recipeName .. " ScrollArea!mls-vehicles-scrollarea", {
		size = { 412, 108 },
		minSize = { 412, 108 },
		maxSize = { 412, 108 },
	})
	add("R::" .. recipeName .. " ScrollArea!mls-competing-scrollarea", {
		size = { 412, 212 },
		minSize = { 412, 212 },
		maxSize = { 412, 212 },
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

	-- "Vehicles" /"Competing Lines" / "Cargo on Line" title rows.
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

	-- The Summary row's buttons (Open Line Window, Manage Line, More/Less):
	-- a gap before each so they don't touch.
	add("R::" .. recipeName .. " !mls-summary-btn", {
		margin = { 0, 0, 0, 8 },
	})
	-- The Manage Line button's icon (the game's), before its label.
	add("R::" .. recipeName .. " !mls-btn-icon", {
		size = { 20, 20 },
		minSize = { 20, 20 },
		maxSize = { 20, 20 },
		margin = { 0, 4, 0, 0 },
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
	-- The "->" between the two stations of the Cargo panel's section line.
	add("R::MlsCargoDetailsContent !mls-section-arrow", {
		margin = { 0, 8, 0, 8 },
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
	-- The row of icon-and-number cells above the two buttons.
	add("R::MlsCardContent !mls-card-icons", {
		margin = { 0, 0, 8, 0 },
	})

	-- All four windows open centred through this class the first time in a
	-- session; once one has been moved, the next of its kind opens there
	-- through initialX / initialY without the class (window_position.script.tl;
	-- a gravity here would override them). No size: a window takes the size
	-- of its content, as the game's own class-styled `Window!missing-res-window`
	-- does with the same two properties; the lines window's size is below.
	add("Window!mls-centred-window", {
		anchorPoint = { 0.5, 0.5 },
		gravity = { 0.5, 0.5 },
	})

	-- The HUD button (lines_list_gui.script.tl) and the all-lines window body.
	add("R::MlsLinesButton ToggleButton!mls-toolbar-btn", {
		padding = { 4, 8, 4, 8 },
		margin = { 1, 1, 2, 1 },
		gravity = { 0.5, 0.5 },
	})
	-- A fixed size (centred by the class above, or placed where it was last
	-- left). 40 px taller than before the tabs, for the tab
	-- strip (2026-10-14), so the list keeps its height; 110 px wider for the
	-- Balance column (2026-11-07): the window, body, scroll area, header and
	-- row box all grew by it.
	add("Window#mls.lines.window", {
		size = { 1270, 830 },
	})
	-- The Passengers / Cargo tab strip is a header only: its tabs have empty
	-- items, and their content box is hidden as in the game's vehicle store
	-- (vehicle_store.css.lua, "R::TopBar TabWidget::Content").
	add("R::MlsLinesWindowContent TabWidget!mls-lines-tabs", {
		margin = { 0, 0, 6, 0 },
	})
	add("R::MlsLinesWindowContent TabWidget!mls-lines-tabs TabWidget::Content", {
		visibility = "none",
	})
	-- The selected tab stands out: the game's default differs only by a
	-- slightly lighter surface (shadowColor BaseLight against BaseMedium),
	-- so the selected one takes the accent blue of the primary buttons and
	-- the other's label is greyed. Hover and press keep the game's colours.
	local colorDefault = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/default_colors.gres")).data
	add("R::MlsLinesWindowContent TabWidget!mls-lines-tabs TabWidget::Indicator!checked", {
		shadowColor = colorDefault.AccentMedium,
	})
	add("R::MlsLinesWindowContent TabWidget!mls-lines-tabs TabWidget::Indicator!unchecked TextView", {
		color = colorDefault.NeutralLight,
	})
	-- Cargo tab: the type icons in the Cargo column (the same classes as the
	-- Loads cell of Cargo Details; selectors are per window recipe).
	add("R::MlsLinesWindowContent !mls-cargo-icon", {
		size = { 20, 20 },
		minSize = { 20, 20 },
		maxSize = { 20, 20 },
		margin = { 0, 2, 0, 2 },
	})
	add("R::MlsLinesWindowContent !mls-cargo-loads", {
		gravity = { 1, 0.5 },
		margin = { 0, 0, 0, 8 },
	})
	-- Header cells are buttons without the button chrome (an empty file
	-- name clears the surface and contour images, as the game's own
	-- stylesheet does), filling the cell so the hover highlight covers it
	-- like the game's DataTable headers. The icon inside keeps the 20 px
	-- size without the right-gravity of mls-icon, and the sort arrow is a
	-- small marker after it. Also the sortable Cargo table of Cargo Details
	-- (list_table's headerRow, 2026-11-12).
	for _, recipeName in ipairs({ "MlsLinesWindowContent", "MlsCargoDetailsContent" }) do
	add("R::" .. recipeName .. " Button!mls-header-btn", {
		padding = { 2, 0, 2, 0 },
		margin = { 0, 0, 0, 0 },
		gravity = { -1, -1 },
		maxSize = { -1, 30 },
		backgroundImage1 = { fileName = "" },
		borderImage = { fileName = "" },
	})
	-- Anchor the header content left (Name) or right (numbers); a button
	-- centres it otherwise. "> *" is the content node inside the button.
	add("R::" .. recipeName .. " Button!mls-header-left > *", {
		gravity = { 0, 0.5 },
	})
	add("R::" .. recipeName .. " Button!mls-header-right > *", {
		gravity = { 1, 0.5 },
	})
	add("R::" .. recipeName .. " Button!mls-header-btn:hover", {
		backgroundColor = { 1, 1, 1, 0.12 },
		backgroundColor1 = { 1, 1, 1, 0.12 },
	})
	add("R::" .. recipeName .. " Button!mls-header-btn:active", {
		backgroundColor = { 1, 1, 1, 0.2 },
		backgroundColor1 = { 1, 1, 1, 0.2 },
	})
	add("R::" .. recipeName .. " !mls-header-icon", {
		size = { 20, 20 },
		minSize = { 20, 20 },
		maxSize = { 20, 20 },
	})
	add("R::" .. recipeName .. " !mls-sort-arrow", {
		size = { 12, 12 },
		minSize = { 12, 12 },
		maxSize = { 12, 12 },
		margin = { 0, 0, 0, 2 },
	})
	end
	-- Filter row: "All" plus one toggle per vehicle kind, and the search box.
	-- One row holds the title, the filters, the search box and Refresh
	-- (2026-11-09; the title had its own row before, and the list grew by
	-- that row's 30 px).
	add("R::MlsLinesWindowContent !mls-filter-row", {
		margin = { 0, 0, 6, 0 },
	})
	-- The "Lines: 12" title at the row's left end, centred on the 32 px
	-- toggles, with a gap before the first of them.
	add("R::MlsLinesWindowContent !mls-list-title", {
		gravity = { 0, 0.5 },
		margin = { 0, 12, 0, 0 },
	})
	-- Refresh at the right end, a gap after the search box.
	add("R::MlsLinesWindowContent Button!mls-refresh-btn", {
		margin = { 0, 0, 0, 8 },
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
	add("R::MlsLinesWindowContent !mls-lines", {
		minSize = { 1250, -1 },
		padding = { 8, 8, 8, 8 },
	})
	-- The header row is outside the scroll area; it has the same width as
	-- the row box (mls-lines-scroll), so the header columns sit exactly
	-- over the row columns.
	add("R::MlsLinesWindowContent !mls-lines-header", {
		size = { 1236, 30 },
		maxSize = { 1236, 30 },
	})
	-- The list scrolls inside a fixed box; its content needs its own width.
	-- As wide as the body, so the scrollbar sits at the window's edge; the
	-- rows are narrower, which leaves the gap between Balance and the bar.
	-- 570 tall until 2026-11-09, then the title row merged into the filter
	-- row and the list took its height; 620 since 2026-11-11, when the
	-- "Not shown: ..." footer under the list was removed.
	add("R::MlsLinesWindowContent ScrollArea!mls-lines-scrollarea", {
		size = { 1254, 620 },
		minSize = { 1254, 620 },
		maxSize = { 1254, 620 },
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
	-- Fixed, not just preferred, and narrower than the 1254 px scroll area:
	-- the rest is the gap before the scrollbar (a spacer beside the box
	-- takes it, so the scroll area can't stretch the rows).
	add("R::MlsLinesWindowContent !mls-lines-scroll", {
		size = { 1236, -1 },
		minSize = { 1236, -1 },
		maxSize = { 1236, -1 },
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
