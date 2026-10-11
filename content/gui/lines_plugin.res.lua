-- Registers the "More Line Stats" button in the HUD's mod-button area.
-- Pattern from celmi_timetables: the extension-point id is "::<name>" for a
-- base-game point, and the recipe is the "@Export" of the module's return
-- table.
function data()
	return {
		type = "react-plugin ::MainModButtonAreaExtension",
		data = {
			filePath = "bottle_more_line_stats::/gui/lines_list_gui.script@MlsLinesButton",
			order = 10,
		},
	}
end
