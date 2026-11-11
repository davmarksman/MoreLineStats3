-- More Line Stats: the windows reopen where they were last left.
--
-- One spot per window kind ("lines", "lineDetails", "cargoDetails",
-- "stationCompeting"), kept for the session in this module (GUI thread,
-- nothing in the save). The first window of a kind opens centred by the
-- stylesheet (class mls-centred-window); once one has been moved, the next
-- opens at the spot through builtin.Window's initialX / initialY, without the
-- class (a stylesheet gravity would override them).
--
-- initialX / initialY are the window's top-left corner in screen fractions,
-- as the Sticky Notes mod (mod.io 6487152) uses them. Settled in game
-- 2026-11-11: a Line Details spot saved at top-left 0.500, 0.501 reopened
-- with its top-left exactly there. The game keeps a window on screen by
-- itself: a spot whose window would cross the right edge or hang below the
-- screen opens pulled back in (ENGINE_FACTS §10).
--
-- Reading the position, as Sticky Notes does: there is no "window moved"
-- callback, and the window wrapper's own position reads 0,0, so the content
-- recipe reads its own node every POLL_FRAMES frames (react.useSelfRef,
-- getPosition; construction.tl:648 reads a node the same way). The content
-- sits below the title bar, so the offset from the window's top-left to the
-- content's is measured once per kind, on a centred open, whose top-left is
-- known from the window's size (api.gui.byId.getSize).
--
-- A position is remembered once it changed and then held still for one poll.
-- A size change (the More/Less panel, data arriving) is not a move: the new
-- position becomes the start. Safeguards (review, 2026-11-11): an offset that
-- doesn't look like a title bar is not used (the window was moved before the
-- first read), and a window whose position can't be read logs that once.
--
-- Positions and sizes are normalised to screen fractions (a value over 1.5
-- is taken as pixels and divided by the screen size), as Sticky Notes does.

local react = ug_require "::/gui/main/react.lua" as React

local LUA_UTILS : string = "bottle_more_line_stats::/scripts/lua_utils.script.tl"
local luaUtils = require(LUA_UTILS) as MlsLuaUtils

-- Read every this many frames (about 0.5 s at 60 fps).
local POLL_FRAMES : integer = 30
-- The class whose stylesheet rule centres a window (mls.css.lua).
local CENTRED_CLASS : string = "mls-centred-window"

-- The bounds of a plausible content offset: the content sits on or right of
-- the window's left edge and below its top (a title bar of about 0.033 at
-- 1440 px, measured 2026-11-11).
local MAX_OFFSET_X : number = 0.05
local MAX_OFFSET_Y : number = 0.1
-- A size change smaller than this is not a change.
local SIZE_TOLERANCE : number = 0.002

-- Per kind: the remembered spot, and the offset from the window's top-left
-- to its content's top-left (screen fractions).
local record FrameOffset
	dx : number
	dy : number
end
local spots : {string : MlsWindowSpot} = {}
local frameOffsets : {string : FrameOffset} = {}

-- Per open window (a ref of its content recipe).
local record PollState
	frames : integer
	startKey : string   -- the first position read, or the position after the last size change
	lastKey : string    -- the position at the previous poll
	savedKey : string   -- the position this window last remembered
	width : number      -- the window's size at the previous poll
	height : number
	failed : boolean    -- an error was logged once
	stuck : boolean     -- "cannot read" was logged once
end

local function spotFor(kind : string) : MlsWindowSpot
	return spots[kind]
end

local function place(win : Builtin.WindowParam, spot : MlsWindowSpot)
	if spot ~= nil then
		win.initialX = spot.x
		win.initialY = spot.y
	else
		-- WindowParam doesn't declare meta; the game's entity window sets it the same way.
		(win as {string : any}).meta = { class = CENTRED_CLASS }
	end
end

local function normalise(x : number, y : number, screen : Vec2i) : number, number
	if (x > 1.5 or y > 1.5) and screen ~= nil and screen.x > 0 and screen.y > 0 then
		return x / screen.x, y / screen.y
	end
	return x, y
end

local function clamp01(value : number) : number
	return math.max(0, math.min(1, value))
end

local function spotKey(x : number, y : number) : string
	return string.format("%.3f,%.3f", x, y)
end

-- Logs once per window that its position can't be read (nothing is saved then).
local function stuck(kind : string, windowId : string, state : PollState, why : string)
	if state.stuck then return end
	state.stuck = true
	luaUtils.debug("window position " .. kind .. ": cannot read " .. windowId .. " (" .. why .. "), not remembered")
