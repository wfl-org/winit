-- The refresh rate of the displays an X server drives, from XRandR: the fastest mode any lit
-- monitor is running, which is the most frames a window could be shown at. A server without
-- XRandR -- or a machine without the library -- has no answer, and the caller keeps its own.
local ffi = require("ffi")
local bit = require("bit")

ffi.cdef [[
	typedef struct {
		unsigned long id;
		unsigned int width, height;
		unsigned long dotClock;
		unsigned int hSyncStart, hSyncEnd, hTotal, hSkew;
		unsigned int vSyncStart, vSyncEnd, vTotal;
		char *name;
		unsigned int nameLength;
		unsigned long modeFlags;
	} winit_x11_XRRModeInfo;

	typedef struct {
		unsigned long timestamp, configTimestamp;
		int ncrtc;
		unsigned long *crtcs;
		int noutput;
		unsigned long *outputs;
		int nmode;
		winit_x11_XRRModeInfo *modes;
	} winit_x11_XRRScreenResources;

	typedef struct {
		unsigned long timestamp;
		int x, y;
		unsigned int width, height;
		unsigned long mode;
		unsigned short rotation;
		int noutput;
		unsigned long *outputs;
		unsigned short rotations;
		int npossible;
		unsigned long *possible;
	} winit_x11_XRRCrtcInfo;

	winit_x11_XRRScreenResources *XRRGetScreenResourcesCurrent(void *display, unsigned long window);
	void XRRFreeScreenResources(winit_x11_XRRScreenResources *resources);
	winit_x11_XRRCrtcInfo *XRRGetCrtcInfo(void *display, winit_x11_XRRScreenResources *resources, unsigned long crtc);
	void XRRFreeCrtcInfo(winit_x11_XRRCrtcInfo *info);
	unsigned long winit_x11_default_root(void *display) __asm__("XDefaultRootWindow");
]]

local loaded, xrandr = pcall(ffi.load, "Xrandr")
if not loaded then loaded, xrandr = pcall(ffi.load, "libXrandr.so.2") end

-- XRandR's mode flags for a mode that draws every line twice, or every other line a frame.
local DOUBLE_SCAN = 0x20
local INTERLACE = 0x10

local refresh = {}

---@param mode ffi.cdata*
---@return number
local function rateOf(mode)
	local lines = mode.vTotal
	local flags = tonumber(mode.modeFlags) or 0
	if bit.band(flags, DOUBLE_SCAN) ~= 0 then lines = lines * 2 end
	if bit.band(flags, INTERLACE) ~= 0 then lines = lines / 2 end
	if mode.hTotal == 0 or lines == 0 then return 0 end
	return tonumber(mode.dotClock) / (mode.hTotal * lines)
end

--- The fastest refresh rate of a monitor that is on, in hertz, or nothing where XRandR cannot say.
---@param display ffi.cdata*
---@return number?
function refresh.rate(display)
	if not loaded then return nil end

	-- Through the XRandR library's handle: a lookup there searches what it links, which is Xlib.
	local resources = xrandr.XRRGetScreenResourcesCurrent(display, xrandr.winit_x11_default_root(display))
	if resources == nil then return nil end

	local best = 0
	for index = 0, resources.ncrtc - 1 do
		local crtc = xrandr.XRRGetCrtcInfo(display, resources, resources.crtcs[index])
		if crtc ~= nil then
			if crtc.mode ~= 0 then
				for at = 0, resources.nmode - 1 do
					local mode = resources.modes[at]
					if mode.id == crtc.mode then
						best = math.max(best, rateOf(mode))
						break
					end
				end
			end
			xrandr.XRRFreeCrtcInfo(crtc)
		end
	end

	xrandr.XRRFreeScreenResources(resources)
	return best > 0 and best or nil
end

return refresh
