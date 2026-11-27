local ffi = require("ffi")
local bit = require("bit")
local android = require("androidapi")
local touch = require("winit-android.touch")

local constants = android.Constants
local jni = android.jni
local lib = android.libandroid
local app = android.app()

if not android.isAndroid or app == nil or lib == nil then
	error("winit-android requires androidapi inside an Android app host")
end

local appCommand = constants.AppCommand
local inputType = constants.InputType
local motionAction = constants.MotionAction
local keyAction = constants.KeyAction
local source = constants.Source
local toolType = constants.ToolType
local meta = constants.Meta
local button = constants.Button
local axis = constants.Axis

local KEYCODE_BACK = constants.KeyCode.back

--- Keys the system also handles while the app has focus: the volume keys open the volume panel
--- and change the stream. They are still reported to the program from the queue.
---@type table<number, boolean>
local volumeKeys = {
	[24] = true, -- volume up
	[25] = true, -- volume down
	[164] = true, -- volume mute
}

---@type table<number, winit.KeyName>
local keyNames = {
	[4] = "back",
	[7] = "0", [8] = "1", [9] = "2", [10] = "3", [11] = "4",
	[12] = "5", [13] = "6", [14] = "7", [15] = "8", [16] = "9",
	[19] = "up", [20] = "down", [21] = "left", [22] = "right",
	[29] = "a", [30] = "b", [31] = "c", [32] = "d", [33] = "e",
	[34] = "f", [35] = "g", [36] = "h", [37] = "i", [38] = "j",
	[39] = "k", [40] = "l", [41] = "m", [42] = "n", [43] = "o",
	[44] = "p", [45] = "q", [46] = "r", [47] = "s", [48] = "t",
	[49] = "u", [50] = "v", [51] = "w", [52] = "x", [53] = "y",
	[54] = "z",
	[55] = ",", [56] = ".",
	[57] = "left-alt", [58] = "right-alt",
	[59] = "left-shift", [60] = "right-shift",
	[61] = "tab", [62] = "space", [66] = "return", [67] = "backspace",
	[68] = "`", [69] = "-", [70] = "=", [71] = "[", [72] = "]",
	[73] = "\\", [74] = ";", [75] = "'", [76] = "/",
	[92] = "page-up", [93] = "page-down",
	[111] = "escape", [112] = "delete",
	[113] = "left-ctrl", [114] = "right-ctrl",
	[115] = "caps-lock",
	[117] = "left-super", [118] = "right-super",
	[122] = "home", [123] = "end", [124] = "insert",
	[131] = "f1", [132] = "f2", [133] = "f3", [134] = "f4",
	[135] = "f5", [136] = "f6", [137] = "f7", [138] = "f8",
	[139] = "f9", [140] = "f10", [141] = "f11", [142] = "f12",
	[160] = "return", -- numpad enter
}

---@type table<number, winit.MediaAction>
local mediaKeys = {
	[79] = "playPause", -- headset hook
	[85] = "playPause",
	[86] = "stop",
	[87] = "next",
	[88] = "previous",
	[126] = "play",
	[127] = "pause",
}

---@param state number
---@return winit.KeyModifiers
local function modifiersOf(state)
	return {
		shift = bit.band(state, meta.shift) ~= 0,
		lock = bit.band(state, meta.capsLock) ~= 0,
		ctrl = bit.band(state, meta.ctrl) ~= 0,
		alt = bit.band(state, meta.alt) ~= 0,
		super = bit.band(state, meta.super) ~= 0,
	}
end

--- winit numbers buttons as X11 does: 1 left, 2 middle, 3 right, 8 back, 9 forward.
---@type { [1]: number, [2]: number }[]
local buttonBits = {
	{ button.primary, 1 },
	{ button.tertiary, 2 },
	{ button.secondary, 3 },
	{ button.back, 8 },
	{ button.forward, 9 },
}

---@param code number
---@return winit.KeyName
local function keyNameOf(code)
	return keyNames[code] or ("keycode-" .. tostring(code))
end