end

local function poll(kind : string, windowId : string, spot : MlsWindowSpot, selfRef : ReactRefWrap, state : PollState)
	if selfRef:hasExpired() then return end
	local node = selfRef:get()
	if node == nil then return stuck(kind, windowId, state, "no node") end
	local screen = api.gui.camera.getSize()
	local topLeft = node:getPosition(0, 0)
	local bottomRight = node:getPosition(1, 1)
	local left, top = normalise(topLeft.x, topLeft.y, screen)
	local right, bottom = normalise(bottomRight.x, bottomRight.y, screen)
	if not (right > left and bottom > top) then return stuck(kind, windowId, state, "content has no extent") end
	local size = api.gui.byId.getSize(windowId)
	if size == nil then return stuck(kind, windowId, state, "no window size") end
	local width, height = normalise(size.x, size.y, screen)
	if width <= 0 or height <= 0 then return stuck(kind, windowId, state, "window size 0") end

	local offset = frameOffsets[kind]
	if offset == nil then
		-- Measurable only on a centred open, before any move.
		if spot ~= nil then return end
		local dx = (1 - width) / 2 - left
		local dy = (1 - height) / 2 - top
		if dx > 0.001 or dx < -MAX_OFFSET_X or dy > 0.001 or dy < -MAX_OFFSET_Y then
			-- Already moved: not centred any more. Try again on the next centred open.
			return stuck(kind, windowId, state, string.format("offset %.4f, %.4f not plausible, moved before the first read", dx, dy))
		end
		offset = { dx = dx, dy = dy }
		frameOffsets[kind] = offset
		luaUtils.debug(string.format("window position %s: content offset %.4f, %.4f (window %.3f x %.3f, content at %.4f, %.4f)",
			kind, offset.dx, offset.dy, width, height, left, top))
	end

	-- The window's top-left corner.
	local x = clamp01(left + offset.dx)
	local y = clamp01(top + offset.dy)
	local key = spotKey(x, y)
	if state.startKey == nil then
		state.startKey = key
		state.lastKey = key
		state.width, state.height = width, height
		-- Where it landed against where it was asked to go (the game pulls a
		-- window that wouldn't fit back on screen, so these may differ).
		luaUtils.debug(string.format("window position %s: %s opened at %s, asked %s (window %.3f x %.3f)",
			kind, windowId, key, spot ~= nil and spotKey(spot.x, spot.y) or "centred", width, height))
		return
	end
	-- A size change (the side panel, data arriving) may move the window
	-- without a drag: take the new position as the start, save nothing.
	if math.abs(width - state.width) > SIZE_TOLERANCE or math.abs(height - state.height) > SIZE_TOLERANCE then
		luaUtils.debug(string.format("window position %s: resized %.3f x %.3f -> %.3f x %.3f, now at %s (was %s)",
			kind, state.width, state.height, width, height, key, state.lastKey))
		state.width, state.height = width, height
		state.startKey = key
		state.lastKey = key
		state.savedKey = nil
		return
	end
	-- Moved (away from where it opened, or again after a save) and still since the last poll.
	local moved = key ~= state.savedKey and (state.savedKey ~= nil or key ~= state.startKey)
	if moved and key == state.lastKey then
		spots[kind] = { x = x, y = y }
		state.savedKey = key
		luaUtils.debug(string.format("window position %s: remembered %s (window %.3f x %.3f)", kind, key, width, height))
	end
	state.lastKey = key
end

local function usePoll(kind : string, windowId : string, spot : MlsWindowSpot)
	local selfRef = react.useSelfRef()
	local stateRef = react.useRef({ frames = 0 } as PollState) as ReactRefT<PollState>
	-- GUI thread, every frame while the window is open: a counter and a compare.
	react.onStep(function()
		local state = stateRef:get()
		if state == nil then return end
		state.frames = state.frames + 1
		if state.frames % POLL_FRAMES ~= 0 then return end
		-- The function returns a value so pcall's second result (the error) is declared.
		local ok, err = pcall(function() : boolean
			poll(kind, windowId, spot, selfRef, state)
			return true
		end)
		if not ok and not state.failed then
			state.failed = true
			luaUtils.log("window position " .. kind .. " failed: " .. tostring(err))
		end
	end)
end

local exports : MlsWindowPosition = {
	spotFor = spotFor,
	place = place,
	usePoll = usePoll,
}
return exports
