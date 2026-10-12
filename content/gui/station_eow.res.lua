function data()
	return {
		-- Adds the More Line Stats card to the station window
		-- (react-plugin at the base-game "::StationGroupEowExtensionPoint").
		-- "@MlsStationEowCard" is the key in station_gui.script.tl's return table.
		type = "react-plugin ::StationGroupEowExtensionPoint",
		data = {
			filePath = "bottle_more_line_stats::/gui/station_gui.script@MlsStationEowCard",
			order = 100,
		}
	}
end
