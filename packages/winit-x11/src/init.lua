local ffi = require("ffi")
local x11 = require("x11api")
local xi2 = require("x11api.xi2")
local wait = require("winit-x11.wait")
local Clipboard = require("winit-x11.clipboard")
local Dnd = require("winit-x11.dnd")
local FileDialog = require("winit-x11.dialog")
local refresh = require("winit-x11.refresh")

-- A property change is a property the window manager writes -- the state a window is in is
-- one -- and it is the only way an iconified window that stays mapped says so. The
-- bindings do not name its event, so the layout Xlib uses for it is laid out here: the
-- atom that changed and the state it was left in, after the fields every event starts with.
ffi.cdef [[
	struct winit_x11_property_event {
		int type;
		unsigned long serial;
		int send_event;
		void *display;
		unsigned long window;
		unsigned long atom;
		unsigned long time;
		int state;
	};
]]

local PROPERTY_NOTIFY = 28
--- PropertyChangeMask, which is not among the masks `x11api` names: a property change on
--- a window selected with it arrives as a PropertyNotify.
local PROPERTY_CHANGE_MASK = 0x00400000
--- WM_STATE's IconicState: ICCCM's name for a minimized window.
local ICONIC_STATE = 3

---@class winit-x11.Window
---@field id number
---@field width number
---@field height number
---@field shouldRedraw boolean
---@field visible boolean? # On the screen: false while it is unmapped or the window manager has iconified it
---@field mapped boolean? # Mapped by the server, which a window manager may hide while keeping it mapped
---@field rawMotion boolean? # Raw motion is selected for this window's pointer grab
---@field frameAsked boolean?
---@field display XDisplay
---@field currentCursor number?
---@field blankCursor number?
---@field cursorGrab winit.CursorGrab?
---@field syncCounter number?
---@field syncPendingLo number?
---@field syncPendingHi number?
---@field iconSet boolean?
local X11Window = {}
X11Window.__index = X11Window

---@param eventLoop winit-x11.EventLoop
---@param width number
---@param height number
function X11Window.new(eventLoop, width, height)
	local display = eventLoop.display

	local root = x11.defaultRootWindow(display)
	if root == 0 then
		x11.closeDisplay(display)
		error("No root window found")
	end

	local id = x11.createSimpleWindow(display, root, 0, 0, width, height, 0, 0, 0x000000)
	if id == 0 then
		x11.closeDisplay(display)
		error("Failed to create window")
	end

	local window = setmetatable({
		display = display,
		id = id,
		width = width,
		height = height,
		syncCounter = nil,
		syncPendingLo = nil,
		syncPendingHi = nil
	}, X11Window)

	-- What the pointer can be drawn as here: `setShape` asks before asking the backend. The hand
	-- is always available; these are the rest of this backend's cursor shapes.
	window.cursors = { text = true, sizewe = true, sizens = true }

	-- Prevent X11 from auto-painting the background (avoids black flicker on resize)
	x11.setWindowBackgroundPixmap(display, window.id, 0) -- 0 = None

	-- Set up _NET_WM_SYNC_REQUEST protocol if the XSync extension is available
	local protocols = { "WM_DELETE_WINDOW" }
	do
		local major = x11.syncInitialize(display)
		if major then
			-- Create a sync counter initialized to 0
			local counter = x11.syncCreateCounter(display, 0)

			-- Set _NET_WM_SYNC_REQUEST_COUNTER property (CARDINAL, 32-bit)
			-- XSyncCounter is unsigned long (64-bit), truncate to uint32_t for CARDINAL
			local counterVal = ffi.new("uint32_t[1]", tonumber(bit.band(counter, 0xFFFFFFFF)))
			x11.changeProperty(display, window.id,
				"_NET_WM_SYNC_REQUEST_COUNTER", "CARDINAL", 32, 0,
				ffi.cast("const unsigned char *", counterVal), 1)

			window.syncCounter = counter
			table.insert(protocols, "_NET_WM_SYNC_REQUEST")
		end
	end

	x11.setWMProtocols(display, window.id, protocols)

	x11.selectInput(
		display,
		window.id,
		bit.bor(
			x11.EventMaskBits.Exposure,
			x11.EventMaskBits.StructureNotify,
			x11.EventMaskBits.SubstructureNotify,
			x11.EventMaskBits.ButtonPress,
			x11.EventMaskBits.ButtonRelease,
			x11.EventMaskBits.PointerMotion,
			x11.EventMaskBits.KeyPress,
			x11.EventMaskBits.KeyRelease,
			x11.EventMaskBits.FocusChange,
			-- The window manager says a window is minimized -- which can happen without it
			-- ever being unmapped -- by changing a property, and only a property change says so.
			PROPERTY_CHANGE_MASK
		)
	)
	-- A window is a place files may be dropped on, which is said by a property the program doing
	-- the dragging reads off it before it starts talking -- so it is set before the window is put
	-- on screen, where a drag could find it.
	eventLoop.dnd:aware(window.id)

	x11.mapWindow(display, window.id)

	return window
