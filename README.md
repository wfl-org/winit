# winit [![Tests](https://github.com/bycruz/winit/actions/workflows/test.yml/badge.svg)](https://github.com/bycruz/winit/actions/workflows/test.yml)

Window creation and handling library in pure LuaJIT.

## Support

| Windows | Linux | macOS | Android |
| ------- | ----- | ----- | ------- |
| ✅      | ✅    | ✅    | ✅      |

## Installation

Use this package with the [lde](https://lde.sh/) package manager.

```bash
lde add winit
```

## Backends

The backends are packages of their own, and a program installs the one its platform runs on:

| Package       | Platform | Built on        |
| ------------- | -------- | --------------- |
| `winit-x11`   | Linux    | Xlib and XInput2, through [x11api](https://github.com/bycruz/x11api) |
| `winit-win32` | Windows  | user32 and shell32, through [winapi](https://github.com/bycruz/winapi) |
| `winit-macos` | macOS    | Cocoa, through a small Objective-C shim built when the package is installed |
| `winit-android` | Android | NativeActivity, through [androidapi](https://github.com/wfl-org/androidapi) |

`linux`, `windows`, `macos` and `android` are features lde turns on by itself, so naming winit is
enough to get the right one:

```jsonc
"dependencies": {
	"winit": { "version": "0.2" }
}
```

The backend a program does not run on is not installed at all, which is what keeps it out of a
bundle: a whole platform's worth of code that could never run there.

### macOS

A window on macOS is an object that is sent messages rather than a handle a program makes calls
on, and the events it is sent back are objects of another shape again, so the platform's half is
one page of Objective-C compiled into a shared library when the package is installed -- see
`src/shim.m` and `build.lua` in `packages/winit-macos`. What crosses back to Lua is a queue of
plain values, read a struct at a time. Nothing needs to be installed for it beyond the command
line tools a mac ships with, since what compiles it is the clang already there.

A renderer is given the view a window draws in with `window:nativeView()`, which is what a
graphics backend on this platform makes its context out of.

### Android

An Android app has one window, the activity's, and it is full screen. Its surface exists only
while the app is in the foreground: it arrives with `map` and is gone after `unmap`, so a
renderer makes its GPU surface on `map` (from `window.nativeWindow`) and drops it on `unmap`.
Going to the background is also `minimize`, coming back `restore`.

Touches are events of their own, one per finger, with an `id` that stays the same for as long as
the finger is down:

```lua
{ window = window, name = "touchStart", id = 0, x = 120, y = 80, pressure = 1 }
-- then touchMove, and touchEnd -- or touchCancel when the system takes the gesture
```

The first finger down also drives the mouse as button 1, so a program written for the mouse
works as it is. Gestures such as pinch and pan are not events: a program works them out from its
touches.

`window:setTextInput(true)` shows the on-screen keyboard; what it types arrives as `keyPress`
events carrying `text`, as a hardware keyboard's keys do. A NativeActivity has no text input
connection, so a keyboard's suggestions, composed text and emoji do not reach it. The back button
is a `keyPress` with key `"back"`, after which the system closes the app (`windowClose`).

## Windows

```lua
local winit = require("winit")

local eventLoop = winit.EventLoop.new()
local window = winit.Window.fromEventLoop(eventLoop)
window:setTitle("my window")

eventLoop:run(function(event, handler)
	if event.name == "windowClose" then
		handler:exit()
	elseif event.name == "keyPress" and event.key == "escape" then
		handler:exit()
	elseif event.name == "fileDrop" then
		for _, path in ipairs(event.paths) do
			print("dropped: " .. path)
		end
	end
end)
```

## Clipboard

A clipboard is the system's rather than a window's, so a program wants one of them, not one per
window. Text is what both platforms agree on:

```lua
local clipboard = winit.Clipboard.new(eventLoop)

clipboard:setText("what a copy would put there")  -- offered to the rest of the system
clipboard:getText()                                -- what is on it now, or nil
clipboard:clear()                                  -- emptied
```

On Linux a clipboard is a conversation: what a program offers is served while it runs, and what
it reads is asked of whichever program is offering it. A read waits for that program to answer,
up to a second, and events that arrive while it waits are handed to the event loop afterwards
rather than lost.

## Files

Files dropped on a window arrive as a path list, one event for the whole drop:

```lua
---@type winit.Event
{ window = window, name = "fileDrop", paths = { "/home/user/notes.txt" }, x = 120, y = 80 }
```

Linux uses XDND, the X drag and drop protocol, so a window says it accepts files before anything
is dragged onto it; Windows uses the shell's own drop messages.

## Examples

Each example is a package of its own, run from its directory with `lde run`:

```bash
cd examples/clipboard && lde run
```
