local ffi = require("ffi")
local bit = require("bit")
local android = require("androidapi")

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

--- Show or hide the on-screen keyboard. What it types arrives as keyPress events carrying
--- `text`, as a hardware keyboard's keys do. The keyboard is shown again when the window comes
--- back from the background, as long as text input is still on.
---@param enabled boolean
function AndroidWindow:setTextInput(enabled)
	self.textInput = enabled
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
---@field gesture winit-android.Gesture? # The finger a mouse-only program hears, while it is down
---@field fling { velocity: number, start: number, travelled: number, x: number, y: number, steppedAt: number? }? # A scroll still coasting after the finger left: how fast it was let go, when, how far it has gone since, and when it last moved
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
		gesture = nil,
		fling = nil,
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
		if window.textInput then android.showKeyboard(true) end
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
		window.visible = window.nativeWindow ~= nil
		if window.visible then
			window.shouldRedraw = true
		end
		if command == appCommand.resume then
			deliver(self, { name = "restore", window = window }, callback)
		end
	elseif command == appCommand.destroy then
		deliver(self, { name = "windowClose", window = window }, callback)
		self.isActive = false
	end
end

---@param p { id: number, x: number, y: number, pressure: number }
---@param window winit-android.Window
---@param name string
local function touchEvent(name, p, window)
	return { name = name, window = window, id = p.id, x = p.x, y = p.y, pressure = p.pressure }
end

-- How far a finger travels before a touch is a drag rather than a tap, and how fast a released
-- drag has to be moving to keep going, both in density-independent pixels.
local TOUCH_SLOP_DP = 8
local FLING_MIN_DP = 50 -- per second
-- A fling slows two ways at once: by drag, which takes away a share of its speed -- this is the
-- share left after a second -- and by a steady braking, which is what brings it to a stop rather
-- than to a crawl that never ends. Its speed comes down to nought, smoothly, at the moment it stops.
local FLING_FRICTION = 0.25
local FLING_BRAKE_DP = 220 -- per second, per second
-- How long the display is kept at its fastest rate after the last touch or fling.
local FAST_HOLD = 2
-- How long a finger rests without moving before it is a long press: the right button, which is a
-- context menu, as on every phone.
local LONG_PRESS = 0.5

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

---@param self winit-android.EventLoop
---@param window winit-android.Window
---@param x number
---@param y number
---@param dy number # Pixels the content is pulled up by: positive scrolls down, as a wheel's dy does
---@param callback winit.EventHandler
local function scrollBy(self, window, x, y, dy, callback)
	if dy ~= 0 then
		deliver(self, { name = "mouseScroll", window = window, x = x, y = y, dx = 0, dy = dy, pixels = true }, callback)
	end
end

--- A touch has no hover: with the last finger off the glass, nothing is under the pointer, and a
--- program that kept the place the last one was at would keep a hover there until it moved again.
---@param self winit-android.EventLoop
---@param window winit-android.Window
---@param callback winit.EventHandler
local function leavePointer(self, window, callback)
	deliver(self, { name = "mouseLeave", window = window }, callback)
end

