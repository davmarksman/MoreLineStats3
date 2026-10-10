-- Styles for the Line Details window, loaded by the game from content/.
-- Classes are set with meta.class in line_gui.script.tl; only Components and
-- widgets take them. Margins and padding are { top, right, bottom, left }.
-- Selectors under the window recipe also reach the nested competing panel.
local ssu = require "::/gui/main/stylesheetutil.lua"

function data()
	local result = {}
	local a = ssu.makeAdder(result)

	-- Window body: both columns, or only the left one with the competing
	-- panel hidden. The Component carries the minimum width.
	a("R::MlsLineDetailsContent !mls-details", {
		minSize = { 1120, -1 },
		padding = { 8, 8, 8, 8 },
	})
	a("R::MlsLineDetailsContent !mls-details-narrow", {
		minSize = { 708, -1 },
		padding = { 8, 8, 8, 8 },
	})

	-- Left column: summary + stop list. Right column: competing lines.
	a("R::MlsLineDetailsContent !mls-left", {
		size = { 680, -1 },
		margin = { 0, 12, 0, 0 },
	})
	-- gravity { x, y }: 0, 0 pins the right column to the top of the row
	-- instead of centring it against the taller left column.
	a("R::MlsLineDetailsContent !mls-right", {
		size = { 412, -1 },
		gravity = { 0, 0 },
	})

	-- The ScrollArea gives its content no width, so the rows need one
	-- (less than the column, leaving room for the scrollbar).
	a("R::MlsLineDetailsContent !mls-scroll-content", {
		size = { 396, -1 },
	})

	-- The summary block and the "From ..." heading.
	a("R::MlsLineDetailsContent !mls-journey", {
		margin = { 0, 0, 8, 0 },
	})

	-- The vehicles block above the competing lines.
	a("R::MlsLineDetailsContent !mls-vehicles", {
		margin = { 0, 0, 16, 0 },
	})

	-- "Vehicles on Section" / "Competing Lines" title rows.
	a("R::MlsLineDetailsContent !mls-section-title", {
		margin = { 0, 0, 4, 0 },
	})

	-- "To <station>" headings inside the competing list.
	a("R::MlsLineDetailsContent !mls-destination", {
		margin = { 6, 0, 2, 0 },
	})

	-- Numbers: right-aligned, with a gap on the left from the previous column.
	a("R::MlsLineDetailsContent !mls-time", {
		gravity = { 1, 0.5 },
		margin = { 0, 0, 0, 12 },
	})

	-- 20 px icons, right-aligned like the numbers.
	a("R::MlsLineDetailsContent !mls-icon", {
		size = { 20, 20 },
		minSize = { 20, 20 },
		maxSize = { 20, 20 },
		gravity = { 1, 0.5 },
		margin = { 0, 0, 0, 12 },
	})

	-- The pin image inside a heading's locate button: no margin, no gravity
	-- (mls-icon's left margin pushed it out of the 24 px button).
	a("R::MlsLineDetailsContent !mls-pin-icon", {
		size = { 20, 20 },
		minSize = { 20, 20 },
		maxSize = { 20, 20 },
	})

	-- Locate pin buttons (headings) and the stop number + pin button.
	a("R::MlsLineDetailsContent !mls-locate", {
		size = { 24, 24 },
		minSize = { 24, 24 },
		maxSize = { 24, 24 },
		padding = { 2, 2, 2, 2 },
		margin = { 0, 4, 0, 0 },
	})
	a("R::MlsLineDetailsContent !mls-stop-locate", {
		padding = { 0, 4, 0, 2 },
		margin = { 0, 0, 0, 0 },
	})

	a("R::MlsLineDetailsContent !mls-summary-icons", {
		margin = { 4, 0, 4, 0 },
	})

	-- Competing-line rows: the line-name widget is a button with its own
	-- padding, which made the rows tall. Zero its padding and cap the row.
	a("R::MlsLineDetailsContent !mls-line-name", {
		padding = { 0, 0, 0, 0 },
		margin = { 0, 0, 0, 0 },
	})
	a("R::MlsLineDetailsContent !mls-competing-row", {
		maxSize = { -1, 26 },
	})

	-- The HUD button (lines_gui.script.tl) and the all-lines window body.
	a("R::MlsLinesButton ToggleButton!mls-toolbar-btn", {
		padding = { 4, 8, 4, 8 },
		margin = { 1, 1, 2, 1 },
		gravity = { 0.5, 0.5 },
	})
	-- Opens centred on the screen (anchor and gravity, as the timetable mod
	-- does) at a fixed size.
	a("Window#mls.lines.window", {
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
	a("R::MlsLinesWindowContent Button!mls-header-btn", {
		padding = { 2, 0, 2, 0 },
		margin = { 0, 0, 0, 0 },
		gravity = { -1, -1 },
		maxSize = { -1, 30 },
		backgroundImage1 = { fileName = "" },
		borderImage = { fileName = "" },
	})
	-- Anchor the header content left (Name) or right (numbers); a button
	-- centres it otherwise. "> *" is the content node inside the button.
	a("R::MlsLinesWindowContent Button!mls-header-left > *", {
		gravity = { 0, 0.5 },
	})
	a("R::MlsLinesWindowContent Button!mls-header-right > *", {
		gravity = { 1, 0.5 },
	})
	a("R::MlsLinesWindowContent Button!mls-header-btn:hover", {
		backgroundColor = { 1, 1, 1, 0.12 },
		backgroundColor1 = { 1, 1, 1, 0.12 },
	})
	a("R::MlsLinesWindowContent Button!mls-header-btn:active", {
		backgroundColor = { 1, 1, 1, 0.2 },
		backgroundColor1 = { 1, 1, 1, 0.2 },
	})
	-- Filter row: "All" plus one toggle per vehicle kind, and the search box.
	a("R::MlsLinesWindowContent !mls-filter-row", {
		margin = { 0, 0, 6, 0 },
	})
	a("R::MlsLinesWindowContent ToggleButton!mls-filter-btn", {
		minSize = { 32, 32 },
		maxSize = { -1, 32 },
		padding = { 4, 6, 4, 6 },
		margin = { 0, 4, 0, 0 },
	})
	a("R::MlsLinesWindowContent TextInputField!mls-search", {
		size = { 260, 32 },
		minSize = { 260, 32 },
		maxSize = { 260, 32 },
	})

	-- The colour swatch is a real button (opens the game's line window):
	-- keeps the default button chrome, with a little padding around the
	-- swatch so it reads as clickable.
	a("R::MlsLinesWindowContent Button!mls-colour-btn", {
		padding = { 2, 4, 2, 4 },
		margin = { 1, 6, 1, 0 },
	})
	a("R::MlsLinesWindowContent !mls-header-icon", {
		size = { 20, 20 },
		minSize = { 20, 20 },
		maxSize = { 20, 20 },
	})
	a("R::MlsLinesWindowContent !mls-sort-arrow", {
		size = { 12, 12 },
		minSize = { 12, 12 },
		maxSize = { 12, 12 },
		margin = { 0, 0, 0, 2 },
	})
	a("R::MlsLinesWindowContent !mls-lines", {
		minSize = { 1140, -1 },
		padding = { 8, 8, 8, 8 },
	})
	-- The header row is outside the scroll area, so it takes the scroll
	-- content's width to line up with the rows beside the scrollbar.
	-- Same width as the row box (mls-lines-scroll), so the header columns
	-- sit exactly over the row columns.
	a("R::MlsLinesWindowContent !mls-lines-header", {
		size = { 1126, 30 },
		maxSize = { 1126, 30 },
	})
	-- The list scrolls inside a fixed box; its content needs its own width.
	-- As wide as the body, so the scrollbar sits at the window's edge; the
	-- rows are narrower, which leaves the gap between Freq. and the bar.
	a("R::MlsLinesWindowContent ScrollArea!mls-lines-scrollarea", {
		size = { 1144, 570 },
		minSize = { 1144, 570 },
		maxSize = { 1144, 570 },
	})
	-- Waiting and Unhappy cells: the number, then a 16 px icon after a
	-- small gap. The number keeps the usual 12 px gap from the previous
	-- column.
	a("R::MlsLinesWindowContent !mls-cell-num", {
		gravity = { 1, 0.5 },
		margin = { 0, 0, 0, 12 },
	})
	a("R::MlsLinesWindowContent !mls-cell-icon", {
		size = { 16, 16 },
		minSize = { 16, 16 },
		maxSize = { 16, 16 },
		gravity = { 1, 0.5 },
		margin = { 0, 0, 0, 4 },
	})
	-- Fixed, not just preferred, and narrower than the 1104 px scroll area:
	-- the rest is the gap before the scrollbar (a spacer beside the box
	-- takes it, so the scroll area can't stretch the rows).
	a("R::MlsLinesWindowContent !mls-lines-scroll", {
		size = { 1126, -1 },
		minSize = { 1126, -1 },
		maxSize = { 1126, -1 },
	})
	-- Same cell styles as Line Details (selectors are per window recipe).
	a("R::MlsLinesWindowContent !mls-time", {
		gravity = { 1, 0.5 },
		margin = { 0, 0, 0, 12 },
	})
	a("R::MlsLinesWindowContent !mls-icon", {
		size = { 20, 20 },
		minSize = { 20, 20 },
		maxSize = { 20, 20 },
		gravity = { 1, 0.5 },
		margin = { 0, 0, 0, 12 },
	})
	a("R::MlsLinesWindowContent !mls-line-name", {
		padding = { 0, 0, 0, 0 },
		margin = { 0, 0, 0, 0 },
	})
	a("R::MlsLinesWindowContent !mls-competing-row", {
		maxSize = { -1, 26 },
	})
	a("R::MlsLinesWindowContent !mls-section-title", {
		margin = { 0, 0, 4, 0 },
	})

	-- Highlights: faster competitor (green), busiest leg (amber), most
	-- unhappy stop (red).
	a("R::MlsLineDetailsContent !mls-faster", {
		color = { 0.55, 0.9, 0.55, 1.0 },
	})
	a("R::MlsLineDetailsContent !mls-busiest", {
		color = { 1.0, 0.8, 0.45, 1.0 },
	})
	a("R::MlsLineDetailsContent !mls-unhappy", {
		color = { 1.0, 0.65, 0.6, 1.0 },
	})

	return result
end
