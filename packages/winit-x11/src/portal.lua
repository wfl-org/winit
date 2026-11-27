-- The desktop's file chooser through xdg-desktop-portal, spoken over D-Bus with libdbus.
--
-- Every current Linux desktop ships a portal backend (GNOME, KDE, LXQt, wlroots desktops, Flatpak
-- sandboxes), so this is tried before any chooser program. The call is modal like the programs
-- it replaces: it returns once the user picks or cancels. A missing libdbus, session bus or
-- portal answers `nil`, and the caller falls back to the programs.
local ffi = require("ffi")

ffi.cdef [[
typedef struct DBusConnection DBusConnection;
typedef struct DBusMessage DBusMessage;
typedef struct {
	const char *name;
	const char *message;
	unsigned int dummy1 : 1;
	unsigned int dummy2 : 1;
	unsigned int dummy3 : 1;
	unsigned int dummy4 : 1;
	unsigned int dummy5 : 1;
	void *padding1;
} DBusError;
typedef struct {
	void *dummy1;
	void *dummy2;
	uint32_t dummy3;
	int dummy4, dummy5, dummy6, dummy7, dummy8, dummy9, dummy10, dummy11;
	int pad1;
	void *pad2;
	void *pad3;
} DBusMessageIter;

void dbus_error_init(DBusError *error);
void dbus_error_free(DBusError *error);
uint32_t dbus_error_is_set(const DBusError *error);
DBusConnection *dbus_bus_get_private(int type, DBusError *error);
void dbus_connection_set_exit_on_disconnect(DBusConnection *connection, uint32_t exit);
void dbus_connection_close(DBusConnection *connection);
void dbus_connection_unref(DBusConnection *connection);
const char *dbus_bus_get_unique_name(DBusConnection *connection);
void dbus_bus_add_match(DBusConnection *connection, const char *rule, DBusError *error);
uint32_t dbus_connection_read_write(DBusConnection *connection, int timeout_milliseconds);
DBusMessage *dbus_connection_pop_message(DBusConnection *connection);
DBusMessage *dbus_connection_send_with_reply_and_block(DBusConnection *connection, DBusMessage *message, int timeout_milliseconds, DBusError *error);
DBusMessage *dbus_message_new_method_call(const char *destination, const char *path, const char *iface, const char *method);
void dbus_message_unref(DBusMessage *message);
uint32_t dbus_message_is_signal(DBusMessage *message, const char *iface, const char *signal_name);
const char *dbus_message_get_path(DBusMessage *message);
void dbus_message_iter_init_append(DBusMessage *message, DBusMessageIter *iter);
uint32_t dbus_message_iter_append_basic(DBusMessageIter *iter, int type, const void *value);
uint32_t dbus_message_iter_open_container(DBusMessageIter *iter, int type, const char *contained_signature, DBusMessageIter *sub);
uint32_t dbus_message_iter_close_container(DBusMessageIter *iter, DBusMessageIter *sub);
uint32_t dbus_message_iter_init(DBusMessage *message, DBusMessageIter *iter);
int dbus_message_iter_get_arg_type(DBusMessageIter *iter);
void dbus_message_iter_get_basic(DBusMessageIter *iter, void *value);
uint32_t dbus_message_iter_next(DBusMessageIter *iter);
void dbus_message_iter_recurse(DBusMessageIter *iter, DBusMessageIter *sub);
]]

local SESSION = 0
local TYPE_STRING = string.byte("s")
local TYPE_OBJECT_PATH = string.byte("o")
local TYPE_UINT32 = string.byte("u")
local TYPE_BOOLEAN = string.byte("b")
local TYPE_ARRAY = string.byte("a")
local TYPE_VARIANT = string.byte("v")
local TYPE_STRUCT = string.byte("r")
local TYPE_DICT_ENTRY = string.byte("e")

local DESTINATION = "org.freedesktop.portal.Desktop"
local OBJECT = "/org/freedesktop/portal/desktop"
local CHOOSER = "org.freedesktop.portal.FileChooser"
local REQUEST = "org.freedesktop.portal.Request"

-- How long the call itself may take to come back with its request handle (the dialog's answer
-- has no limit: the user may take as long as they like).
local CALL_TIMEOUT_MS = 5000

local Iter = ffi.typeof("DBusMessageIter[1]")
local Error = ffi.typeof("DBusError[1]")
local CString = ffi.typeof("const char*[1]")
local UInt = ffi.typeof("uint32_t[1]")

local portal = {}

local loaded, dbus = pcall(ffi.load, "dbus-1")
if not loaded then loaded, dbus = pcall(ffi.load, "libdbus-1.so.3") end
if not loaded then dbus = nil end

local tokens = 0