--- What a key types, filtered to text: control characters (tab, return, backspace) are keys, not
--- text, as on the other backends.
---@param cp number?
---@return string?
local function textOf(cp)
	if cp == nil or cp < 0x20 or cp == 0x7f then
		return nil
	end
	return android.jni.utf8(cp)
end

-- ── Input queue ──────────────────────────────────────────────────────────────
-- Android hands input to a C callback that must answer at once whether it handled the event,
-- and the event is only valid during the call. Everything a handler needs is copied out into a
-- plain table and queued; the loop turns the queue into winit events after the looper returns.
-- Nothing that can raise runs inside the callback: an error there would unwind through C.

local events = {}
local eventHead = 1
local eventTail = 0

---@param event table
local function queueEvent(event)
	eventTail = eventTail + 1
	events[eventTail] = event
end

---@return table?
local function nextEvent()
	if eventHead > eventTail then
		return nil
	end
	local event = events[eventHead]
	events[eventHead] = nil
	eventHead = eventHead + 1
	if eventHead > eventTail then
		eventHead, eventTail = 1, 0
	end
	return event
end

---@param command number
local function onAppCmd(_, command)
	queueEvent({ command = command })
end

-- Whether the program takes the back key (and the back gesture, which Android reports as one) for
-- itself: a program with pages of its own goes back through them, and leaves when it decides to.
local backHandled = false

---@param input androidapi.ffi.InputEvent
---@return number
local function onInput(_, input)
	local kind = lib.AInputEvent_getType(input)

	if kind == inputType.motion then
		local rawAction = lib.AMotionEvent_getAction(input)
		local count = tonumber(lib.AMotionEvent_getPointerCount(input))
		local pointers = {}
		for i = 0, count - 1 do
			pointers[i + 1] = {
				id = lib.AMotionEvent_getPointerId(input, i),
				x = lib.AMotionEvent_getX(input, i),
				y = lib.AMotionEvent_getY(input, i),
				pressure = lib.AMotionEvent_getPressure(input, i),
				tool = lib.AMotionEvent_getToolType(input, i),
			}
		end
		queueEvent({
			input = "motion",
			action = bit.band(rawAction, motionAction.mask),
			index = bit.rshift(bit.band(rawAction, motionAction.pointerIndexMask), motionAction.pointerIndexShift),
			source = lib.AInputEvent_getSource(input),
			buttons = lib.AMotionEvent_getButtonState(input),
			pointers = pointers,
			dx = lib.AMotionEvent_getAxisValue(input, axis.hscroll, 0),
			dy = lib.AMotionEvent_getAxisValue(input, axis.vscroll, 0),
		})
		return 1
	end

	if kind == inputType.key then
		local keyCode = lib.AKeyEvent_getKeyCode(input)
		queueEvent({
			input = "key",
			action = lib.AKeyEvent_getAction(input),
			keyCode = keyCode,
			metaState = lib.AKeyEvent_getMetaState(input),
			repeatCount = lib.AKeyEvent_getRepeatCount(input),
			deviceId = lib.AInputEvent_getDeviceId(input),
		})
		-- Back is reported and then left to the system, which finishes the activity -- a program
		-- hears about that as windowClose -- unless the program said it handles back itself (see
		-- `setBackHandled`). The volume keys are left to the system too, so the volume panel shows
		-- and the stream changes, but the program still hears them from the queue. Every other key
		-- is the program's.
		if keyCode == KEYCODE_BACK then
			return backHandled and 1 or 0
		end
		if volumeKeys[keyCode] then
			return 0
		end
		return 1
	end

	return 0
end

-- The callbacks live as long as the Lua state does: the glue calls them until android_main
-- returns, so they are never freed.
local appCmdCallback = ffi.cast("void (*)(struct androidapi_app*, int32_t)", onAppCmd)
local inputCallback = ffi.cast("int32_t (*)(struct androidapi_app*, void*)", onInput)
app.onAppCmd = appCmdCallback
app.onInputEvent = inputCallback

-- ── Window ───────────────────────────────────────────────────────────────────

