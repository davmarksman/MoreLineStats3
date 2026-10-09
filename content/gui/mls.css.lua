-- Styles for the Line Details window, loaded by the game from content/.
-- Classes are set with meta.class in lineGui.script.tl; only Components and
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
	a("R::MlsLineDetailsContent !mls-right", {
		size = { 412, -1 },
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