---@param iter ffi.cdata*
---@param value string
local function appendString(iter, value)
	local text = CString()
	text[0] = value
	dbus.dbus_message_iter_append_basic(iter, TYPE_STRING, text)
end

--- One `{sv}` entry of the options dictionary; `write` fills the variant.
---@param dict ffi.cdata*
---@param key string
---@param signature string
---@param write fun(variant: ffi.cdata*)
local function option(dict, key, signature, write)
	local entry, variant = Iter(), Iter()
	dbus.dbus_message_iter_open_container(dict, TYPE_DICT_ENTRY, nil, entry)
	appendString(entry, key)
	dbus.dbus_message_iter_open_container(entry, TYPE_VARIANT, signature, variant)
	write(variant)
	dbus.dbus_message_iter_close_container(entry, variant)
	dbus.dbus_message_iter_close_container(dict, entry)
end

---@param iter ffi.cdata*
---@param value boolean
local function appendBoolean(iter, value)
	local flag = UInt()
	flag[0] = value and 1 or 0
	dbus.dbus_message_iter_append_basic(iter, TYPE_BOOLEAN, flag)
end

--- `a(sa(us))`: each filter is a name and its glob patterns (type 0 = glob).
---@param iter ffi.cdata*
---@param filters winit.FileFilter[]
local function appendFilters(iter, filters)
	local list = Iter()
	dbus.dbus_message_iter_open_container(iter, TYPE_ARRAY, "(sa(us))", list)

	for _, filter in ipairs(filters) do
		local patterns = {} ---@type string[]
		for _, extension in ipairs(filter.extensions or {}) do
			extension = tostring(extension):gsub("^%.", "")
			if extension ~= "" then patterns[#patterns + 1] = "*." .. extension end
		end

		if #patterns > 0 then
			local struct, globs = Iter(), Iter()
			dbus.dbus_message_iter_open_container(list, TYPE_STRUCT, nil, struct)
			appendString(struct, filter.name or "Files")
			dbus.dbus_message_iter_open_container(struct, TYPE_ARRAY, "(us)", globs)

			for _, pattern in ipairs(patterns) do
				local glob = Iter()
				local kind = UInt()
				kind[0] = 0
				dbus.dbus_message_iter_open_container(globs, TYPE_STRUCT, nil, glob)
				dbus.dbus_message_iter_append_basic(glob, TYPE_UINT32, kind)
				appendString(glob, pattern)
				dbus.dbus_message_iter_close_container(globs, glob)
			end

			dbus.dbus_message_iter_close_container(struct, globs)
			dbus.dbus_message_iter_close_container(list, struct)
		end
	end

	dbus.dbus_message_iter_close_container(iter, list)
end

---@param filters winit.FileFilter[]?
---@return boolean
local function hasPatterns(filters)
	for _, filter in ipairs(filters or {}) do
		for _, extension in ipairs(filter.extensions or {}) do
			if tostring(extension):gsub("^%.", "") ~= "" then return true end
		end
	end
	return false
end

---@param iter ffi.cdata*
---@return string?
local function readString(iter)
	local kind = dbus.dbus_message_iter_get_arg_type(iter)
	if kind ~= TYPE_STRING and kind ~= TYPE_OBJECT_PATH then return nil end
	local text = CString()
	dbus.dbus_message_iter_get_basic(iter, text)
	return ffi.string(text[0])
end

--- `file:///a%20b` -> `/a b`. Anything that is not a local file is dropped.
---@param uri string
---@return string?
local function pathOf(uri)
	local rest = uri:match("^file://[^/]*(/.*)$")
	if rest == nil then return nil end
	return (rest:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16) or 63) end))
end