--- An Android app has one window, the activity's, and it is full screen: the size a program
--- asks for is a placeholder until the system hands over the real surface. That surface comes
--- and goes as the app is shown and hidden -- `nativeWindow` is nil while it is gone, between
--- an `unmap` and the next `map`.
---@class winit-android.Window: winit.Window
---@field nativeWindow androidapi.ffi.NativeWindow?
---@field textInput boolean
---@field textInputHandler (fun(enabled: boolean): boolean?)? # A program's own editor: see `setTextInputHandler`
---@field eventLoop winit-android.EventLoop # The loop that made it, which is where a touch it claims is classified
local AndroidWindow = {}
AndroidWindow.__index = AndroidWindow

---@param eventLoop winit-android.EventLoop
---@param width number
---@param height number
---@return winit-android.Window
function AndroidWindow.new(eventLoop, width, height)
	local id = eventLoop.nextWindowId
	eventLoop.nextWindowId = id + 1

	return setmetatable({
		id = id,
		width = width,
		height = height,
		shouldRedraw = false,
		visible = false,
		textInput = false,
		nativeWindow = nil,
		eventLoop = eventLoop,
	}, AndroidWindow)
end

---@param title string
function AndroidWindow:setTitle(title)
	-- The Activity label is fixed by the manifest; NativeActivity does not expose a title.
	android.log("debug", "winit-android: setTitle is a manifest property: " .. tostring(title))
end

function AndroidWindow:setCursor(shape)
	android.log("debug", "winit-android: setCursor is unsupported: " .. tostring(shape))
end

function AndroidWindow:resetCursor()
end

---@param mode winit.CursorGrab
function AndroidWindow:setCursorGrab(mode)
	android.log("debug", "winit-android: setCursorGrab is unsupported: " .. tostring(mode))
end

--- A program that brings its own editor -- an Android view with an InputConnection, so the
--- keyboard can suggest words and compose them -- takes the keyboard over with this. The handler
--- is asked before the window's own keyboard is shown or hidden, and answering true means the
--- program has it: the window then does nothing itself. Answering nothing falls back to the
--- window, so a backend that cannot make an editor keeps what it had.
---@param handler fun(enabled: boolean): boolean?
function AndroidWindow:setTextInputHandler(handler)
	self.textInputHandler = handler
end

--- Show or hide the on-screen keyboard. What it types arrives as keyPress events carrying
--- `text`, as a hardware keyboard's keys do, unless the program took the keyboard over with
--- `setTextInputHandler`. The keyboard is shown again when the window comes back from the
--- background, as long as text input is still on.
---@param enabled boolean
function AndroidWindow:setTextInput(enabled)
	self.textInput = enabled
	local handler = self.textInputHandler
	if handler ~= nil and handler(enabled) == true then return end
	if self.nativeWindow ~= nil or not enabled then
		android.showKeyboard(enabled)
	end
end

--- Whether back is the program's. Off, a back press finishes the activity, as Android does for an
--- app with nothing to go back to; on, it arrives as a `keyPress` of "back" and nothing else
--- happens, so the program goes back a page itself and leaves with `handler:exit()`.
---@param handled boolean
function AndroidWindow:setBackHandled(handled)
	backHandled = handled
end

--- A box under the finger takes the touch for itself. The program says so while the touchStart is
--- being delivered, if what the finger went down on is something that drags -- a row a swipe
--- removes, a list a held row is moved in -- and it is then the box's gesture rather than a guess
--- from the distance moved:
---
---  * the pointer is pressed where the finger went down, so a hold is that press staying down
---    rather than the right button's context menu, and a long press on the box is never a menu;
---  * a sideways move is a drag of the box, as it is for any touch;
---  * an up or down move before the finger has rested `hold` seconds is still a scroll, and after
---    that it is the box's own move -- which is what makes hold-then-drag a reorder rather than a
---    scroll that never comes back.
---
--- `hold` is how long the finger must rest, in seconds: the box's gesture times its own hold
--- against the same press, so it should be that number. A box that does not capture is a touch
--- nothing claims, which keeps the platform's behaviour: long press is a context menu, and up and
--- down scrolls.
---
--- Returns whether there was an undecided touch to take.
---@param hold number?
---@param id number? # The finger that claimed it, where the program names one
---@return boolean
function AndroidWindow:captureTouch(hold, id)
	return self.eventLoop.touch:claim(hold, id)
