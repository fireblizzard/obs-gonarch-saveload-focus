-- Gonarch Saveload Focus
-- Mutes distracting audio sources around the Gonarch saveload
-- Muted a few seconds after the "mute from" split starts
-- Unmuted a few seconds after the "unmute after" split starts
-- Load it in OBS from Tools > Scripts, nothing else to install

local obs = obslua
local ffi = require("ffi")
local bit = require("bit")

pcall(ffi.cdef, [[
typedef void* HANDLE;
HANDLE CreateFileA(const char*, uint32_t, uint32_t, void*, uint32_t, uint32_t, HANDLE);
int WriteFile(HANDLE, const void*, uint32_t, uint32_t*, void*);
int ReadFile(HANDLE, void*, uint32_t, uint32_t*, void*);
int PeekNamedPipe(HANDLE, void*, uint32_t, uint32_t*, uint32_t*, uint32_t*);
int CloseHandle(HANDLE);
]])
local k32 = ffi.load("kernel32")

local PIPE = "\\\\.\\pipe\\LiveSplit"
local GENERIC_RW = 0xC0000000
local OPEN_EXISTING = 3
local OBS_SOURCE_AUDIO = 2
local TICK_MS = 100
local TIMEOUT_TICKS = 20
local LIVESPLIT_GONE_NS = 10 * 1e9

local my_settings = nil
local start_pattern = ""
local end_pattern = ""
local mute_delay_ns = 0
local unmute_delay_ns = 0

local pipe = nil
local waiting = false
local waited = 0
local buffer = ""

-- asked to LiveSplit in turn, one per tick
local QUERIES = { "getcurrenttimerphase", "getcurrentsplitname" }
local query_index = 1
local timer_phase = nil

local current_split = nil
local mute_at = nil
local unmute_at = nil
local last_want = false
local lost_since = nil

local function log(msg)
    obs.script_log(obs.LOG_INFO, msg)
end

local function now_ns()
    return tonumber(obs.os_gettime_ns())
end

local function close_pipe()
    if pipe then k32.CloseHandle(pipe) end
    pipe, waiting, waited, buffer = nil, false, 0, ""
    query_index = 1
end

local function open_pipe()
    local h = k32.CreateFileA(PIPE, GENERIC_RW, 0, nil, OPEN_EXISTING, 0, nil)
    if ffi.cast("intptr_t", h) == -1 then return false end
    pipe = h
    return true
end

