-- What a finger comes to for a program that hears a mouse: the events a tap, a scroll, a drag and
-- a hold are handed over as, and what a box that claims the touch changes. A phone is not needed
-- for any of it: the module is handed the pointers, the time and the density, and hands back the
-- events, so a whole gesture is a few calls and an array.
local test = require("lde-test")
local Touch = require("winit-android.touch")

local DENSITY = 1
local LEFT, RIGHT = 1, 3

--- A place to catch what a gesture emits, and the pointer into it.
---@return table[] events
---@return fun(event: table) emit
local function caught()
	local events = {}

	return events, function(event)
		events[#events + 1] = event
	end
end

--- The events of a list with this name, in the order they were emitted.
---@param events table[]
---@param name string
---@return table[]
local function named(events, name)
	local found = {}

	for _, event in ipairs(events) do
		if event.name == name then found[#found + 1] = event end
	end

	return found
end

---@param events table[]
---@param name string
---@return table?
local function last(events, name)
	local found = named(events, name)

	return found[#found]
end

--- A finger down at a place, and the module's answer, with the app claiming the touch while its
--- start is delivered when `claim` is given: that is the moment a box under the finger takes it.
---@param touch winit-android.Touch
---@param x number
---@param y number
---@param time number
---@param claim number?
---@param events table[]
---@param emit fun(event: table)
local function down(touch, x, y, time, claim, events, emit)
	if claim ~= nil then
		local emitStart = emit
		emit = function(event)
			emitStart(event)
			if event.name == "touchStart" then touch:claim(claim) end
		end
	end

	touch:handle("down", { { id = 1, x = x, y = y, pressure = 1 } }, 0, time, DENSITY, emit)
	return events
end

---@param touch winit-android.Touch
---@param x number
---@param y number
---@param time number
---@param emit fun(event: table)
local function move(touch, x, y, time, emit)
	touch:handle("move", { { id = 1, x = x, y = y, pressure = 1 } }, 0, time, DENSITY, emit)
end

---@param touch winit-android.Touch
---@param x number
---@param y number
---@param time number
---@param emit fun(event: table)
local function up(touch, x, y, time, emit)
	touch:handle("up", { { id = 1, x = x, y = y, pressure = 1 } }, 0, time, DENSITY, emit)
end

test.it("makes a tap a left click where the finger was", function()
	local touch = Touch.new()
	local events, emit = caught()

	down(touch, 40, 30, 10, nil, events, emit)
	up(touch, 42, 31, 10.1, emit)

	test.equal(#named(events, "touchStart"), 1)
	test.equal(#named(events, "touchEnd"), 1)

	local pressed, released = last(events, "mousePress"), last(events, "mouseRelease")
	test.truthy(pressed ~= nil and released ~= nil, "a tap is pressed and released")
	test.equal(pressed.button, LEFT)
	test.equal(pressed.x, 40, "where the finger went down")
	test.equal(pressed.y, 30)
	test.equal(released.x, 40, "and let go of where it went down")
	test.equal(last(events, "mouseLeave") ~= nil, true, "the pointer leaves with the last finger")
end)

test.it("makes a long press on what nobody claimed the right button, and ignores what follows", function()
	local touch = Touch.new()
	local events, emit = caught()

	down(touch, 40, 30, 10, nil, events, emit)
	touch:checkLongPress(10.6, emit)

	local pressed = last(events, "mousePress")
	test.truthy(pressed ~= nil, "the long press is a press")
	test.equal(pressed.button, RIGHT, "of the right button, which is a menu")
	test.equal(last(events, "mouseRelease").button, RIGHT)

	local before = #events
	move(touch, 40, 120, 10.7, emit)
	test.equal(#events, before + 1, "only the touch move is left: no scroll from the move after a menu")
	test.equal(named(events, "mouseScroll")[1], nil)

	up(touch, 40, 120, 10.8, emit)
	test.equal(#named(events, "mousePress"), 1, "and no other press came")
end)

test.it("presses where a claimed touch went down, so the hold is that press staying down", function()
	local touch = Touch.new()
	local events, emit = caught()

	down(touch, 60, 80, 10, 0.35, events, emit)

	test.equal(#named(events, "mousePress"), 1, "the press begins with the finger")
	local pressed = last(events, "mousePress")
	test.equal(pressed.button, LEFT)
	test.equal(pressed.x, 60, "where the finger went down")
	test.equal(pressed.y, 80)

	touch:checkLongPress(10.4, emit)
	test.equal(#named(events, "mousePress"), 1, "the hold is not another press")
	test.equal(#named(events, "mouseRelease"), 0, "and nothing was let go of")

	move(touch, 60, 120, 10.45, emit)

	local moved = last(events, "mouseMove")
	test.equal(#named(events, "mouseScroll"), 0, "the move after the hold is not a scroll")
	test.truthy(moved ~= nil, "it is the box's own move")
	test.equal(moved.x, 60)
	test.equal(moved.y, 120)

	move(touch, 60, 200, 10.55, emit)
	up(touch, 60, 200, 10.6, emit)

	test.equal(last(events, "mouseRelease").y, 200, "and the press is let go of where the finger was")
	test.equal(last(events, "mouseRelease").button, LEFT)
end)

test.it("scrolls a claimed touch moved up or down before the hold", function()
	local touch = Touch.new()
	local events, emit = caught()

	down(touch, 60, 80, 10, 0.35, events, emit)
	move(touch, 60, 120, 10.1, emit)

	local scroll = last(events, "mouseScroll")
	test.truthy(scroll ~= nil, "before the hold a vertical move is the list scrolling")
	test.equal(scroll.dy, -40, "the content follows the finger")
	test.equal(scroll.pixels, true)

	local released = last(events, "mouseRelease")
	test.truthy(released ~= nil, "the claimed press is let go of when the box is not the gesture")
	test.equal(released.button, LEFT)

	move(touch, 60, 150, 10.2, emit)
	test.truthy(#named(events, "mouseScroll") >= 2, "and the scroll goes on")
	test.equal(#named(events, "mouseMove"), 1, "with no box moves")
end)

test.it("drags a claimed touch that is sideways, before any hold", function()
	local touch = Touch.new()
	local events, emit = caught()

	down(touch, 200, 80, 10, 0.35, events, emit)
	move(touch, 120, 82, 10.05, emit)

	test.equal(#named(events, "mousePress"), 1, "pressed once, where the finger went down")
	test.equal(#named(events, "mouseScroll"), 0, "a sideways move never scrolls")

	local moved = last(events, "mouseMove")
	test.truthy(moved ~= nil, "the box hears the move")
	test.equal(moved.x, 120)

	up(touch, 40, 82, 10.2, emit)
	test.equal(last(events, "mouseRelease").x, 40, "and the release is where it was let go of")
	test.equal(last(events, "mouseRelease").button, LEFT)
end)

test.it("takes the press for a claimed drag, and the release where it was let go of", function()
	local touch = Touch.new()
	local events, emit = caught()

	down(touch, 200, 80, 10, 0.35, events, emit)
	move(touch, 196, 80, 10.02, emit)
	test.equal(#named(events, "mousePress"), 1, "still only the press the finger began with")
	test.equal(#named(events, "mouseMove"), 1, "a move that has not left the slop is nothing")
end)

test.it("scrolls an unclaimed vertical move, without pressing", function()
	local touch = Touch.new()
	local events, emit = caught()

	down(touch, 60, 80, 10, nil, events, emit)
	move(touch, 60, 120, 10.1, emit)

	test.equal(#named(events, "mousePress"), 0, "an unclaimed touch presses nothing until it is a tap")
	local scroll = last(events, "mouseScroll")
	test.truthy(scroll ~= nil)
	test.equal(scroll.dy, -40)

	up(touch, 60, 120, 10.2, emit)
	test.equal(#named(events, "mouseRelease"), 0, "and nothing is let go of")
end)

test.it("refuses to claim what is already scrolling or dragged", function()
	local touch = Touch.new()
	local events, emit = caught()

	down(touch, 60, 80, 10, nil, events, emit)
	move(touch, 60, 120, 10.1, emit)
	test.equal(touch:claim(0.35), false, "a scroll is nobody's to claim")

	local other = Touch.new()
	local otherEvents, otherEmit = caught()
	down(other, 60, 80, 10, nil, otherEvents, otherEmit)
	move(other, 120, 82, 10.1, otherEmit)
	test.equal(other:claim(0.35), false, "nor is a drag")
	test.equal(Touch.new():claim(0.35), false, "and there is nothing to claim with no finger down")

	local finger = Touch.new()
	local fingerEvents, fingerEmit = caught()
	down(finger, 60, 80, 10, nil, fingerEvents, fingerEmit)
	test.equal(finger:claim(0.35, 2), false, "a second finger does not take the first one's touch")
	test.equal(finger:claim(0.35, 1), true, "the finger that went down does")
end)

test.it("lets go of a claimed press the system cancels", function()
	local touch = Touch.new()
	local events, emit = caught()

	down(touch, 60, 80, 10, 0.35, events, emit)
	touch:handle("cancel", { { id = 1, x = 60, y = 80, pressure = 1 } }, 0, 10.1, DENSITY, emit)

	test.equal(last(events, "mouseRelease").button, LEFT, "the press does not stay down")
	test.truthy(last(events, "mouseLeave") ~= nil)
	test.equal(touch.gesture, nil)
end)

test.it("coasts a scroll let go of fast, from where it began", function()
	local touch = Touch.new()
	local events, emit = caught()

	down(touch, 60, 200, 10, nil, events, emit)
	move(touch, 60, 150, 10.02, emit)
	move(touch, 60, 100, 10.04, emit)
	up(touch, 60, 100, 10.06, emit)

	test.truthy(touch.fling ~= nil, "a fast scroll keeps going")
	test.equal(touch.fling.x, 60, "from where the finger went down")
	test.equal(touch.fling.y, 200)

	local scrolls = #named(events, "mouseScroll")
	touch:stepFling(10.1, DENSITY, emit)
	test.truthy(#named(events, "mouseScroll") > scrolls, "a step moves it")
end)

test.it("does not keep a fling from a slow scroll", function()
	local touch = Touch.new()
	local events, emit = caught()

	down(touch, 60, 200, 10, nil, events, emit)
	move(touch, 60, 195, 10.2, emit)
	up(touch, 60, 195, 10.4, emit)

	test.equal(touch.fling, nil, "a scroll let go of slowly just stops")
end)

test.it("is active while a finger is down or a list is coasting", function()
	local touch = Touch.new()
	local events, emit = caught()

	test.equal(touch:active(), false)
	down(touch, 60, 80, 10, nil, events, emit)
	test.equal(touch:active(), true)
	up(touch, 60, 80, 10.1, emit)
	test.equal(touch:active(), false)
end)

test.it("wakes for a long press only where a finger is resting on nobody's box", function()
	local touch = Touch.new()
	local events, emit = caught()

	test.equal(touch:longPressIn(10), nil, "no finger, no wake")

	down(touch, 60, 80, 10, nil, events, emit)
	local wake = touch:longPressIn(10.2)
	test.truthy(wake ~= nil and math.abs(wake - 0.3) < 1e-6, "the rest of the long press, from now")

	local claimedTouch = Touch.new()
	local claimedEvents, claimedEmit = caught()
	down(claimedTouch, 60, 80, 10, 0.35, claimedEvents, claimedEmit)
	test.equal(claimedTouch:longPressIn(10.2), nil, "a claimed hold is the box's own")
end)