end

local currentRate, invalidateRate -- Forward declarations: defined with the clock, below.

--- The rate the display is running at now, in hertz. That is not the fastest rate the display
--- has a mode for: the loop asks for that one while the user is touching the window and for a
--- moment after, but a phone may keep its panel at 60 Hz regardless, and pacing has to follow
--- what the panel does rather than what was asked of it. The read is kept for a moment, and
--- taken again once a request has had time to settle or the display has changed, so a window
--- that asks every frame costs no JNI call a frame.
---@return number?
function AndroidWindow:refreshRate()
	return currentRate()
end

function AndroidWindow:destroy()
	self.nativeWindow = nil
	android.finish()
end

-- ── Clipboard ────────────────────────────────────────────────────────────────

---@class winit-android.Clipboard: winit.Clipboard
local AndroidClipboard = {}
AndroidClipboard.__index = AndroidClipboard

---@param _ winit.EventLoop?
function AndroidClipboard.new(_)
	return setmetatable({}, AndroidClipboard)
end

---@param text string
function AndroidClipboard:setText(text)
	android.setClipboardText(text)
end

---@return string?
function AndroidClipboard:getText()
	local text = android.getClipboardText()
	if text == "" then return nil end
	return text
end

function AndroidClipboard:clear()
	android.setClipboardText(nil)
end

-- ── Event loop ───────────────────────────────────────────────────────────────

---@class winit-android.EventLoop: winit.EventLoop
---@field windows table<string, winit-android.Window>
---@field nextWindowId number
---@field isActive boolean
---@field mode winit.EventLoopMode
---@field timeout number?
---@field handler winit.EventManager
---@field touch winit-android.Touch # The finger a mouse-only program hears, and the list still coasting after one
---@field density number # Physical pixels per density-independent pixel, read when the loop starts
---@field fast boolean? # Whether the display was last asked for its fastest rate
---@field fastUntil number? # When it is given its own choice of rate back, on the monotonic clock
---@field buttons number # Mouse buttons held, as Android's button-state bits
local AndroidEventLoop = {}
AndroidEventLoop.__index = AndroidEventLoop

---@return winit-android.EventLoop
function AndroidEventLoop.new()
	local self = setmetatable({
		windows = {},
		nextWindowId = 1,
		isActive = true,
		mode = "poll",
		timeout = nil,
		touch = touch.new(),
		density = 1,
		buttons = 0,
	}, AndroidEventLoop)

	---@type winit.EventManager
	self.handler = {
		exit = function()
			self.isActive = false
		end,
		close = function(_, window)
			self:close(window)
		end,
		requestRedraw = function(_, window)
			window.shouldRedraw = true
		end,
		setMode = function(_, mode)
			self.mode = mode
		end,
		setTimeout = function(_, seconds)
			self.timeout = seconds
		end,
	}

	return self
end

---@param window winit-android.Window
function AndroidEventLoop:register(window)
	self.windows[tostring(window.id)] = window
end

---@param window winit-android.Window
function AndroidEventLoop:close(window)
	self.windows[tostring(window.id)] = nil
	window:destroy()
end

---@return winit-android.Window?
local function firstWindow(self)
	for _, window in pairs(self.windows) do
		return window
	end
end

---@param self winit-android.EventLoop
---@param event table
---@param callback winit.EventHandler
local function deliver(self, event, callback)
	if event.window == nil then
		event.window = firstWindow(self)
	end
	callback(event, self.handler)
end

---@param self winit-android.EventLoop
---@param window winit-android.Window
local function refreshSize(self, window)
	local width, height = android.windowSize()
	if width and width > 0 then window.width = width end
	if height and height > 0 then window.height = height end
end