local function send(cmd)
    local data = cmd .. "\n"
    local written = ffi.new("uint32_t[1]")
    if k32.WriteFile(pipe, data, #data, written, nil) == 0 then
        close_pipe()
        return false
    end
    return true
end

-- returns a full line once it has arrived
-- never blocks OBS
local function try_read_line()
    local avail = ffi.new("uint32_t[1]")
    if k32.PeekNamedPipe(pipe, nil, 0, nil, avail, nil) == 0 then
        close_pipe()
        return nil
    end
    if avail[0] > 0 then
        local buf = ffi.new("char[?]", avail[0])
        local got = ffi.new("uint32_t[1]")
        if k32.ReadFile(pipe, buf, avail[0], got, nil) == 0 then
            close_pipe()
            return nil
        end
        buffer = buffer .. ffi.string(buf, got[0])
    end
    local line, rest = buffer:match("^(.-)\r?\n(.*)$")
    if line then
        buffer = rest
        return line
    end
    return nil
end

local function matches(name, pattern)
    return pattern ~= "" and name:lower():find(pattern, 1, true) ~= nil
end

-- calls fn for every source that has audio
local function each_audio_source(fn)
    local sources = obs.obs_enum_sources()
    if sources == nil then return end
    for _, s in ipairs(sources) do
        if bit.band(obs.obs_source_get_output_flags(s), OBS_SOURCE_AUDIO) ~= 0 then
            fn(s, obs.obs_source_get_name(s))
        end
    end
    obs.source_list_release(sources)
end

-- sources muted by this script, saved with the OBS settings
-- so they survive a reload or an OBS restart
local function load_ours()
    local ours = {}
    if my_settings == nil then return ours end
    for name in obs.obs_data_get_string(my_settings, "muted_by_script"):gmatch("[^\n]+") do
        table.insert(ours, name)
    end
    return ours
end

local function save_ours(ours)
    if my_settings then
        obs.obs_data_set_string(my_settings, "muted_by_script", table.concat(ours, "\n"))
    end
end

-- mutes the checked sources that aren't muted yet
-- sources the streamer muted by hand are left alone
local function mute_checked()
    local ours = load_ours()
    local checked = 0
    local names = {}
    each_audio_source(function(s, name)
        if my_settings and obs.obs_data_get_bool(my_settings, "mute_" .. name) then
            checked = checked + 1
            if not obs.obs_source_muted(s) then
                obs.obs_source_set_muted(s, true)
                table.insert(ours, name)
                table.insert(names, name)
            end
        end
    end)
    save_ours(ours)
    if checked == 0 then
        log("No sources are checked for muting")
    elseif #names > 0 then
        log("Muted " .. table.concat(names, ", "))
    end
end

-- unmutes only what this script muted
-- if the streamer already unmuted something by hand it stays as it is
local function unmute_ours()
    local names = {}
    for _, name in ipairs(load_ours()) do
        local s = obs.obs_get_source_by_name(name)
        if s then
            if obs.obs_source_muted(s) then
                obs.obs_source_set_muted(s, false)
                table.insert(names, name)
            end
            obs.obs_source_release(s)
        end
    end
    save_ours({})
    if #names > 0 then log("Unmuted " .. table.concat(names, ", ")) end
end

local function set_muted(want)
    if want then mute_checked() else unmute_ours() end
end

local function on_split_name(name)
    if name ~= current_split then
        current_split = name
        -- each countdown starts when its split begins
        mute_at = matches(name, start_pattern) and (now_ns() + mute_delay_ns) or nil
        unmute_at = matches(name, end_pattern) and (now_ns() + unmute_delay_ns) or nil
    end
end

local function update_mute()
    if current_split == nil then return end
    local now = now_ns()
    local want = (mute_at ~= nil and now >= mute_at)
        or (unmute_at ~= nil and now < unmute_at)
    -- only acts on changes so manual muting is respected
    if want ~= last_want then
        set_muted(want)
        last_want = want
    end
end

local function on_answer(query, line)
    if query == "getcurrenttimerphase" then
        if line ~= timer_phase then
            log("Timer " .. line)
            -- a reset always unmutes what this script muted
            if line == "NotRunning" and timer_phase ~= nil then
                set_muted(false)
                last_want = false
            end
        end
        timer_phase = line
        if line ~= "Running" then on_split_name("") end
        return
    end
    -- a stopped, paused or reset timer counts as being in no split
    if timer_phase ~= "Running" then line = "" end
    on_split_name(line)
end

-- LiveSplit unreachable for a while counts as closed
-- what the script muted gets unmuted
local function check_livesplit_gone()
    if timer_phase == nil then return end
    local now = now_ns()
    lost_since = lost_since or now
    if now - lost_since < LIVESPLIT_GONE_NS then return end
    log("LiveSplit closed")
    unmute_ours()
    last_want = false
    timer_phase, current_split, mute_at, unmute_at = nil, nil, nil, nil
end

local function poll_livesplit()
    if pipe == nil and not open_pipe() then
        check_livesplit_gone()
        return
    end
    lost_since = nil

    if waiting then
        local line = try_read_line()
        if line == nil then
            if pipe then
                waited = waited + 1
                if waited > TIMEOUT_TICKS then close_pipe() end
            end
            return
        end
        waiting = false
        on_answer(QUERIES[query_index], line)
        query_index = query_index % #QUERIES + 1
    end

    -- asks the next question right away
    if pipe and send(QUERIES[query_index]) then
        waiting, waited = true, 0
    end
end

local function tick()
    poll_livesplit()
    update_mute()
end

function script_description()
    return "<b>Gonarch Saveload Focus</b><br>" ..
           "Mutes the checked audio sources so the Gonarch's Lair load can be heard clearly.<br>" ..
           "Sources are muted a few seconds after the <i>mute from</i> split starts, " ..
           "and unmuted a few seconds after the <i>unmute after</i> split starts. " ..
           "Resetting the timer or closing LiveSplit unmutes them too."
end

function script_properties()
    local props = obs.obs_properties_create()
    obs.obs_properties_add_text(props, "split_info",
        "Split names are the ones in your LiveSplit splits. " ..
        "For example, if your Xen split is called \"viewsnap\" in LiveSplit, put \"viewsnap\". " ..
        "Part of the name is enough, and uppercase or lowercase doesn't matter (\"xen\" works for \"XEN\").",
        obs.OBS_TEXT_INFO)
    obs.obs_properties_add_text(props, "start_split",
        "Mute from split", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_float(props, "start_delay",
        "Seconds into that split before muting", 0, 600, 0.5)
    obs.obs_properties_add_text(props, "end_split",
        "Unmute after split", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_float(props, "delay",
        "Seconds into that split before unmuting", 0, 60, 0.5)
    each_audio_source(function(_, name)
        obs.obs_properties_add_bool(props, "mute_" .. name, "Mute " .. name)
    end)
    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_string(settings, "start_split", "Xen")
    obs.obs_data_set_default_double(settings, "start_delay", 0)
    obs.obs_data_set_default_string(settings, "end_split", "Gonarch")
    obs.obs_data_set_default_double(settings, "delay", 15)
end

local function clean(s)
    return s:match("^%s*(.-)%s*$"):lower()
end

function script_update(settings)
    start_pattern = clean(obs.obs_data_get_string(settings, "start_split"))
    end_pattern = clean(obs.obs_data_get_string(settings, "end_split"))
    mute_delay_ns = obs.obs_data_get_double(settings, "start_delay") * 1e9
    unmute_delay_ns = obs.obs_data_get_double(settings, "delay") * 1e9
end

function script_load(settings)
    my_settings = settings
    obs.timer_add(tick, TICK_MS)
end

function script_unload()
    obs.timer_remove(tick)
    -- doesn't leave anything muted by the script when it's removed or reloaded
    unmute_ours()
    last_want = false
    close_pipe()
end