end

---@type table<number, string>
local keysymNames = {
	[0x20]   = "space",
	[0xff08] = "backspace",
	[0xff09] = "tab",
	[0xff0d] = "return",
	[0xff1b] = "escape",
	[0xff50] = "home",
	[0xff51] = "left",
	[0xff52] = "up",
	[0xff53] = "right",
	[0xff54] = "down",
	[0xff55] = "page-up",
	[0xff56] = "page-down",
	[0xff57] = "end",
	[0xff63] = "insert",
	[0xffff] = "delete",
	[0xffbe] = "f1",
	[0xffbf] = "f2",
	[0xffc0] = "f3",
	[0xffc1] = "f4",
	[0xffc2] = "f5",
	[0xffc3] = "f6",
	[0xffc4] = "f7",
	[0xffc5] = "f8",
	[0xffc6] = "f9",
	[0xffc7] = "f10",
	[0xffc8] = "f11",
	[0xffc9] = "f12",
	[0xffe1] = "left-shift",
	[0xffe2] = "right-shift",
	[0xffe3] = "left-ctrl",
	[0xffe4] = "right-ctrl",
	[0xffe9] = "left-alt",
	[0xffea] = "right-alt",
	[0xffeb] = "left-super",
	[0xffec] = "right-super",
	[0xffe5] = "caps-lock"
}

---@param keysym number
---@param char string
local function keysymToKey(keysym, char)
	local named = keysymNames[keysym]
	if named then return named end

	if keysym >= 0x20 and keysym <= 0x7e then
		local plain = string.char(keysym)
		if keysym >= 0x41 and keysym <= 0x5a then
			plain = plain:lower()
		end
		return plain
	end

	if #char > 0 then return char end
	return nil
end

local function keyModifiers(state)
	return {
		shift = bit.band(state, 1) ~= 0,
		lock  = bit.band(state, 2) ~= 0,
		ctrl  = bit.band(state, 4) ~= 0,
		alt   = bit.band(state, 8) ~= 0,
		super = bit.band(state, 64) ~= 0
	}
end

local cursors = {
	pointer = x11.Icon.LeftPtr,
	hand2 = x11.Icon.Hand2,
	text = x11.Icon.Xterm,
	sizewe = x11.Icon.SbHDoubleArrow,
	sizens = x11.Icon.SbVDoubleArrow,
}

--- Raw motion is relative movement, which is what a grabbed pointer is used for: a game
--- that holds the pointer still gets movement to turn with. It is selected while a grab is
--- held and let go of when it ends, because selected on the root window it is every mouse
--- movement anywhere on the screen -- a wakeup for a window with nothing to do with it.
---@param display XDisplay
---@param selected boolean
local function selectRawMotion(display, selected)
	local root = x11.defaultRootWindow(display)
	-- An empty mask is how a selection is taken back: XISelectEvents replaces what this
	-- client had selected for the device and window.
	xi2.selectEvents(display, root, xi2.Device.All,
		selected and { xi2.EventType.RawMotion } or {})
	x11.flush(display)