---@param self winit-android.EventLoop
---@param event table
---@param window winit-android.Window
---@param callback winit.EventHandler
local function handleCommand(self, event, window, callback)
	local command = event.command

	if command == appCommand.initWindow then
		window.nativeWindow = app.window
		window.visible = true
		-- A rate asked for belongs to the surface it was asked on, and this one is new: the rate
		-- the last one ran at says nothing about this one.
		self.fast = nil
		invalidateRate()
		refreshSize(self, window)
		window.shouldRedraw = true

		-- A window exists to a program only once Android has made its native surface: a GPU
		-- surface needs the ANativeWindow, so `create` waits for this, the first time.
		if not self.created then
			self.created = true
			for _, made in pairs(self.windows) do
				deliver(self, { name = "create", window = made }, callback)
			end
		end

		deliver(self, { name = "map", window = window }, callback)
		if window.textInput then
			local handler = window.textInputHandler
			if handler == nil or handler(true) ~= true then android.showKeyboard(true) end
		end
	elseif command == appCommand.termWindow then
		-- The surface is destroyed when this returns, so the program must let go of it now; the
		-- one the next initWindow brings is a new surface.
		deliver(self, { name = "unmap", window = window, surfaceLost = true }, callback)
		window.nativeWindow = nil
		window.visible = false
		-- A rate asked for belonged to the surface that is going: the one that comes next is
		-- not held at the fastest rate for what a touch on the old one asked for.
		self.fastUntil = nil
	elseif command == appCommand.windowResized or command == appCommand.configChanged
		or command == appCommand.contentRectChanged then
		local width, height = window.width, window.height
		if command == appCommand.configChanged then
			-- A rotation, another display chosen, or the system's own rate changed: the rate the
			-- display was running at is not the one to keep pacing against.
			invalidateRate()
		end
		refreshSize(self, window)
		window.shouldRedraw = true
		if window.width ~= width or window.height ~= height then
			deliver(self, { name = "resize", window = window }, callback)
		end
	elseif command == appCommand.windowRedrawNeeded then
		window.shouldRedraw = true
	elseif command == appCommand.gainedFocus then
		deliver(self, { name = "focusIn", window = window }, callback)
	elseif command == appCommand.lostFocus then
		deliver(self, { name = "focusOut", window = window }, callback)
	elseif command == appCommand.pause then
		-- A paused activity can still be on screen -- split-screen, a picture-in-picture window --
		-- so it is not hidden here; `stop` is the system saying the user no longer sees it.
		deliver(self, { name = "minimize", window = window }, callback)
	elseif command == appCommand.stop then
		window.visible = false
	elseif command == appCommand.start or command == appCommand.resume then
		-- Back in front of the user: with the surface it kept if the system did not take it away,
		-- and one to come from `initWindow` otherwise. A window that was not drawn while it was
		-- hidden owes the frame that shows it again.
		local wasHidden = window.visible == false
		window.visible = window.nativeWindow ~= nil
		if window.visible then
			window.shouldRedraw = true
		end
		-- `start` and `resume` are both the app coming back; which one the system sent says
		-- nothing about what the program has to do about it, so both say the window is shown
		-- again. See the visibility edge app.run watches.
		if window.visible and (wasHidden or command == appCommand.resume) then
			deliver(self, { name = "restore", window = window }, callback)
		end
	elseif command == appCommand.destroy then
		deliver(self, { name = "windowClose", window = window }, callback)
		self.isActive = false
	end
end

-- How long the display is kept at its fastest rate after the last touch or fling.
local FAST_HOLD = 2

pcall(ffi.cdef, "int32_t AConfiguration_getDensity(void *config);")
-- Under names of their own, so another module's declaration of the libc call cannot collide.
ffi.cdef [[
	struct winit_android_timespec { long tv_sec; long tv_nsec; };
	int winit_android_clock_gettime(int clock, struct winit_android_timespec *ts) __asm__("clock_gettime");
]]

local CLOCK_MONOTONIC = 1
local timespec = ffi.new("struct winit_android_timespec")

---@return number seconds # On the monotonic clock
local function now()
	ffi.C.winit_android_clock_gettime(CLOCK_MONOTONIC, timespec)
	return tonumber(timespec.tv_sec) + tonumber(timespec.tv_nsec) / 1e9
end

--- Physical pixels per density-independent pixel.
---@return number
local function densityScale()
	local ok, dpi = pcall(function() return lib.AConfiguration_getDensity(app.config) end)
	dpi = ok and tonumber(dpi) or 0
	return dpi > 0 and dpi / 160 or 1
end

