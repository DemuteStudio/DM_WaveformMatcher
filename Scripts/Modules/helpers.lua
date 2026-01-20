-- compareWaveform/helpers.lua
-- Utility functions used across modules

function Log(message, color)
    local timestamp = os.date("%H:%M:%S")
    local colored_msg = timestamp .. " - " .. message

    table.insert(report_log, {
        text = colored_msg,
        color = color or COLORS.WHITE
    })

    if #report_log > CONFIG.MAX_LOG_ENTRIES then
        table.remove(report_log, 1)
    end
end

function time_to_sample(time, sample_rate)
    return math.floor(time * sample_rate) + 1
end

function sample_to_time(sample, sample_rate)
    return (sample - 1) / sample_rate
end

function get_or_create_track(track_idx, track_name)
    local track = reaper.GetTrack(0, track_idx)

    if track then
        local _, existing_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
        if existing_name == track_name then
            return track, false  -- existing
        end
    end

    reaper.InsertTrackAtIndex(track_idx, false)
    track = reaper.GetTrack(0, track_idx)
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", track_name, true)
    return track, true  -- created
end

function GetItemName(item)
    local take = reaper.GetActiveTake(item)
    if take then
        local _, name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
        return name
    end
    return "Unnamed"
end

function GetTrack(item)
    return reaper.GetMediaItem_Track(item)
end

-- Normalize path separators to forward slashes (Windows Python accepts these)
-- This fixes "The specified path is invalid" errors caused by backslash escaping in shell commands
function NormalizePath(path)
    if not path then return "" end
    -- Replace all backslashes with forward slashes
    local normalized = path:gsub("\\", "/")
    -- Remove any duplicate slashes
    normalized = normalized:gsub("//+", "/")
    -- Remove trailing slash if present
    normalized = normalized:gsub("/$", "")
    return normalized
end
