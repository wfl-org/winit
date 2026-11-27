-- What a finger on a touch screen comes to, for a program that hears a mouse: the first finger
-- drives the pointer, and what it does along the way -- a tap, a scroll, a drag of what it went
-- down on, or a hold -- is what this works out. It knows nothing of Android: the loop hands it an
-- action, the pointers and the time, and it hands back the events a program hears. That is what
-- makes the rules testable without a phone.
--
-- A box that drags -- a row a phone swipes away, a list a held row is moved in -- can take the
-- touch for itself through `Touch:claim`, which is what the app does while the touchStart is
-- being delivered. A claimed touch presses the pointer down where the finger did, so a hold is
-- that press staying down rather than the right button's context menu, and the moves that follow
-- the hold go to the box rather than scrolling the list under it. A touch nobody claims is what
-- it was: a tap, a scroll of what is under it, or a right click where it rested.
local Touch = {}
Touch.__index = Touch

-- How far a finger travels before a touch is a drag rather than a tap, and how fast a released
-- scroll has to be moving to keep going, both in density-independent pixels.
local TOUCH_SLOP_DP = 8
local FLING_MIN_DP = 50 -- per second
-- A fling slows two ways at once: by drag, which takes away a share of its speed -- this is the
-- share left after a second -- and by a steady braking, which is what brings it to a stop rather
-- than to a crawl that never ends. Its speed comes down to nought, smoothly, at the moment it stops.
local FLING_FRICTION = 0.25
local FLING_BRAKE_DP = 220 -- per second, per second
-- How long a finger rests without moving before it is a long press: the right button, which is a
-- context menu, as on every phone. A touch an element claimed rests for the element's own hold
-- instead, which is what `claim` is given.
local LONG_PRESS = 0.5

--- The finger a mouse-only program hears, while it is down.
---@class winit-android.Touch.Gesture
---@field id number
---@field startX number # Where it went down, which is where a tap and a scroll belong
---@field startY number
---@field x number # Where it was at the last event that moved it
---@field y number
---@field downAt number # When it went down, on the monotonic clock
---@field mode "pending" | "scroll" | "drag" | "held" # What it has turned out to be, once it has moved or rested long enough
---@field samples { t: number, y: number }[] # The last few places it was, which is what a fling's speed is read from
---@field claimed boolean? # Whether a box took the touch while the start was delivered
---@field hold number? # How long a claimed touch rests before its moves are the box's: see `Touch:claim`
---@field pressed boolean? # Whether the left button went down for it and has not been let go of yet

--- A scroll still coasting after the finger left: how fast it was let go, when, how far it has
--- gone since, and when it last moved.
---@class winit-android.Touch.Fling
---@field velocity number
---@field start number
---@field travelled number
---@field x number
---@field y number
---@field steppedAt number?

---@class winit-android.Touch
---@field gesture winit-android.Touch.Gesture?
---@field fling winit-android.Touch.Fling?

---@return winit-android.Touch
function Touch.new()
	return setmetatable({ gesture = nil, fling = nil }, Touch)
end

--- A box under the finger takes the touch for itself, if it is still undecided. The app does this
--- while the touchStart is being delivered: the press then goes down where the finger did, and the
--- long press that would have been a context menu becomes this press staying down. `hold` is how
--- long the finger must rest before the moves that follow are the box's, in seconds; the box's own
--- gesture times itself against the same moment, and a default of the platform's long press is
--- used where it does not say.
---
--- Returns whether there was a touch to take: a gesture already scrolling or dragged, or none at
--- all, is one that cannot be claimed, and so is a finger that is not the one the gesture is.
---@param hold number?
---@param id number?
---@return boolean
function Touch:claim(hold, id)
	local gesture = self.gesture

	if gesture == nil or gesture.mode ~= "pending" then return false end
	if id ~= nil and id ~= gesture.id then return false end

	gesture.claimed = true
	gesture.hold = hold

	return true
end

---@param name string
---@param p { id: number, x: number, y: number, pressure: number }
---@return table
local function touchEvent(name, p)
	return { name = name, id = p.id, x = p.x, y = p.y, pressure = p.pressure }
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

--- The press a claimed touch began with, at the place the finger went down.
---@param gesture winit-android.Touch.Gesture
---@param emit fun(event: table)
local function pressAt(gesture, emit)
	emit({ name = "mouseMove", x = gesture.startX, y = gesture.startY, touch = true })
	emit({ name = "mousePress", x = gesture.startX, y = gesture.startY, button = 1, touch = true })
	gesture.pressed = true