-- How long a rate read is trusted for, and how long a display is given to take a rate it has just
-- been asked for before it is read back. Together they keep the read to a handful a second even
-- for a window that asks for its rate every frame, and let a panel that does switch be followed
-- a fraction of a second after the request rather than a cache lifetime later.
local RATE_TRUST = 0.5
local RATE_SETTLE = 0.25
-- The last rate read and when it was read, and when a rate request has settled enough to read
-- again: until then the last read stands.
---@type number?
local rateHz
---@type number?
local rateAt
---@type number?
local rateDue

--- The display's rate as the system reports it, in hertz, or nil where the call failed.
---@return number?
local function readRate()
	local activity = app.activity.clazz
	local hz = jni.frame(function()
		local manager = jni.call(activity, "android/app/Activity", "getWindowManager",
			"()Landroid/view/WindowManager;", "object")
		local display = jni.call(manager, "android/view/WindowManager", "getDefaultDisplay",
			"()Landroid/view/Display;", "object")
		return jni.call(display, "android/view/Display", "getRefreshRate", "()F", "float")
	end, 8)
	return tonumber(hz)
end

--- Forget the rate that was read, so the next look sees the display as it is after a change.
---@param settle number? # Seconds to leave the last read standing while the display takes a rate
function invalidateRate(settle)
	rateAt = nil
	rateDue = settle ~= nil and (now() + settle) or nil
end

--- The rate the display is running at now: read back through JNI rather than assumed from what was
--- asked for, and kept between reads. The fastest rate the display has a mode for is the fallback
--- where the system cannot say.
---@return number?
function currentRate()
	local at = now()
	if rateDue ~= nil then
		-- A request is still settling: the rate read before it stands, where there is one. Where
		-- there is none, a start-up look is not a stale one and waiting it out would leave the
		-- first frames paced as if the panel ran at its fastest mode.
		if at < rateDue and rateHz ~= nil then return rateHz end
		rateDue = nil
	end
	if rateHz ~= nil and rateAt ~= nil and at - rateAt < RATE_TRUST then
		return rateHz
	end
	local hz = readRate()
	if hz ~= nil and hz > 0 then
		rateHz = hz
	end
	-- A failed read is not retried on every frame either: what is known stands for a while.
	rateAt = at
	return rateHz or android.maxRefreshRate()
end

--- What Android's motion action is, as the touch module names it.
---@param action number
---@return "down" | "move" | "up" | "cancel"?
local function touchAction(action)
	if action == motionAction.down or action == motionAction.pointerDown then return "down" end
	if action == motionAction.move then return "move" end
	if action == motionAction.up or action == motionAction.pointerUp then return "up" end
	if action == motionAction.cancel then return "cancel" end
end

--- A touch comes to its events in the touch module, which is what an element under the finger
--- claims while the start is delivered: what is left here is handing them the window they belong
--- to.
---@param self winit-android.EventLoop
---@param event table
---@param emit fun(event: table)
local function handleTouch(self, event, emit)
	local action = touchAction(event.action)

	if action ~= nil then
		self.touch:handle(action, event.pointers, event.index, now(), self.density, emit)
	end
end

---@param self winit-android.EventLoop
---@param event table
---@param window winit-android.Window
---@param callback winit.EventHandler
local function handleMouse(self, event, window, callback)
	local action = event.action
	local p = event.pointers[1]
	if p == nil then return end

	if action == motionAction.move or action == motionAction.hoverMove then
		deliver(self, { name = "mouseMove", window = window, x = p.x, y = p.y }, callback)
	elseif action == motionAction.scroll then
		-- Android's vertical axis is positive away from the user; winit's dy is positive down.
		deliver(self, { name = "mouseScroll", window = window, dx = event.dx, dy = -event.dy }, callback)
	end

	-- Buttons are reported as a state, on whichever action changed it: compare with what was held.
	-- Some input stacks (emulators, remote desktops) send a bare down/up with no state; that is
	-- the primary button.
	local held = event.buttons
	if held == 0 and action == motionAction.down then held = button.primary end
	if held ~= self.buttons then
		for _, pair in ipairs(buttonBits) do
			local mask, number = pair[1], pair[2]
			local was, is = bit.band(self.buttons, mask) ~= 0, bit.band(held, mask) ~= 0
			if is and not was then
				deliver(self, { name = "mousePress", window = window, x = p.x, y = p.y, button = number }, callback)
			elseif was and not is then
				deliver(self, { name = "mouseRelease", window = window, x = p.x, y = p.y, button = number }, callback)
			end
		end
		self.buttons = held
	end
