--!strict
--[[
	An overlay that takes over a panel: the Shop's case preview, the
	Inventory's case reveal.

	A plain module (ARCHITECTURE.md Recipe 3). An overlay is authored in Studio
	as a child of the panel it covers. Drawing it on top was not enough: the
	panel's own padding left its edges uncovered, the header poked out, and --
	worse -- the buttons underneath still took clicks through it. So instead of
	covering the panel, the overlay REPLACES its content: show() hides every
	other visible child of the panel and returns the function that puts back
	exactly the ones it hid. Templates and popups that were already hidden are
	left alone, so nothing that should stay hidden is revealed on close.
]]

local PanelOverlay = {}

export type Restore = () -> ()

-- Shows `overlay`, hiding its visible siblings. Call the result to undo.
function PanelOverlay.show(overlay: GuiObject): Restore
	local hidden: { GuiObject } = {}
	local panel = overlay.Parent
	if panel ~= nil then
		for _, child in panel:GetChildren() do
			if child ~= overlay and child:IsA("GuiObject") and child.Visible then
				child.Visible = false
				table.insert(hidden, child)
			end
		end
	end
	overlay.Visible = true

	local restored = false
	return function()
		if restored then
			return
		end
		restored = true
		overlay.Visible = false
		for _, child in hidden do
			-- A child destroyed meanwhile (a PlayerGui re-clone) is skipped.
			if child.Parent ~= nil then
				child.Visible = true
			end
		end
	end
end

return PanelOverlay
