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
local meta = constants.Meta
local button = constants.Button
local axis = constants.Axis

local keyNames = {
	[7] = "0", [8] = "1", [9] = "2", [10] = "3", [11] = "4",
	[12] = "5", [13] = "6", [14] = "7", [15] = "8", [16] = "9",
	[19] = "up", [20] = "down", [21] = "left", [22] = "right",
	[29] = "a", [30] = "b", [31] = "c", [32] = "d", [33] = "e",
	[34] = "f", [35] = "g", [36] = "h", [37] = "i", [38] = "j",
	[39] = "k", [40] = "l", [41] = "m", [42] = "n", [43] = "o",
	[44] = "p", [45] = "q", [46] = "r", [47] = "s", [48] = "t",
	[49] = "u", [50] = "v", [51] = "w", [52] = "x", [53] = "y",
	[54] = "z",
	[57] = "left-alt", [58] = "right-alt",
	[59] = "left-shift", [60] = "right-shift",
	[61] = "tab", [62] = "space", [66] = "return", [67] = "backspace",
	[92] = "page-up", [93] = "page-down",
	[111] = "escape", [112] = "delete",
	[113] = "left-ctrl", [114] = "right-ctrl",
	[115] = "caps-lock",
	[117] = "left-super", [118] = "right-super",
	[122] = "home", [123] = "end", [124] = "insert",
	[131] = "f1", [132] = "f2", [133] = "f3", [134] = "f4",
	[135] = "f5", [136] = "f6", [137] = "f7", [138] = "f8",
	[139] = "f9", [140] = "f10", [141] = "f11", [142] = "f12",
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

---@param state number
---@return number?
local function buttonOf(state)
	if bit.band(state, button.primary) ~= 0 then return 1 end
	if bit.band(state, button.secondary) ~= 0 then return 3 end
	if bit.band(state, button.tertiary) ~= 0 then return 2 end
	return nil
end

---@param code number
---@return string
local function keyNameOf(code)
	return keyNames[code] or ("keycode-" .. tostring(code))
end

---@param code number
---@return string?
local function textOf(code)
	if code == 0 or code < 0x20 or code == 0x7f then
		return nil
	end
	if code < 0x80 then
		return string.char(code)
	end
	local ok, utf8 = pcall(require, "utf8")
	if ok then
		return utf8.char(code)
	end
	return nil
end

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
	local source = lib.AInputEvent_getSource(input)

	if kind == inputType.motion then
		local action = bit.band(lib.AMotionEvent_getAction(input), motionAction.mask)
		queueEvent({
			input = "motion",
			action = action,
			pointerId = lib.AMotionEvent_getPointerId(input, 0),
			button = lib.AMotionEvent_getButtonState(input),
			source = source,
			x = lib.AMotionEvent_getX(input, 0),
			y = lib.AMotionEvent_getY(input, 0),
			dx = lib.AMotionEvent_getAxisValue(input, axis.hscroll, 0),
			dy = lib.AMotionEvent_getAxisValue(input, axis.vscroll, 0),
		})
		return 1
	end

	if kind == inputType.key then
		local action = lib.AKeyEvent_getAction(input)
		queueEvent({
			input = "key",
			action = action,
			keyCode = lib.AKeyEvent_getKeyCode(input),
			metaState = lib.AKeyEvent_getMetaState(input),
			repeatCount = lib.AKeyEvent_getRepeatCount(input),
			unicode = lib.AKeyEvent_getUnicodeChar(input),
			source = source,
		})
		return 1
	end

	return 0
end

local appCmdCallback = ffi.cast("void (*)(struct androidapi_app*, int32_t)", onAppCmd)
local inputCallback = ffi.cast("int32_t (*)(struct androidapi_app*, void*)", onInput)
app.onAppCmd = appCmdCallback
app.onInputEvent = inputCallback

---@class winit-android.Window: winit.Window
---@field nativeWindow androidapi.ffi.NativeWindow?
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

function AndroidWindow:destroy()
	self.nativeWindow = nil
	android.finish()
end

---@class winit-android.EventLoop: winit.EventLoop
---@field windows table<string, winit-android.Window>
---@field nextWindowId number
---@field isActive boolean
---@field mode winit.EventLoopMode
---@field timeout number?
---@field handler winit.EventManager
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

---@param event table
---@param callback winit.EventHandler
local function deliver(self, event, callback)
	local window = event.window or firstWindow(self)
	if window ~= nil then
		event.window = window
	end
	callback(event, self.handler)
end

---@param callback winit.EventHandler
function AndroidEventLoop:run(callback)
	self.isActive = true
	local created = false

	while self.isActive do
		local timeout = 0
		if self.mode == "wait" then
			timeout = self.timeout and math.floor(self.timeout * 1000) or -1
		end

		android.pollOnce(timeout)

		for event in function() return nextEvent() end do
			if event.command ~= nil then
				local command = event.command
				local window = firstWindow(self)

				if command == appCommand.initWindow and window ~= nil then
					window.nativeWindow = app.window
					local width, height = android.windowSize()
					window.width = width or window.width
					window.height = height or window.height
					window.shouldRedraw = true

					-- A window exists to a program only once Android has made its
					-- native surface. Creating a GPU surface before that has no
					-- ANativeWindow to attach to, so `create` waits for this event.
					if not created then
						created = true
						for _, made in pairs(self.windows) do
							deliver(self, { name = "create", window = made }, callback)
						end
					end

					deliver(self, { name = "map", window = window }, callback)
				elseif command == appCommand.termWindow and window ~= nil then
					window.nativeWindow = nil
					deliver(self, { name = "unmap", window = window }, callback)
				elseif command == appCommand.windowResized and window ~= nil then
					local width, height = android.windowSize()
					window.width = width or window.width
					window.height = height or window.height
					window.shouldRedraw = true
					deliver(self, { name = "resize", window = window }, callback)
				elseif command == appCommand.windowRedrawNeeded then
					if window ~= nil then window.shouldRedraw = true end
				elseif command == appCommand.gainedFocus and window ~= nil then
					deliver(self, { name = "focusIn", window = window }, callback)
				elseif command == appCommand.lostFocus and window ~= nil then
					deliver(self, { name = "focusOut", window = window }, callback)
				elseif command == appCommand.destroy and window ~= nil then
					deliver(self, { name = "windowClose", window = window }, callback)
					self.isActive = false
				end
			elseif event.input == "motion" then
				local window = firstWindow(self)
				if window ~= nil then
					if event.action == motionAction.down or event.action == motionAction.pointerDown then
						deliver(self, {
							name = "mousePress",
							window = window,
							x = event.x,
							y = event.y,
							button = buttonOf(event.button) or 1,
						}, callback)
					elseif event.action == motionAction.move or event.action == motionAction.hoverMove then
						deliver(self, { name = "mouseMove", window = window, x = event.x, y = event.y }, callback)
					elseif event.action == motionAction.up or event.action == motionAction.pointerUp then
						deliver(self, {
							name = "mouseRelease",
							window = window,
							x = event.x,
							y = event.y,
							button = buttonOf(event.button) or 1,
						}, callback)
					elseif event.action == motionAction.scroll then
						deliver(self, { name = "mouseScroll", window = window, dx = event.dx, dy = event.dy }, callback)
					end
				end
			elseif event.input == "key" then
				local window = firstWindow(self)
				if window ~= nil then
					local key = keyNameOf(event.keyCode)
					local modifiers = modifiersOf(event.metaState)
					if event.action == keyAction.down or event.action == keyAction.multiple then
						deliver(self, {
							name = "keyPress",
							window = window,
							key = key,
							modifiers = modifiers,
							text = textOf(event.unicode),
							repeated = event.repeatCount > 0,
						}, callback)
					elseif event.action == keyAction.up then
						deliver(self, {
							name = "keyRelease",
							window = window,
							key = key,
							modifiers = modifiers,
							repeated = event.repeatCount > 0,
						}, callback)
					end
				end
			end
		end

		for _, window in pairs(self.windows) do
			if window.shouldRedraw then
				window.shouldRedraw = false
				deliver(self, { name = "redraw", window = window }, callback)
			end
		end

		deliver(self, { name = "aboutToWait" }, callback)
	end
end

return {
	Window = AndroidWindow,
	EventLoop = AndroidEventLoop,
}