---@param self winit-android.EventLoop
---@param event table
---@param window winit-android.Window
---@param callback winit.EventHandler
local function handleTouch(self, event, window, callback)
	local action = event.action
	local pointers = event.pointers
	local gesture = self.gesture

	if action == motionAction.down or action == motionAction.pointerDown then
		local p = pointers[event.index + 1]
		deliver(self, touchEvent("touchStart", p, window), callback)
		-- The first finger is the one a mouse-only program hears, but not yet: whether it is a
		-- tap, a scroll or a drag is only known once it has moved or been lifted. A finger put
		-- down stops a list that is still coasting, as on every phone.
		if gesture == nil then
			self.fling = nil
			self.gesture = {
				id = p.id, startX = p.x, startY = p.y, x = p.x, y = p.y, mode = "pending",
				samples = { { t = now(), y = p.y } },
			}
		end
	elseif action == motionAction.move then
		for _, p in ipairs(pointers) do
			deliver(self, touchEvent("touchMove", p, window), callback)
			if gesture ~= nil and p.id == gesture.id then
				if gesture.mode == "pending" then
					local slop = TOUCH_SLOP_DP * self.density
					local dx, dy = p.x - gesture.startX, p.y - gesture.startY
					if math.abs(dy) > slop and math.abs(dy) >= math.abs(dx) then
						-- Up and down is a scroll of whatever is under the finger.
						gesture.mode = "scroll"
					elseif math.abs(dx) > slop then
						-- Sideways is a drag, which is what a slider and a resize edge take: the
						-- press goes where the finger went down.
						gesture.mode = "drag"
						deliver(self, { name = "mouseMove", window = window, x = gesture.startX, y = gesture.startY }, callback)
						deliver(self, { name = "mousePress", window = window, x = gesture.startX, y = gesture.startY, button = 1 }, callback)
					end
				end

				if gesture.mode == "scroll" then
					-- A scroll belongs to what was under the finger when it went down, not to
					-- whatever it has moved over since: a finger dragging the content up moves down
					-- the screen, toward the bottom bar, and a scroll handed to the box it ended over
					-- is one the list never hears -- it stops dead halfway through the drag. Android
					-- fixes the target the same way, at the start of the gesture.
					scrollBy(self, window, gesture.startX, gesture.startY, gesture.y - p.y, callback)
					local samples = gesture.samples
					samples[#samples + 1] = { t = now(), y = p.y }
					if #samples > 6 then table.remove(samples, 1) end
					gesture.x, gesture.y = p.x, p.y
				elseif gesture.mode == "drag" then
					deliver(self, { name = "mouseMove", window = window, x = p.x, y = p.y }, callback)
					gesture.x, gesture.y = p.x, p.y
				end
			end
		end
	elseif action == motionAction.up or action == motionAction.pointerUp then
		local p = pointers[event.index + 1]
		deliver(self, touchEvent("touchEnd", p, window), callback)
		if gesture ~= nil and p.id == gesture.id then
			self.gesture = nil
			if gesture.mode == "pending" then
				-- Lifted near where it went down: a tap, which is a click where the finger was.
				deliver(self, { name = "mouseMove", window = window, x = gesture.startX, y = gesture.startY }, callback)
				deliver(self, { name = "mousePress", window = window, x = gesture.startX, y = gesture.startY, button = 1 }, callback)
				deliver(self, { name = "mouseRelease", window = window, x = gesture.startX, y = gesture.startY, button = 1 }, callback)
			elseif gesture.mode == "drag" then
				deliver(self, { name = "mouseRelease", window = window, x = p.x, y = p.y, button = 1 }, callback)
			else
				-- A scroll let go of while moving keeps moving and slows down. It coasts where the
				-- gesture began, like the drag before it: a finger dragging the content up lifts
				-- over the bars at the bottom, and a fling sent from there is a fling nothing
				-- scrolls.
				local samples = gesture.samples
				local first, last = samples[1], samples[#samples]
				local span = last.t - first.t
				local velocity = span > 0 and (first.y - last.y) / span or 0
				if math.abs(velocity) >= FLING_MIN_DP * self.density then
					self.fling = { velocity = velocity, start = now(), travelled = 0, x = gesture.startX, y = gesture.startY }
				end
			end
		end

		-- The last finger is off the glass, so there is no pointer any more: what a program kept
		-- of where it was is a hover over something nobody is pointing at. It goes after the
		-- release the gesture came to, so a tap is still a click where the finger was; a finger
		-- still down is still a pointer, and a fling is a scroll with a place of its own rather
		-- than a pointer, so neither of those is a leave.
		if #pointers == 1 then
			leavePointer(self, window, callback)
		end
	elseif action == motionAction.cancel then
		-- The system took the gesture (a swipe from the edge, a palm): every pointer is gone,
		-- and none of them is a release a program should act on.
		for _, p in ipairs(pointers) do
			deliver(self, touchEvent("touchCancel", p, window), callback)
		end
		if gesture ~= nil and gesture.mode == "drag" then
			local p = pointers[1]
			deliver(self, { name = "mouseRelease", window = window, x = p.x, y = p.y, button = 1 }, callback)
		end
		self.gesture = nil

		-- Every finger went with the gesture, so nothing is under a pointer any more either.
		leavePointer(self, window, callback)
	end
end

--- Where a fling has got to `t` seconds after it was let go, and whether it has stopped. Speed
--- falls as dv/dt = -k*v - c: drag `k` and braking `c`. That has a closed form, so where it is at
--- any moment is worked out from when it started, never summed step by step: a step that comes
--- late moves it further, and no rounding builds up.
---@param speed number # How fast it was let go, in pixels a second; always positive
---@param brake number # The braking, in pixels a second a second
---@param t number
---@return number distance
---@return boolean stopped
local function flingAt(speed, brake, t)
	local k = -math.log(FLING_FRICTION)
	local glide = brake / k
	local stopsAt = math.log(1 + speed / glide) / k
	local stopped = t >= stopsAt
	if stopped then t = stopsAt end
	return (speed + glide) * (1 - math.exp(-k * t)) / k - glide * t, stopped
end

--- One step of a fling: the distance it has covered since the last step.
---@param self winit-android.EventLoop
---@param window winit-android.Window
---@param callback winit.EventHandler
local function stepFling(self, window, callback)
	local fling = self.fling
	if fling == nil then return end
	local direction = fling.velocity < 0 and -1 or 1
	local distance, stopped = flingAt(math.abs(fling.velocity), FLING_BRAKE_DP * self.density, now() - fling.start)
	scrollBy(self, window, fling.x, fling.y, direction * (distance - fling.travelled), callback)
	fling.travelled = distance
	if stopped then
		self.fling = nil
	end
end

--- A finger that has rested where it went down for long enough is a long press, told to the program
--- as the right button pressed and let go there. What the finger does after it is nothing.
---@param self winit-android.EventLoop
---@param window winit-android.Window
---@param callback winit.EventHandler
local function checkLongPress(self, window, callback)
	local gesture = self.gesture
	if gesture == nil or gesture.mode ~= "pending" then return end
	if now() - gesture.samples[1].t < LONG_PRESS then return end
	gesture.mode = "held"
	local x, y = gesture.startX, gesture.startY
	deliver(self, { name = "mouseMove", window = window, x = x, y = y }, callback)
	deliver(self, { name = "mousePress", window = window, x = x, y = y, button = 3 }, callback)
	deliver(self, { name = "mouseRelease", window = window, x = x, y = y, button = 3 }, callback)
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
		if self.fling ~= nil and window ~= nil and window.nativeWindow ~= nil then
			-- A step whose frame came out the same is not presented, and nothing waits for the
			-- display then: the next step is held to a frame's time after the last one, so a list
			-- coasting against its end does not spin the loop. A frame's time is the display's,
			-- read back: asking for the fastest rate does not make a panel that stays at 60 run
			-- one frame every 11 ms.
			local frame = 1 / (currentRate() or 60)
			local left = (self.fling.steppedAt or 0) + frame - now()
			local held = left > 0 and math.ceil(left * 1000) or 0
			-- A deadline the program asked for that falls inside the frame is taken as it is: a
			-- step that is not due yet is one the pass after it takes.
			if timeout <= 0 or timeout > held then timeout = held end
		elseif self.fast and self.fastUntil ~= nil then
			local left = math.max(0, math.ceil((self.fastUntil - now()) * 1000))
			if timeout < 0 or timeout > left then timeout = left end
		end
		-- A finger resting on the screen is woken for when it becomes a long press.
		if self.gesture ~= nil and self.gesture.mode == "pending" then
			local left = math.max(0, math.ceil((self.gesture.samples[1].t + LONG_PRESS - now()) * 1000))
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
						handleTouch(self, event, window, callback)
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
			checkLongPress(self, window, callback)

			-- Exactly one step of a fling for each frame, taken just before it is drawn and drawn
			-- whatever the program's own frame pacing says: a step taken with no frame after it is
			-- motion that shows up a frame late, two steps in one frame -- a list that jerks.
			-- A pass woken early -- by an event that came in between frames -- is not a frame of
			-- the fling's own, and moves nothing.
			local fling = self.fling
			local frame = 1 / (currentRate() or 60)
			if fling ~= nil and now() - (fling.steppedAt or 0) >= frame * 0.75 then
				stepFling(self, window, callback)
				if self.fling ~= nil then self.fling.steppedAt = now() end
				window.shouldRedraw = true
			end

			-- A finger on the screen, or a list still coasting from one, is motion the eye follows:
			-- the display is asked for its fastest rate then, and for a moment after, and given its
			-- own choice back once nothing has moved for that long -- a still screen held at the
			-- fastest rate is battery spent on nothing.
			local at = now()
			if self.gesture ~= nil or self.fling ~= nil then
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