end

--- Says whether a window is on the screen, and asks for a frame when it comes back: what
--- the app drew while it was away is stale, and a window restored without a frame would
--- stay blank until something else asked for one.
---@param window winit-x11.Window
---@param visible boolean
local function setVisible(window, visible)
	if window.visible == visible then
		return
	end

	window.visible = visible
	if visible then
		window.shouldRedraw = true
	end
end

---@return number?
function X11Window:getOrCreateBlankCursor()
	if not self.blankCursor then
		local pixmap = x11.createPixmap(self.display, self.id, 1, 1, 1)
		local color = x11.Color()
		self.blankCursor = x11.createPixmapCursor(self.display, pixmap, pixmap, color, color, 0, 0)
		x11.freePixmap(self.display, pixmap)
	end
	return self.blankCursor
end

---@param mode winit.CursorGrab
function X11Window:setCursorGrab(mode)
	-- safety: the same mode arriving again changes nothing, and warping the pointer every
	-- time it arrived would hold a menu's cursor at the middle of the window while the
	-- player tried to move it
	if mode == self.cursorGrab then
		return
	end

	local previous = self.cursorGrab

	-- Only a grab needs relative movement; the rest of the time the window's own
	-- MotionNotify is what a pointer over it says.
	if mode == "contain" or mode == "locked" then
		if not self.rawMotion then
			selectRawMotion(self.display, true)
			self.rawMotion = true
		end
	elseif previous == "contain" or previous == "locked" then
		selectRawMotion(self.display, false)
		self.rawMotion = false
	end

	local eventMask = bit.bor(
		x11.EventMaskBits.PointerMotion,
		x11.EventMaskBits.ButtonPress,
		x11.EventMaskBits.ButtonRelease
	)

	if mode == "contain" then
		x11.grabPointer(self.display, self.id, 1, eventMask,
			x11.GrabMode.Async, x11.GrabMode.Async, self.id, 0, 0)
	elseif mode == "locked" then
		local blank = assert(self:getOrCreateBlankCursor())
		x11.grabPointer(self.display, self.id, 1, eventMask,
			x11.GrabMode.Async, x11.GrabMode.Async, self.id, blank, 0)
		x11.warpPointer(self.display, 0, self.id, 0, 0, 0, 0,
			math.floor(self.width / 2), math.floor(self.height / 2))
	elseif mode == "none" then
		-- safety: letting go of a grab leaves the pointer wherever the grab had put it,
		-- which can be outside the window, so it is brought back into the middle of it
		-- once, when there was a grab to let go of
		x11.ungrabPointer(self.display, 0)
		if previous == "locked" or previous == "contain" then
			x11.warpPointer(self.display, 0, self.id, 0, 0, 0, 0,
				math.floor(self.width / 2), math.floor(self.height / 2))
		end
	end

	self.cursorGrab = mode
end

---@param shape "pointer" | "hand2" | "text" | "sizewe" | "sizens"
function X11Window:setCursor(shape)
	if self.currentCursor then
		x11.freeCursor(self.display, assert(self.currentCursor))
	end

	local cursor = x11.createFontCursor(self.display, cursors[shape])
	x11.defineCursor(self.display, self.id, cursor)
	self.currentCursor = cursor
end

function X11Window:resetCursor()
	if self.currentCursor then
		x11.freeCursor(self.display, assert(self.currentCursor))
		self.currentCursor = nil
	end

	x11.undefineCursor(self.display, self.id)
end

--- Takes the window off the screen and off the taskbar; its loop and keys keep working.
---@return nil
function X11Window:hide()
	x11.unmapWindow(self.display, self.id)
	x11.flush(self.display)
	return nil
end