--- Reads `(u a{sv})` of a Response signal: the code and the chosen paths.
---@param message any # DBusMessage*
---@return integer code
---@return string[] paths
local function readResponse(message)
	local args = Iter()
	local paths = {}
	if dbus.dbus_message_iter_init(message, args) == 0 then return 2, paths end
	if dbus.dbus_message_iter_get_arg_type(args) ~= TYPE_UINT32 then return 2, paths end

	local code = UInt()
	dbus.dbus_message_iter_get_basic(args, code)
	if dbus.dbus_message_iter_next(args) == 0 then return tonumber(code[0]) --[[@as integer]], paths end

	local results = Iter()
	dbus.dbus_message_iter_recurse(args, results)

	while dbus.dbus_message_iter_get_arg_type(results) == TYPE_DICT_ENTRY do
		local entry = Iter()
		dbus.dbus_message_iter_recurse(results, entry)
		local key = readString(entry)

		if key == "uris" and dbus.dbus_message_iter_next(entry) ~= 0 then
			local variant, list = Iter(), Iter()
			dbus.dbus_message_iter_recurse(entry, variant)
			dbus.dbus_message_iter_recurse(variant, list)

			while dbus.dbus_message_iter_get_arg_type(list) == TYPE_STRING do
				local path = pathOf(readString(list) --[[@as string]])
				if path ~= nil then paths[#paths + 1] = path end
				dbus.dbus_message_iter_next(list)
			end
		end

		dbus.dbus_message_iter_next(results)
	end

	return tonumber(code[0]) --[[@as integer]], paths
end

--- The request object a call with this token will answer on, known before the call so the
--- match is in place before the portal can answer.
---@param connection any # DBusConnection*
---@param token string
---@return string
local function requestPath(connection, token)
	local sender = ffi.string(dbus.dbus_bus_get_unique_name(connection)):gsub("^:", ""):gsub("%.", "_")
	return OBJECT .. "/request/" .. sender .. "/" .. token
end

--- Asks the portal. Returns the chosen paths (empty when cancelled), or nil when there is no
--- portal to ask, so the caller can try something else.
---@param window { id: any }?
---@param opts winit.FileDialog.OpenOptions
---@param title string
---@return string[]?
function portal.open(window, opts, title)
	if dbus == nil then return nil end

	local err = Error()
	dbus.dbus_error_init(err)
	local connection = dbus.dbus_bus_get_private(SESSION, err)
	if connection == nil or dbus.dbus_error_is_set(err) ~= 0 then
		dbus.dbus_error_free(err)
		return nil
	end
	dbus.dbus_connection_set_exit_on_disconnect(connection, 0)

	tokens = tokens + 1
	local token = "winit" .. tostring(tokens) .. "_" .. tostring(os.time())
	local path = requestPath(connection, token)

	dbus.dbus_bus_add_match(connection,
		"type='signal',interface='" .. REQUEST .. "',member='Response',path='" .. path .. "'", err)
	-- libdbus refuses an error that is already set, so each call starts from a clear one.
	dbus.dbus_error_free(err)

	local call = dbus.dbus_message_new_method_call(DESTINATION, OBJECT, CHOOSER, "OpenFile")
	local args, dict = Iter(), Iter()
	dbus.dbus_message_iter_init_append(call, args)

	local parent = ""
	if window ~= nil and window.id ~= nil then
		parent = string.format("x11:%x", tonumber(ffi.cast("uint64_t", window.id)) or 0)
	end
	appendString(args, parent)
	appendString(args, title)

	dbus.dbus_message_iter_open_container(args, TYPE_ARRAY, "{sv}", dict)
	option(dict, "handle_token", "s", function(variant) appendString(variant, token) end)
	option(dict, "modal", "b", function(variant) appendBoolean(variant, true) end)
	option(dict, "multiple", "b", function(variant) appendBoolean(variant, opts.multiple == true) end)
	if opts.directory then
		option(dict, "directory", "b", function(variant) appendBoolean(variant, true) end)
	elseif hasPatterns(opts.filters) then
		option(dict, "filters", "a(sa(us))", function(variant) appendFilters(variant, opts.filters) end)
	end
	dbus.dbus_message_iter_close_container(args, dict)

	local reply = dbus.dbus_connection_send_with_reply_and_block(connection, call, CALL_TIMEOUT_MS, err)
	dbus.dbus_message_unref(call)

	local paths ---@type string[]?
	if reply == nil or dbus.dbus_error_is_set(err) ~= 0 then
		-- No portal on this bus, or no FileChooser in it.
		paths = nil
	else
		local handle = Iter()
		dbus.dbus_message_iter_init(reply, handle)
		-- Old portals ignore handle_token and answer on a path of their own.
		path = readString(handle) or path
		dbus.dbus_message_unref(reply)

		dbus.dbus_bus_add_match(connection,
			"type='signal',interface='" .. REQUEST .. "',member='Response',path='" .. path .. "'", err)
		dbus.dbus_error_free(err)

		paths = {}
		while true do
			if dbus.dbus_connection_read_write(connection, 250) == 0 then break end

			local message = dbus.dbus_connection_pop_message(connection)
			local answered = false
			while message ~= nil do
				if dbus.dbus_message_is_signal(message, REQUEST, "Response") ~= 0
					and ffi.string(dbus.dbus_message_get_path(message)) == path then
					local code, chosen = readResponse(message)
					if code == 0 then paths = chosen end
					answered = true
				end
				dbus.dbus_message_unref(message)
				if answered then break end
				message = dbus.dbus_connection_pop_message(connection)
			end
			if answered then break end
		end
	end

	dbus.dbus_error_free(err)
	dbus.dbus_connection_close(connection)
	dbus.dbus_connection_unref(connection)

	return paths
end

return portal