end

--- The press let go of, because what the finger did turned out not to be the box's gesture: the
--- moves that follow scroll the list instead.
---@param gesture winit-android.Touch.Gesture
---@param x number
---@param y number
---@param emit fun(event: table)
local function releaseAt(gesture, x, y, emit)
	emit({ name = "mouseRelease", x = x, y = y, button = 1, touch = true })
	gesture.pressed = false
end

--- One touch event, as the events it comes to. The events are handed to `emit` as they are worked
--- out rather than returned, because what is emitted first -- the touchStart -- is what the app
--- answers with a claim.
---@param action "down" | "move" | "up" | "cancel"
---@param pointers { id: number, x: number, y: number, pressure: number }[]
---@param index number # Which of this event's pointers the action names
---@param time number # On the monotonic clock
---@param density number # Physical pixels per density-independent pixel
---@param emit fun(event: table)
function Touch:handle(action, pointers, index, time, density, emit)
	local gesture = self.gesture

	if action == "down" then
		local p = pointers[index + 1]
		-- The gesture exists before the app hears its start: that is the moment an element
		-- under the finger claims it, and a claim has to be on the gesture the events join.
		if gesture == nil then
			self.fling = nil
			gesture = {
				id = p.id,
				startX = p.x,
				startY = p.y,
				x = p.x,
				y = p.y,
				downAt = time,
				mode = "pending",
				samples = { { t = time, y = p.y } },
			}
			self.gesture = gesture
		end

		emit(touchEvent("touchStart", p))

		-- A box that claimed it has the pointer pressed where the finger went down, from the
		-- moment it went down: that press staying down is the hold.
		if gesture.claimed and not gesture.pressed and gesture.mode == "pending" and p.id == gesture.id then
			pressAt(gesture, emit)
		end
	elseif action == "move" then
		for _, p in ipairs(pointers) do
			emit(touchEvent("touchMove", p))

			if gesture ~= nil and p.id == gesture.id then
				if gesture.mode == "pending" then
					local slop = TOUCH_SLOP_DP * density
					local dx, dy = p.x - gesture.startX, p.y - gesture.startY
					local adx, ady = math.abs(dx), math.abs(dy)

					if adx > slop and adx > ady then
						-- Sideways is a drag, which is what a slider, a resize edge and a row swiped
						-- away take: the press goes where the finger went down. A claimed touch is
						-- already pressed there.
						gesture.mode = "drag"
						if not gesture.pressed then pressAt(gesture, emit) end
					elseif ady > slop and ady >= adx then
						-- Up and down is a scroll of whatever is under the finger, unless the box
						-- claimed the touch and the finger has rested on it long enough: then the
						-- hold has become a drag, and the moves are the box's own.
						if gesture.claimed and time - gesture.downAt >= (gesture.hold or LONG_PRESS) then
							gesture.mode = "drag"
							if not gesture.pressed then pressAt(gesture, emit) end
						else
							gesture.mode = "scroll"
							-- A claimed press is let go of here: what follows is the list scrolling,
							-- not the box dragging.
							if gesture.pressed then releaseAt(gesture, p.x, p.y, emit) end
						end
					end
				end

				if gesture.mode == "scroll" then
					-- A scroll belongs to what was under the finger when it went down, not to
					-- whatever it has moved over since: a finger dragging the content up moves down
					-- the screen, toward the bottom bar, and a scroll handed to the box it ended over
					-- is one the list never hears -- it stops dead halfway through the drag. Android
					-- fixes the target the same way, at the start of the gesture.
					local dy = gesture.y - p.y
					if dy ~= 0 then
						emit({
							name = "mouseScroll", x = gesture.startX, y = gesture.startY,
							dx = 0, dy = dy, pixels = true,
						})
					end
					local samples = gesture.samples
					samples[#samples + 1] = { t = time, y = p.y }
					if #samples > 6 then table.remove(samples, 1) end
					gesture.x, gesture.y = p.x, p.y
				elseif gesture.mode == "drag" then
					emit({ name = "mouseMove", x = p.x, y = p.y, touch = true })
					gesture.x, gesture.y = p.x, p.y
				end
			end
		end
	elseif action == "up" then
		local p = pointers[index + 1]
		emit(touchEvent("touchEnd", p))

		if gesture ~= nil and p.id == gesture.id then
			self.gesture = nil

			if gesture.mode == "pending" then
				-- Lifted near where it went down: a tap, which is a click where the finger was. A
				-- claimed touch was pressed there already, so only its release is left.
				if gesture.claimed then
					emit({ name = "mouseRelease", x = gesture.startX, y = gesture.startY, button = 1, touch = true })
				else
					pressAt(gesture, emit)
					emit({ name = "mouseRelease", x = gesture.startX, y = gesture.startY, button = 1, touch = true })
					gesture.pressed = false
				end
			elseif gesture.mode == "drag" then
				emit({ name = "mouseRelease", x = p.x, y = p.y, button = 1, touch = true })
			elseif gesture.mode == "scroll" then
				-- A scroll let go of while moving keeps moving and slows down. It coasts where the
				-- gesture began, like the drag before it: a finger dragging the content up lifts
				-- over the bars at the bottom, and a fling sent from there is a fling nothing
				-- scrolls. A claimed scroll let its press go when it became one, so there is no
				-- release left to send.
				local samples = gesture.samples
				local first, last = samples[1], samples[#samples]
				local span = last.t - first.t
				local velocity = span > 0 and (first.y - last.y) / span or 0

				if math.abs(velocity) >= FLING_MIN_DP * density then
					self.fling = {
						velocity = velocity, start = time, travelled = 0,
						x = gesture.startX, y = gesture.startY,
					}
				end
			end
		end

		-- The last finger is off the glass, so there is no pointer any more: what a program kept
		-- of where it was is a hover over something nobody is pointing at. It goes after the
		-- release the gesture came to, so a tap is still a click where the finger was; a finger
		-- still down is still a pointer, and a fling is a scroll with a place of its own rather
		-- than a pointer, so neither of those is a leave.
		if #pointers == 1 then emit({ name = "mouseLeave" }) end
	elseif action == "cancel" then
		-- The system took the gesture (a swipe from the edge, a palm): every pointer is gone,
		-- and none of them is a release a program should act on.
		for _, p in ipairs(pointers) do
			emit(touchEvent("touchCancel", p))
		end

		if gesture ~= nil then
			local p = pointers[1]
			if p ~= nil and (gesture.mode == "drag" or gesture.pressed) then
				emit({ name = "mouseRelease", x = p.x, y = p.y, button = 1, touch = true })
			end
			self.gesture = nil
		end

		-- Every finger went with the gesture, so nothing is under a pointer any more either.
		emit({ name = "mouseLeave" })
	end
end

--- A finger that has rested where it went down for long enough is a long press, told to the
--- program as the right button pressed and let go there. What the finger does after it is nothing.
--- A touch a box claimed is not this: its press is already down, and it stays down for the box's
--- own hold instead.
---@param time number
---@param emit fun(event: table)
function Touch:checkLongPress(time, emit)
	local gesture = self.gesture

	if gesture == nil or gesture.mode ~= "pending" or gesture.claimed then return end
	if time - gesture.samples[1].t < LONG_PRESS then return end

	gesture.mode = "held"
	local x, y = gesture.startX, gesture.startY
	emit({ name = "mouseMove", x = x, y = y, touch = true })
	emit({ name = "mousePress", x = x, y = y, button = 3, touch = true })
	emit({ name = "mouseRelease", x = x, y = y, button = 3, touch = true })
end

--- One step of a fling: the distance it has covered since the last step.
---@param time number
---@param density number
---@param emit fun(event: table)
function Touch:stepFling(time, density, emit)
	local fling = self.fling

	if fling == nil then return end

	local direction = fling.velocity < 0 and -1 or 1
	local distance, stopped = flingAt(math.abs(fling.velocity), FLING_BRAKE_DP * density, time - fling.start)
	local dy = direction * (distance - fling.travelled)

	if dy ~= 0 then
		emit({ name = "mouseScroll", x = fling.x, y = fling.y, dx = 0, dy = dy, pixels = true })
	end

	fling.travelled = distance

	if stopped then
		self.fling = nil
	end
end

--- Whether a finger is on the glass, or a list is still coasting from one: the loop draws while
--- this is true and waits otherwise.
---@return boolean
function Touch:active()
	return self.gesture ~= nil or self.fling ~= nil
end

--- When a resting finger becomes a long press, as seconds from now, or nil when there is no
--- finger resting: the loop has no timer, so this is what its wait is cut short by.
---@param time number
---@return number?
function Touch:longPressIn(time)
	local gesture = self.gesture

	if gesture == nil or gesture.mode ~= "pending" or gesture.claimed then return nil end

	return math.max(0, gesture.samples[1].t + LONG_PRESS - time)
end

return Touch