end

---@param self winit-android.EventLoop
---@param event table
---@param window winit-android.Window
---@param callback winit.EventHandler
local function handleKey(self, event, window, callback)
	local media = mediaKeys[event.keyCode]
	if media then
		if event.action == keyAction.down and event.repeatCount == 0 then
			deliver(self, { name = "mediaKey", window = window, action = media }, callback)
		end
		return
	end

	local key = keyNameOf(event.keyCode)
	local modifiers = modifiersOf(event.metaState)

	if event.action == keyAction.down then
		local ok, cp = pcall(android.keyCharacter, event.deviceId, event.keyCode, event.metaState)
		if not ok then
			android.log("warn", "winit-android: " .. tostring(cp))
			cp = nil
		end
		deliver(self, {
			name = "keyPress",
			window = window,
			key = key,
			modifiers = modifiers,
			text = textOf(cp),
			repeated = event.repeatCount > 0,
		}, callback)
	elseif event.action == keyAction.up then
		deliver(self, {
			name = "keyRelease",
			window = window,
			key = key,
			modifiers = modifiers,
			repeated = false,
		}, callback)
	end
end

-- ALooper's wait is a signed 32-bit count of milliseconds. A program asking to sleep longer
-- than that is clamped rather than wrapped round to a negative timeout, which would be a wait
-- with no end to it.
local MAX_WAIT_MS = 0x7fffffff

