function data()
	return {
		-- Adds the More Line Stats card to the line window
		-- (react-plugin at the base-game "::LineEowExtensionPoint").
		-- "@MlsLineEowCard" is the key in lineGui.script.tl's return table.
		type = "react-plugin ::LineEowExtensionPoint",
		data = {
			filePath = "bottle_more_line_stats::/gui/lineGui.script@MlsLineEowCard",
			order = 100,
		}
	}
end