--- Brings a hidden or minimized window back, in front and with the keyboard.
---@return nil
function X11Window:show()
	x11.mapWindow(self.display, self.id)
	x11.raiseWindow(self.display, self.id)

	-- A window the window manager has iconified but left mapped is not brought back by
	-- mapping it again -- the server has it mapped already. The manager is asked to
	-- activate it, which is what takes it out of the iconic state and gives it the keyboard.
	local event = x11.Event()
	event.type = x11.EventType.ClientMessage
	event.xclient.window = self.id
	event.xclient.message_type = x11.internAtom(self.display, "_NET_ACTIVE_WINDOW", 0)
	event.xclient.format = 32
	event.xclient.data.l[0] = 2 -- source: a program's own request, not a click on the window
	event.xclient.data.l[1] = x11.CurrentTime
	event.xclient.data.l[2] = 0
	x11.sendEvent(self.display, x11.defaultRootWindow(self.display), 0,
		bit.bor(0x00100000, 0x00080000), event) -- SubstructureRedirectMask | SubstructureNotifyMask
	x11.flush(self.display)
	return nil
end

---@param title string
function X11Window:setTitle(title)
	x11.changeProperty(self.display, self.id, "_NET_WM_NAME", "UTF8_STRING", 8, 0,
		ffi.cast("const unsigned char*", title), #title)
	x11.flush(self.display)
end

--- The window manager's picture for this window. X11 takes it as ARGB words in one CARDINAL
--- property, `_NET_WM_ICON`; a page of sizes can be written, but one good square is what every
--- window manager scales for its title bar and switcher.
---@param width number
---@param height number
---@param rgba string # width * height pixels, four bytes each, in red, green, blue, alpha order
function X11Window:setIcon(width, height, rgba)
	assert(width > 0 and height > 0, "an icon needs a size")
	assert(#rgba == width * height * 4, "an icon needs four bytes for every pixel")

	local data = ffi.new("unsigned long[?]", width * height + 2)
	data[0], data[1] = width, height
	for at = 0, width * height - 1 do
		local i = at * 4 + 1
		local r, g, b, a = rgba:byte(i, i + 3)
		data[at + 2] = a * 0x1000000 + r * 0x10000 + g * 0x100 + b
	end

	x11.changeProperty(self.display, self.id, "_NET_WM_ICON", "CARDINAL", 32, 0,
		ffi.cast("const unsigned char*", data), width * height + 2)
	x11.flush(self.display)
	self.iconSet = true
end

--- The fastest refresh rate of the monitors the X server drives, in hertz, read once: the most
--- frames a window could be shown at. Nothing where XRandR cannot say.
---@return number?
function X11Window:refreshRate()
	if self.refreshHz == nil then
		self.refreshHz = refresh.rate(self.display) or false
	end
	return self.refreshHz or nil
end

function X11Window:destroy()
	if self.rawMotion then
		selectRawMotion(self.display, false)
	end

	if self.currentCursor then
		x11.freeCursor(self.display, assert(self.currentCursor))
	end
	if self.blankCursor then
		x11.freeCursor(self.display, self.blankCursor)
	end

	-- Destroy XSync counter (server-side resource cleanup)
	if self.syncCounter then
		-- Set counter to a minimum value to unblock any compositor waiting on it.
		-- Construct XSyncValue manually instead of calling x11.syncMinValue()
		-- which can cause FFI issues with struct-by-value returns.
		local doneVal = x11.SyncValue()
		doneVal.hi = -1
		doneVal.lo = 0
		x11.syncSetCounter(self.display, assert(self.syncCounter), doneVal)
		x11.syncDestroyCounter(self.display, assert(self.syncCounter))
	end

	x11.destroyWindow(self.display, self.id)
end

---@private
function X11Window:acknowledgeSync()
	if self.syncPendingLo ~= nil and self.syncCounter then
		local value = x11.syncIntsToValue(assert(self.syncPendingLo), assert(self.syncPendingHi))
		x11.syncSetCounter(self.display, assert(self.syncCounter), value)
		self.syncPendingLo, self.syncPendingHi = nil, nil
	end

	self.frameAsked = nil
end

---@class winit-x11.EventLoop
---@field windows table<number, winit-x11.Window>
---@field display XDisplay
---@field netWmState number # The atom of the EWMH list of what the window manager has done to a window
---@field netWmStateHidden number # The atom naming the hidden (minimized) state in that list
---@field wmState number # The atom of the ICCCM state an older window manager keeps
---@field clipboard winit-x11.Clipboard? # The one clipboard made on this loop, whose requests it answers
---@field dnd winit-x11.Dnd # The drag protocol a drop on a window of this loop is read with
---@field stashedEvents XEvent[] # Events kept back while something was waiting on another program
local X11EventLoop = {}
X11EventLoop.__index = X11EventLoop

function X11EventLoop.new()
	local display = x11.openDisplay(nil)
	if display == nil then
		error("Failed to open X11 display")
	end

	local self = setmetatable({
		display = display,
		windows = {},
		clipboard = nil,
		stashedEvents = {},
		-- Interned once: a property notification names the property that changed, and a
		-- window manager writing either state is what says a window is hidden or back.
		netWmState = tonumber(x11.internAtom(display, "_NET_WM_STATE", 0)),
		netWmStateHidden = tonumber(x11.internAtom(display, "_NET_WM_STATE_HIDDEN", 0)),
		wmState = tonumber(x11.internAtom(display, "WM_STATE", 0)),
	}, X11EventLoop)

	self.dnd = Dnd.new(self)

	return self
end

---@param window winit-x11.Window
function X11EventLoop:register(window)
	self.windows[tonumber(window.id)] = window
end

---@param window winit.Window
function X11EventLoop:close(window)
	window:destroy()
	self.windows[tonumber(window.id)] = nil
end

---@param callback winit.EventHandler
function X11EventLoop:run(callback)
	local display = self.display
	local event = x11.Event()
	local tempEvent = x11.Event()

	local wmDeleteWindow = x11.internAtom(display, "WM_DELETE_WINDOW", 0)
	local netWmSyncRequest = x11.internAtom(display, "_NET_WM_SYNC_REQUEST", 0)
	local netWmStateAtom = self.netWmState
	local netWmStateHiddenAtom = self.netWmStateHidden
	local wmStateAtom = self.wmState

	local isActive = true
	local currentMode = "poll"
	local timeout = nil ---@type number?

	---@type table<number, winit.KeyName>
	local held = {}

	--- Whether the window manager says this window is minimized. There are two ways it can:
	--- EWMH lists `_NET_WM_STATE_HIDDEN` among the window's states, and the older ICCCM
	--- `WM_STATE` is IconicState. A manager that only unmaps the window never needs either.
	---@param window winit-x11.Window
	---@return boolean hidden
	local function isHiddenByManager(window)
		local states = x11.getAtomProperty(display, window.id, netWmStateAtom)
		if states then
			for i = 1, #states do
				if states[i] == netWmStateHiddenAtom then
					return true
				end
			end
		end

		local wmState = x11.getAtomProperty(display, window.id, wmStateAtom)

		return wmState ~= nil and wmState[1] == ICONIC_STATE
	end

	--- Re-reads what the manager says about a window that is mapped, where a minimized window
	--- that is still mapped is known by its properties rather than by an unmap.
	---@param window winit-x11.Window
	local function refreshVisible(window)
		if not window.mapped then
			return
		end

		setVisible(window, not isHiddenByManager(window))
	end

	---@type winit.EventManager
	local handler = {}
	do
		function handler:exit()
			isActive = false
		end

		function handler:setMode(mode)
			currentMode = mode
		end

		--- How long the next wait may last, in seconds, or nothing to wait out an event with no
		--- end to it. One wait: a deadline is what a screen with something to do on its own asks
		--- for, and it asks again for the next one. See `winit.EventManager:setTimeout`.
		---@param seconds number?
		---@return nil
		function handler:setTimeout(seconds)
			timeout = seconds
			return nil
		end

		function handler:requestRedraw(window)
			window.shouldRedraw = true
		end

		function handler.close(_, window)
			self:close(window)
		end
	end

	local function readRawMotion(cookie)
		local raw = xi2.castRawEvent(cookie)
		local mask = ffi.cast("unsigned char*", raw.valuators.mask)
		local values = ffi.cast("double*", raw.valuators.values)
		local dx, dy = 0.0, 0.0
		local vi = 0
		for axis = 0, raw.valuators.mask_len * 8 - 1 do
			local byte   = math.floor(axis / 8)
			local bitpos = axis % 8
			if bit.band(mask[byte], bit.lshift(1, bitpos)) ~= 0 then
				if axis == 0 then dx = values[vi] end
				if axis == 1 then dy = values[vi] end
				vi = vi + 1
			end
		end
		return dx, dy
	end

	local function coalesceMouse()
		while x11.pending(display) > 0 do
			x11.peekEvent(display, tempEvent)
			if tempEvent.type ~= x11.EventType.MotionNotify
				or tempEvent.xmotion.window ~= event.xmotion.window then
				break
			end
			x11.nextEvent(display, event)
		end
	end

	---@param dx number
	---@param dy number
	local function coalesceMouseMotion(dx, dy)
		while x11.pending(display) > 0 do
			x11.peekEvent(display, tempEvent)
			if tempEvent.type ~= x11.EventType.GenericEvent then break end

			x11.nextEvent(display, tempEvent)
			if not x11.getEventData(display, tempEvent.xcookie) then break end
			if tempEvent.xcookie.evtype ~= xi2.EventType.RawMotion then
				x11.freeEventData(display, tempEvent.xcookie)
				break
			end

			local ddx, ddy = readRawMotion(tempEvent.xcookie)
			x11.freeEventData(display, tempEvent.xcookie)
			dx = dx + ddx
			dy = dy + ddy
		end

		return dx, dy
	end

	---@type table<number, fun(window: winit-x11.Window?)>
	local Handlers = {
		[x11.EventType.MotionNotify] = function(window)
			callback({ window = window, name = "mouseMove", x = event.xmotion.x, y = event.xmotion.y }, handler)
		end,

		---@param window winit-x11.Window?
		[x11.EventType.ClientMessage] = function(window)
			---@cast window winit-x11.Window
			-- A drag is a conversation of its own, and it is the source that starts it: what it
			-- sends is not an event a program hears about until it ends in a drop.
			if self.dnd:handleClientMessage(window, event, callback, handler) then
				return
			end

			if event.xclient.data.l[0] == wmDeleteWindow then
				callback({ window = window, name = "windowClose" }, handler)
			elseif event.xclient.data.l[0] == netWmSyncRequest then
				if window and window.syncCounter then
					window.syncPendingLo = bit.band(event.xclient.data.l[2], 0xFFFFFFFF)
					window.syncPendingHi = bit.band(event.xclient.data.l[3], 0xFFFFFFFF)
				end

				if window then
					window.frameAsked = true
					window.shouldRedraw = true
				end
			end
		end,

		-- What a program that is pasting something back to us is asking for, and what it tells us
		-- when the clipboard has changed hands. Neither has a window of its own to be routed by:
		-- the request names the requestor, and the clipboard is what knows what it holds.
		[x11.EventType.SelectionRequest] = function()
			if self.clipboard then
				self.clipboard:handleRequest(event)
			end
		end,

		[x11.EventType.SelectionClear] = function()
			if self.clipboard then
				self.clipboard:handleClear(event)
			end
		end,

		-- ... and the answer to one of our own asks, which is the files a drop carried
		[x11.EventType.SelectionNotify] = function()
			self.dnd:handleSelectionNotify(event, callback, handler)
		end,

		[x11.EventType.Expose] = function(window)
			callback({ window = window, name = "redraw" }, handler)
		end,

		[x11.EventType.DestroyNotify] = function(window) end,

		---@param window winit-x11.Window?
		[x11.EventType.ConfigureNotify] = function(window)
			---@cast window winit-x11.Window
			local newWidth = event.xconfigure.width
			local newHeight = event.xconfigure.height

			if newWidth ~= window.width or newHeight ~= window.height then
				window.width = newWidth
				window.height = newHeight
				callback({ window = window, name = "resize" }, handler)
			end
		end,

		[x11.EventType.MapNotify] = function(window)
			if window then
				---@cast window winit-x11.Window
				window.mapped = true
				-- The window manager may have put the window on screen in the state it was
				-- iconified in, which it says with a property rather than with the map.
				setVisible(window, true)
				refreshVisible(window)
			end
			callback({ window = window, name = "map" }, handler)
		end,

		[x11.EventType.UnmapNotify] = function(window)
			if window then
				---@cast window winit-x11.Window
				window.mapped = false
				setVisible(window, false)
			end
			callback({ window = window, name = "unmap" }, handler)
		end,

		-- A window manager can iconify a window and leave it mapped, in which case no unmap
		-- says so: what says it is one of the window's state properties being written.
		[PROPERTY_NOTIFY] = function(window)
			if not window then return end
			---@cast window winit-x11.Window

			local property = tonumber(ffi.cast("struct winit_x11_property_event *", event).atom)
			if property == netWmStateAtom or property == wmStateAtom then
				refreshVisible(window)
			end
		end,

		[x11.EventType.CreateNotify] = function(window)
			callback({ window = window, name = "create" }, handler)
		end,

		[x11.EventType.ButtonPress] = function(window)
			local button = event.xbutton.button
			if button == 4 then
				callback({ window = window, name = "mouseScroll", dx = 0, dy = -1 }, handler)
			elseif button == 5 then
				callback({ window = window, name = "mouseScroll", dx = 0, dy = 1 }, handler)
			elseif button == 6 then
				callback({ window = window, name = "mouseScroll", dx = -1, dy = 0 }, handler)
			elseif button == 7 then
				callback({ window = window, name = "mouseScroll", dx = 1, dy = 0 }, handler)
			else
				callback({
					window = window,
					name = "mousePress",
					x = event.xbutton.x,
					y = event.xbutton.y,
					button = button
				}, handler)
			end
		end,

		[x11.EventType.ButtonRelease] = function(window)
			local button = event.xbutton.button
			if button < 4 or button > 7 then
				callback({
					window = window,
					name = "mouseRelease",
					x = event.xbutton.x,
					y = event.xbutton.y,
					button = button
				}, handler)
			end
		end,

		[x11.EventType.FocusIn] = function(window)
			callback({ window = window, name = "focusIn" }, handler)
		end,

		[x11.EventType.FocusOut] = function(window)
			held = {}
			callback({ window = window, name = "focusOut" }, handler)
		end,

		[x11.EventType.KeyPress] = function(window)
			local char = x11.lookupString(event)
			local baseKeysym = assert(tonumber(x11.keycodeToKeysym(display, event.xkey.keycode, 0)))
			local key = keysymToKey(baseKeysym, char)
			if key then
				local repeated = held[event.xkey.keycode] ~= nil
				held[event.xkey.keycode] = key

				callback({
					window = window,
					name = "keyPress",
					key = key,
					modifiers = keyModifiers(event.xkey.state),
					-- safety: the text a key types is not the key: a game that reads what a
					-- player wrote needs the letter the way the keyboard produced it, with
					-- its case, while a game that reads a binding wants the key itself
					text = char ~= "" and char or nil,
					repeated = repeated and true or nil
				}, handler)
			end
		end,

		[x11.EventType.KeyRelease] = function(window)
			local baseKeysym = assert(tonumber(x11.keycodeToKeysym(display, event.xkey.keycode, 0)))
			local baseChar = (baseKeysym >= 0x20 and baseKeysym <= 0x7e) and string.char(assert(baseKeysym)) or ""
			local key = held[event.xkey.keycode] or keysymToKey(baseKeysym, baseChar)

			local repeated = false
			if x11.pending(display) > 0 then
				x11.peekEvent(display, tempEvent)

				repeated = tempEvent.type == x11.EventType.KeyPress
					and tempEvent.xkey.keycode == event.xkey.keycode
					and tempEvent.xkey.time == event.xkey.time
			end

			if not repeated then
				held[event.xkey.keycode] = nil
			end

			if key then
				callback({
					window = window,
					name = "keyRelease",
					key = key,
					modifiers = keyModifiers(event.xkey.state),
					repeated = repeated and true or nil
				}, handler)
			end
		end,

		[x11.EventType.GenericEvent] = function(_window)
			if not x11.getEventData(display, event.xcookie) then return end

			if event.xcookie.evtype ~= xi2.EventType.RawMotion then
				x11.freeEventData(display, event.xcookie)
				return
			end

			local dx, dy = readRawMotion(event.xcookie)
			x11.freeEventData(display, event.xcookie)

			dx, dy = coalesceMouseMotion(dx, dy)
			callback({ name = "mouseMotion", dx = dx, dy = dy }, handler)
		end
	}

	local function processEvent()
		local window = self.windows[tonumber(event.xany.window)]

		local evtTypeHandler = Handlers[event.type]
		if not evtTypeHandler then
			print("Warning: Unhandled X11 event type: " .. tostring(event.type))
		else
			evtTypeHandler(window)
		end
	end

	local redrawEvent = { name = "redraw" }
	local aboutToWaitEvent = { name = "aboutToWait" }

	--- The event to hand to the handlers: one the loop kept back while something was waiting on
	--- another program, or the next one the server has -- and whether there was one at all.
	---@param block boolean # whether to wait on the server when it has nothing for us yet
	---@param coalesce boolean # whether a motion may swallow the motions queued behind it
	---@return boolean
	local function nextEvent(block, coalesce)
		local kept = self.stashedEvents
		if #kept > 0 then
			ffi.copy(event, assert(table.remove(kept, 1)), assert(ffi.sizeof(event)))
			return true
		end

		if not block and x11.pending(display) <= 0 then
			return false
		end

		x11.nextEvent(display, event)

		if coalesce and event.type == x11.EventType.MotionNotify then
			coalesceMouse()
		end

		return true
	end

	while isActive do
		if currentMode == "poll" then
			while nextEvent(false, true) do
				processEvent()
			end
		elseif timeout then
			-- Woken by an event or by the time it was asked to be back at, and the iteration goes on
			-- either way: what is left of it is the redraw that is owed, and telling the app that
			-- the loop is about to wait again.
			local milliseconds = math.ceil(timeout * 1000)

			timeout = nil

			-- The socket being readable is not the same as there being an event: a reply the
			-- library has not read yet is data too, and asking it for what it has is what takes it
			-- -- which is also what keeps the next wait from being woken by the same data again.
			--
			-- What was kept back is not waited for at all: it is already here, and waiting on a
			-- socket that has nothing for us would be waiting for a deadline that has nothing to
			-- do with it.
			local readable = #self.stashedEvents > 0
				or wait.readable(display, milliseconds > 0 and milliseconds or 0)

			if readable and nextEvent(false, true) then
				processEvent()
			end
		else
			-- Nothing kept back leaves this waiting on the server, which is what this mode is for
			nextEvent(true, true)
			processEvent()
		end

		for _, window in pairs(self.windows) do
			-- A window that is not on screen is not drawn: a frame into a surface the
			-- compositor has taken away is one the render path waits on and never comes
			-- back from. What was asked for stays asked, and is drawn once it is back.
			if window.shouldRedraw and window.visible ~= false then
				window.shouldRedraw = false
				redrawEvent.window = window
				callback(redrawEvent, handler)
				window:acknowledgeSync()
			end
		end

		callback(aboutToWaitEvent, handler)
	end
end

return { Window = X11Window, EventLoop = X11EventLoop, Clipboard = Clipboard,
	FileDialog = FileDialog }