---@param callback winit.EventHandler
function AndroidEventLoop:run(callback)
	self.isActive = true
	self.density = densityScale()

	-- One table each, reused by every pass: a handler reads an event and does not keep it.
	local redrawEvent = { name = "redraw" }
	local aboutToWaitEvent = { name = "aboutToWait" }

	-- What the touch module makes carries no window: the finger is on the loop's window, which
	-- `deliver` fills in. One closure does it for every event of the run rather than one an event.
	local emit = function(event)
		deliver(self, event, callback)
	end

	while self.isActive do
		-- A deadline is what the program asked of the one wait that follows it, and it is taken
		-- here and cleared: a program that stops asking gets a wait with no end to it again,
		-- rather than waking for a deadline nobody wants any more. See `winit.EventManager`.
		local deadline = self.timeout
		self.timeout = nil
		local timeout = 0
		-- Nothing to draw into while the surface is gone: sleep until the system brings it back,
		-- rather than spinning a program that asked for redraws.
		local window = firstWindow(self)
		if self.mode == "wait" or (window ~= nil and window.nativeWindow == nil) then
			if deadline ~= nil then
				-- Rounded up so a wait never comes back before its deadline and asks again for
				-- the fraction of a millisecond that was left, which is a wakeup for nothing.
				timeout = math.max(0, math.ceil(deadline * 1000))
				if timeout > MAX_WAIT_MS then timeout = MAX_WAIT_MS end
			else
				-- No end to it: woken by the next event, which is what an idle window is.
				timeout = -1
			end
		end
		-- A coasting scroll is a step a frame: the loop does not wait while one is going, and the
		-- frame each pass draws -- whose present waits for the display -- is what paces it. Nor does
		-- it sleep past giving the display's rate back once the screen has been still long enough.
		local fling = self.touch.fling
		if fling ~= nil and window ~= nil and window.nativeWindow ~= nil then
			-- A step whose frame came out the same is not presented, and nothing waits for the
			-- display then: the next step is held to a frame's time after the last one, so a list
			-- coasting against its end does not spin the loop. A frame's time is the display's,
			-- read back: asking for the fastest rate does not make a panel that stays at 60 run
			-- one frame every 11 ms.
			local frame = 1 / (currentRate() or 60)
			local left = (fling.steppedAt or 0) + frame - now()
			local held = left > 0 and math.ceil(left * 1000) or 0
			-- A deadline the program asked for that falls inside the frame is taken as it is: a
			-- step that is not due yet is one the pass after it takes.
			if timeout <= 0 or timeout > held then timeout = held end
		elseif self.fast and self.fastUntil ~= nil then
			local left = math.max(0, math.ceil((self.fastUntil - now()) * 1000))
			if timeout < 0 or timeout > left then timeout = left end
		end
		-- A finger resting on the screen is woken for when it becomes a long press.
		local pressing = self.touch:longPressIn(now())
		if pressing ~= nil then
			local left = math.max(0, math.ceil(pressing * 1000))
			if timeout < 0 or timeout > left then timeout = left end
		end

		-- Drain whatever else is ready without waiting again, so a burst of input is handled in
		-- one pass rather than one event per frame. Only a wait that ran out is known to have
		-- nothing ready, so only that one skips the second look: an idle loop costs one call a
		-- wakeup rather than two, and what a woken one left queued is still taken here.
		local result = android.pollOnce(timeout)
		if result ~= android.POLL_TIMEOUT and result ~= android.POLL_ERROR then
			while android.pollOnce(0) >= 0 do end
		end

		for event in nextEvent do
			window = firstWindow(self)
			if window ~= nil then
				if event.command ~= nil then
					handleCommand(self, event, window, callback)
				elseif event.input == "motion" then
					local isTouch = bit.band(event.source, source.touchscreen) == source.touchscreen
						and (event.pointers[1] == nil or event.pointers[1].tool ~= toolType.mouse)
					if isTouch then
						handleTouch(self, event, emit)
					else
						handleMouse(self, event, window, callback)
					end
				elseif event.input == "key" then
					handleKey(self, event, window, callback)
				end
			elseif event.command == appCommand.destroy then
				self.isActive = false
			end
		end

		window = firstWindow(self)
		if window ~= nil and window.nativeWindow ~= nil then
			self.touch:checkLongPress(now(), emit)

			-- Exactly one step of a fling for each frame, taken just before it is drawn and drawn
			-- whatever the program's own frame pacing says: a step taken with no frame after it is
			-- motion that shows up a frame late, two steps in one frame -- a list that jerks.
			-- A pass woken early -- by an event that came in between frames -- is not a frame of
			-- the fling's own, and moves nothing.
			local fling = self.touch.fling
			local frame = 1 / (currentRate() or 60)
			if fling ~= nil and now() - (fling.steppedAt or 0) >= frame * 0.75 then
				self.touch:stepFling(now(), self.density, emit)
				if self.touch.fling ~= nil then self.touch.fling.steppedAt = now() end
				window.shouldRedraw = true
			end

			-- A finger on the screen, or a list still coasting from one, is motion the eye follows:
			-- the display is asked for its fastest rate then, and for a moment after, and given its
			-- own choice back once nothing has moved for that long -- a still screen held at the
			-- fastest rate is battery spent on nothing.
			local at = now()
			if self.touch:active() then
				self.fastUntil = at + FAST_HOLD
			end
			local fast = self.fastUntil ~= nil and at < self.fastUntil
			if fast ~= self.fast then
				self.fast = fast
				android.setFrameRate(fast and (android.maxRefreshRate() or 0) or 0)
				-- What the display does with the request is the system's to decide, so the rate
				-- is read back rather than taken from what was asked: after the display has had
				-- a moment to switch.
				invalidateRate(RATE_SETTLE)
			end
		end

		-- The same two tables every pass: a frame of a window that is playing would otherwise
		-- make a table for the redraw and another for going about waiting, at the rate of the
		-- display, for nothing. Handlers read them and do not keep them.
		for _, w in pairs(self.windows) do
			if w.shouldRedraw and w.nativeWindow ~= nil then
				w.shouldRedraw = false
				redrawEvent.window = w
				callback(redrawEvent, self.handler)
			end
		end

		aboutToWaitEvent.window = firstWindow(self)
		callback(aboutToWaitEvent, self.handler)
	end
end

return {
	Window = AndroidWindow,
	EventLoop = AndroidEventLoop,
	Clipboard = AndroidClipboard,
}
