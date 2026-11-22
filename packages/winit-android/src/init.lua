local ffi = require("ffi")
local bit = require("bit")
local android = require("androidapi")

local constants = android.Constants
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
		-- Back is reported and then left to the system, which finishes the activity; a program
		-- hears about that as windowClose. Every other key is the program's.
		return keyCode == KEYCODE_BACK and 0 or 1
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
---@field mouseTouch number? # The touch pointer currently standing in for the mouse
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
		mouseTouch = nil,
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
		-- The surface is destroyed when this returns, so the program must let go of it now.
		deliver(self, { name = "unmap", window = window }, callback)
		window.nativeWindow = nil
		window.visible = false
	elseif command == appCommand.windowResized or command == appCommand.configChanged
		or command == appCommand.contentRectChanged then
		local width, height = window.width, window.height
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
		deliver(self, { name = "minimize", window = window }, callback)
	elseif command == appCommand.resume then
		deliver(self, { name = "restore", window = window }, callback)
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

---@param self winit-android.EventLoop
---@param event table
---@param window winit-android.Window
---@param callback winit.EventHandler
local function handleTouch(self, event, window, callback)
	local action = event.action
	local pointers = event.pointers

	if action == motionAction.down or action == motionAction.pointerDown then
		local p = pointers[event.index + 1]
		deliver(self, touchEvent("touchStart", p, window), callback)
		-- The first finger down also drives the mouse, so a program that only knows the mouse
		-- still works; later fingers are touches only.
		if self.mouseTouch == nil then
			self.mouseTouch = p.id
			deliver(self, { name = "mouseMove", window = window, x = p.x, y = p.y }, callback)
			deliver(self, { name = "mousePress", window = window, x = p.x, y = p.y, button = 1 }, callback)
		end
	elseif action == motionAction.move then
		for _, p in ipairs(pointers) do
			deliver(self, touchEvent("touchMove", p, window), callback)
			if p.id == self.mouseTouch then
				deliver(self, { name = "mouseMove", window = window, x = p.x, y = p.y }, callback)
			end
		end
	elseif action == motionAction.up or action == motionAction.pointerUp then
		local p = pointers[event.index + 1]
		deliver(self, touchEvent("touchEnd", p, window), callback)
		if p.id == self.mouseTouch then
			self.mouseTouch = nil
			deliver(self, { name = "mouseRelease", window = window, x = p.x, y = p.y, button = 1 }, callback)
		end
	elseif action == motionAction.cancel then
		-- The system took the gesture (a swipe from the edge, a palm): every pointer is gone,
		-- and none of them is a release a program should act on.
		for _, p in ipairs(pointers) do
			deliver(self, touchEvent("touchCancel", p, window), callback)
		end
		if self.mouseTouch ~= nil then
			local p = pointers[1]
			self.mouseTouch = nil
			deliver(self, { name = "mouseRelease", window = window, x = p.x, y = p.y, button = 1 }, callback)
		end
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

---@param callback winit.EventHandler
function AndroidEventLoop:run(callback)
	self.isActive = true

	while self.isActive do
		local timeout = 0
		-- Nothing to draw into while the surface is gone: sleep until the system brings it back,
		-- rather than spinning a program that asked for redraws.
		local window = firstWindow(self)
		if self.mode == "wait" or (window ~= nil and window.nativeWindow == nil) then
			timeout = self.timeout and math.floor(self.timeout * 1000) or -1
		end

		android.pollOnce(timeout)
		-- Drain whatever else is ready without waiting again, so a burst of input is handled in
		-- one pass rather than one event per frame.
		while android.pollOnce(0) >= 0 do end

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

		for _, w in pairs(self.windows) do
			if w.shouldRedraw and w.nativeWindow ~= nil then
				w.shouldRedraw = false
				deliver(self, { name = "redraw", window = w }, callback)
			end
		end

		deliver(self, { name = "aboutToWait" }, callback)
	end
end

return {
	Window = AndroidWindow,
	EventLoop = AndroidEventLoop,
	Clipboard = AndroidClipboard,
}
