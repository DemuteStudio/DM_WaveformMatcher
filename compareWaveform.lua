-- Voice Line Finder with ReaImGui
-- Matches edited clips to clean recording using local peak detection
-- Modified to prevent freezing with progress bar

-- Check if ReaImGui is available
if not reaper.ImGui_GetVersion then
    reaper.ShowMessageBox("ReaImGui extension is not installed!\n\nPlease install it from ReaPack.", "Error", 0)
    return
end

-- CONFIGURATION

-- Default values for TUNABLE parameters (used for reset functionality)
local TUNABLE_DEFAULTS = {
    peak_prominence = 0.3,
    min_peak_distance_ms = 30,
    num_match_tracks = 3,
    min_score = 0.0,
    stt_enabled = false,
    stt_weight = 0.5,
    stt_peak_threshold = 0.7,
    stt_max_duration = 10,
    mark_peaks = false,
    align_peaks = true,
    short_edit_threshold = 3.0,
    edited_extension = 4.0,
    require_pre_silence = false
}

local TUNABLE = {
    -- Peak Detection
    peak_prominence = 0.3,
    min_peak_distance_ms = 30,
    num_match_tracks = 3,
    -- Minimum Score Thresholds
    min_score = 0.0,
    -- Speech-to-Text
    stt_enabled = false,
    stt_weight = 0.5,  -- 0 = peaks only, 1 = STT only
    stt_peak_threshold = 0.7,  -- Minimum peak score to trigger STT verification
    stt_max_duration = 10,  -- Maximum seconds to transcribe per STT call
    -- Short Edit Extension (always enabled)
    short_edit_threshold = 3.0,  -- Extend items shorter than this (seconds)
    edited_extension = 4.0,  -- Amount to extend before and after (seconds)
    --debug
    mark_peaks = false,  -- Whether to add markers at detected peaks
    align_peaks = true,  -- Align matched items by first peak position
    -- Pre-silence filter
    require_pre_silence = false  -- Disqualify matches with peaks before match position
}

local TOOLTIPS = {
    peak_prominence = "How prominent peaks need to be (0-1). Lower = more peaks detected, higher = only strong peaks.",
    num_match_tracks = "Number of matched items/tracks to create.",
    min_peak_distance_ms = "Minimum time between peaks in milliseconds. Higher = fewer peaks, ignores rapid articulations.",
    min_score = "Minimum score required to accept match.",
    stt_enabled = "Enable speech-to-text comparison",
    stt_weight = "Balance between peak matching (0) and text matching (1).",
    stt_peak_threshold = "Minimum peak match score required before doing STT verification. Higher = fewer API calls, lower = more thorough.",
    stt_max_duration = "Maximum audio duration (seconds) to transcribe per STT call. Shorter = faster & cheaper. Recommended: 5-15s for voice lines.",
    short_edit_threshold = "Items shorter than this will read extended audio for better matching. Default: 3s.", 
    edited_extension = "Amount of audio (in seconds) to read before AND after short items. Default: 4 seconds.",
    mark_peaks = "If enabled, adds markers at detected peak positions in the audio items.",
    align_peaks = "Shift matched audio so first peaks align. Items start at same position but may be trimmed.",
    require_pre_silence = "Disqualify matches that have peaks before the match position (uses the same gap as the edited item's pre-peak silence)."
}

-- Keep non-tunable config separate
local CONFIG = {

    short_clip_threshold = 20, --Max number of peaks in edited clip to be considered 'short'.
    -- Matching Tolerances
    max_tolerance_short = 0.03, --Max time error (seconds) for peak matching in short clips. Lower = stricter timing required.
    max_tolerance_long = 0.15, --Max time error (seconds) for peak matching in long clips. Lower = stricter timing required.
    -- Penalties
    missing_peak_penalty_short = 1.7, --Score penalty when an edited peak has no match in clean (short clips). Higher = stricter.
    missing_peak_penalty_long = 0.5, --Score penalty when an edited peak has no match in clean (long clips). Higher = stricter.
    extra_peak_penalty_short = 1.5, --Score penalty per extra clean peak not in edited (short clips). Higher = penalizes noise more.
    extra_peak_penalty_long = 0.2, --Score penalty per extra clean peak not in edited (long clips). Higher = penalizes noise more.
    extra_peak_penalty_very_short = 1.5, --Score penalty per extra peak in very short clips (≤2 peaks). Usually kept low.
    envelope_mismatch_penalty = 0.5, --Score penalty when one recording is loud but the other is silent. Higher = stricter.

    DOWNSAMPLE_FACTOR = 4,
    ENVELOPE_ATTACK_TIME = 0.003,
    ENVELOPE_RELEASE_TIME = 0.050,
    SMOOTH_WINDOW_MS = 20,
    VERY_SHORT_CLIP_THRESHOLD = 2,
    ENVELOPE_CHECK_SAMPLES = 5,
    ENVELOPE_WINDOW_MS = 150,
    ENVELOPE_MISMATCH_THRESHOLD = 0.6,
    MIN_PEAKS_RATIO_SHORT = 0.75, -- Minimum ratio of matched peaks to total peaks for short clips
    MIN_PEAKS_RATIO_LONG = 0.5,
    FILTER_DISTANCE_SHORT = 1.0,
    FILTER_DISTANCE_LONG = 1.0,
    MAX_LOG_ENTRIES = 50,
    AUDIO_CHUNK_SIZE = 1000000,
    TOLERANCE_BUFFER_SHORT = 0.02,
    TOLERANCE_BUFFER_LONG = 0.3,
-- Envelope Detection
    ENVELOPE_SILENCE_THRESHOLD = 0.1,
    ENVELOPE_ACTIVE_THRESHOLD = 0.3,
    MAX_ENVELOPE_MISMATCH_SHORT = 0.5,
    MAX_ENVELOPE_MISMATCH_LONG = 1.0,
-- Amplitude Weighting
    AMP_WEIGHT_SHORT = 0.4,
    AMP_WEIGHT_LONG = 0.15,
    POSITION_WEIGHT_SHORT = 1.5,
    POSITION_WEIGHT_LONG = 1.2,
-- Speech-to-Text
    STT_TEMP_DIR = (os.getenv("TEMP") or os.getenv("TMP") or "."):gsub("\\", "/"):gsub("//+", "/"):gsub("/$", ""),
    STT_SAMPLE_RATE = 16000  -- preferred sample rate
}

-- STT settings (editable in UI, persisted via ExtState)
local EXT_SECTION = "VoiceLineMatcher"  -- Section name for ExtState

local function LoadSettings()
    local settings = {
        -- Common settings
        engine = "azure",  -- Default to azure for backward compatibility
        language = "en-US",
        python_path = "python",

        -- Azure settings
        azure_key = "",
        region = "westeurope",

        -- Google Cloud settings
        google_credentials_path = "",

        -- Whisper settings
        whisper_model = "base",

        -- Vosk settings
        vosk_model_path = ""
    }

    -- Try to load from ExtState first (user-entered values)
    local saved_engine = reaper.GetExtState(EXT_SECTION, "stt_engine")
    local saved_python_path = reaper.GetExtState(EXT_SECTION, "python_path")
    local saved_key = reaper.GetExtState(EXT_SECTION, "azure_key")
    local saved_lang = reaper.GetExtState(EXT_SECTION, "language")
    local saved_region = reaper.GetExtState(EXT_SECTION, "region")
    local saved_google_creds = reaper.GetExtState(EXT_SECTION, "google_credentials_path")
    local saved_whisper_model = reaper.GetExtState(EXT_SECTION, "whisper_model")
    local saved_vosk_model_path = reaper.GetExtState(EXT_SECTION, "vosk_model_path")

    local saved_peak_prominence = reaper.GetExtState(EXT_SECTION, "peak_prominence")
    local saved_min_peak_distance_ms = reaper.GetExtState(EXT_SECTION, "min_peak_distance_ms")
    local saved_num_match_tracks = reaper.GetExtState(EXT_SECTION, "num_match_tracks")
    local saved_min_score = reaper.GetExtState(EXT_SECTION, "min_score")
    local saved_stt_enabled = reaper.GetExtState(EXT_SECTION, "stt_enabled")
    local saved_stt_weight = reaper.GetExtState(EXT_SECTION, "stt_weight")
    local saved_stt_peak_threshold = reaper.GetExtState(EXT_SECTION, "stt_peak_threshold")
    local saved_stt_max_duration = reaper.GetExtState(EXT_SECTION, "stt_max_duration")
    local saved_mark_peaks = reaper.GetExtState(EXT_SECTION, "mark_peaks")
    local saved_align_peaks = reaper.GetExtState(EXT_SECTION, "align_peaks")
    local saved_short_edit_threshold = reaper.GetExtState(EXT_SECTION, "short_edit_threshold")
    local saved_edited_extension = reaper.GetExtState(EXT_SECTION, "edited_extension")
    local saved_require_pre_silence = reaper.GetExtState(EXT_SECTION, "require_pre_silence")

    -- Use saved values if they exist, otherwise fall back to env var / defaults
    if saved_key ~= "" then
        settings.azure_key = saved_key
    else
        settings.azure_key = os.getenv("AZUREKEY") or ""
    end

    if saved_lang ~= "" then
        settings.language = saved_lang
    end

    if saved_region ~= "" then
        settings.region = saved_region
    end

    -- Load new engine settings
    if saved_engine ~= "" then
        settings.engine = saved_engine
    end

    if saved_python_path ~= "" then
        settings.python_path = saved_python_path
    end

    if saved_google_creds ~= "" then
        settings.google_credentials_path = saved_google_creds
    end

    if saved_whisper_model ~= "" then
        settings.whisper_model = saved_whisper_model
    end

    if saved_vosk_model_path ~= "" then
        settings.vosk_model_path = saved_vosk_model_path
    end

    if saved_peak_prominence ~= "" then
        TUNABLE.peak_prominence = tonumber(saved_peak_prominence) or TUNABLE.peak_prominence
    end
    if saved_min_peak_distance_ms ~= "" then
        TUNABLE.min_peak_distance_ms = tonumber(saved_min_peak_distance_ms) or TUNABLE.min_peak_distance_ms
    end
    if saved_num_match_tracks ~= "" then
        TUNABLE.num_match_tracks = tonumber(saved_num_match_tracks) or TUNABLE.num_match_tracks
    end
    if saved_min_score ~= "" then
        TUNABLE.min_score = tonumber(saved_min_score) or TUNABLE.min_score
    end
    if saved_stt_enabled ~= "" then
        TUNABLE.stt_enabled = (saved_stt_enabled == "true")
    end
    if saved_stt_weight ~= "" then
        TUNABLE.stt_weight = tonumber(saved_stt_weight) or TUNABLE.stt_weight
    end
    if saved_stt_peak_threshold ~= "" then
        TUNABLE.stt_peak_threshold = tonumber(saved_stt_peak_threshold) or TUNABLE.stt_peak_threshold
    end
    if saved_stt_max_duration ~= "" then
        TUNABLE.stt_max_duration = tonumber(saved_stt_max_duration) or TUNABLE.stt_max_duration
    end
    if saved_mark_peaks ~= "" then
        TUNABLE.mark_peaks = (saved_mark_peaks == "true")
    end
    if saved_align_peaks ~= "" then
        TUNABLE.align_peaks = (saved_align_peaks == "true")
    end
    if saved_short_edit_threshold ~= "" then
        TUNABLE.short_edit_threshold = tonumber(saved_short_edit_threshold) or TUNABLE.short_edit_threshold
    end
    if saved_edited_extension ~= "" then
        TUNABLE.edited_extension = tonumber(saved_edited_extension) or TUNABLE.edited_extension
    end
    if saved_require_pre_silence ~= "" then
        TUNABLE.require_pre_silence = (saved_require_pre_silence == "true")
    end

    return settings
end

local function SaveSettings(settings)
    -- persist = true means save to reaper.ini (survives restart)
    if settings then
        -- Save common settings
        reaper.SetExtState(EXT_SECTION, "stt_engine", settings.engine, true)
        reaper.SetExtState(EXT_SECTION, "python_path", settings.python_path, true)
        reaper.SetExtState(EXT_SECTION, "language", settings.language, true)

        -- Save Azure settings
        reaper.SetExtState(EXT_SECTION, "azure_key", settings.azure_key, true)
        reaper.SetExtState(EXT_SECTION, "region", settings.region, true)

        -- Save Google Cloud settings
        reaper.SetExtState(EXT_SECTION, "google_credentials_path", settings.google_credentials_path, true)

        -- Save Whisper settings
        reaper.SetExtState(EXT_SECTION, "whisper_model", settings.whisper_model, true)

        -- Save Vosk settings
        reaper.SetExtState(EXT_SECTION, "vosk_model_path", settings.vosk_model_path, true)
    end

    reaper.SetExtState(EXT_SECTION, "peak_prominence", tostring(TUNABLE.peak_prominence), true)
    reaper.SetExtState(EXT_SECTION, "min_peak_distance_ms", tostring(TUNABLE.min_peak_distance_ms), true)
    reaper.SetExtState(EXT_SECTION, "num_match_tracks", tostring(TUNABLE.num_match_tracks), true)
    reaper.SetExtState(EXT_SECTION, "min_score", tostring(TUNABLE.min_score), true)
    reaper.SetExtState(EXT_SECTION, "stt_enabled", tostring(TUNABLE.stt_enabled), true)
    reaper.SetExtState(EXT_SECTION, "stt_weight", tostring(TUNABLE.stt_weight), true)
    reaper.SetExtState(EXT_SECTION, "stt_peak_threshold", tostring(TUNABLE.stt_peak_threshold), true)
    reaper.SetExtState(EXT_SECTION, "stt_max_duration", tostring(TUNABLE.stt_max_duration), true)
    reaper.SetExtState(EXT_SECTION, "mark_peaks", tostring(TUNABLE.mark_peaks), true)
    reaper.SetExtState(EXT_SECTION, "align_peaks", tostring(TUNABLE.align_peaks), true)
    reaper.SetExtState(EXT_SECTION, "short_edit_threshold", tostring(TUNABLE.short_edit_threshold), true)
    reaper.SetExtState(EXT_SECTION, "edited_extension", tostring(TUNABLE.edited_extension), true)
    reaper.SetExtState(EXT_SECTION, "require_pre_silence", tostring(TUNABLE.require_pre_silence), true)
end

local STT_SETTINGS = LoadSettings()

local COLORS = {
    RED = {1, 0.2, 0.2, 1},
    GREEN = {0.2, 1, 0.2, 1},
    YELLOW = {1, 1, 0.2, 1},
    CYAN = {0.2, 0.8, 1, 1},
    GRAY = {0.7, 0.7, 0.7, 1},
    WHITE = {1, 1, 1, 1},
    ORANGE = {1, 0.6, 0.2, 1}
}

local function ResetToDefaults()
    -- Reset all TUNABLE parameters to default values
    for key, default_value in pairs(TUNABLE_DEFAULTS) do
        if key ~= "stt_enabled" then
            TUNABLE[key] = default_value
        end

    end

    -- Save the reset values
    SaveSettings(STT_SETTINGS)

    Log("All settings reset to default values", COLORS.GREEN)
end


-- Helper function to create fresh state structures
local function create_audio_load_state()
    return {
        item = nil, take = nil, accessor = nil,
        source_sample_rate = nil, num_channels = nil, num_samples = 0,
        current_chunk = 0, total_chunks = 0, audio = nil, buffer = nil,
        progress_percent = 0
    }
end

local function create_peak_detect_state()
    return {
        phase = "downsample", chunk_index = 1, chunk_size = 50000,
        downsampled = nil, envelope = nil, smoothed = nil, all_peaks = nil,
        ds_sample_rate = nil, prominence = nil, total_chunks = 0,
        progress_percent = 0, smooth_window_sum = 0, smooth_window_count = 0,
        find_peaks_subphase = "calc_threshold", sorted_envelope = nil,
        threshold = nil, max_val = 0
    }
end

-- STATE

local ctx = reaper.ImGui_CreateContext('Voice Line Matcher')
local edited_items = {}
local clean_items = {}  -- Changed from single item to array
local report_log = {}
local is_processing = false
local cancel_requested = false

-- Progress tracking state
local processing_state = {
    active = false, current_item = 0, total_items = 0,
    current_phase = "", current_item_name = "",
    -- Clean recordings data (arrays for multiple clean items)
    current_clean_item = 0,
    clean_items_peaks = {},
    clean_items_envelope_data = {},
    clean_items_sr = {},
    -- STT data for current edited item
    edited_stt = nil,  -- {text: "...", confidence: 0.0}
    -- STT verification state (for progress tracking)
    stt_all_matches = nil,           -- All matches found for current item
    stt_candidates_to_verify = 0,    -- How many to verify with STT
    stt_current_candidate = 0,       -- Current candidate being verified
    stt_edited_duration = 0,         -- Duration of edited item (for region export)
    target_tracks = nil, success_count = 0, fail_count = 0, undo_started = false,
    temp_audio = nil, temp_sr = nil, temp_offset = nil,
    temp_peaks = nil, temp_envelope_data = nil,
    audio_load_state = create_audio_load_state(),
    peak_detect_state = create_peak_detect_state()
}


-- UTILITY FUNCTIONS


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

local function time_to_sample(time, sample_rate)
    return math.floor(time * sample_rate) + 1
end

local function sample_to_time(sample, sample_rate)
    return (sample - 1) / sample_rate
end

local function get_or_create_track(track_idx, track_name)
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

-- SPEECH-TO-TEXT FUNCTIONS

-- Export audio item to temp WAV file (16kHz mono for Azure STT)
-- STT duration limit is now controlled by TUNABLE.stt_max_duration (default 10s)
local EXPORT_CHUNK_SIZE = 100000  -- samples per chunk to avoid reaper.new_array limits

-- Export audio item (or portion) to temp WAV file
-- start_offset and duration are optional - if not provided, exports entire item
function ExportItemToWav(item, start_offset, duration)
    local take = reaper.GetActiveTake(item)
    if not take then return nil end

    local source = reaper.GetMediaItemTake_Source(take)
    if not source then return nil end

    local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

    -- Use provided start_offset or default to 0
    start_offset = start_offset or 0
    -- Use provided duration or remaining item length
    duration = duration or (item_len - start_offset)

    -- Cap duration to user-configured limit (reduces API costs & speeds up processing)
    if duration > TUNABLE.stt_max_duration then
        duration = TUNABLE.stt_max_duration
    end

    -- Ensure we don't exceed item bounds
    if start_offset + duration > item_len then
        duration = item_len - start_offset
    end

    if duration <= 0 then return nil end

    -- Create temp file path (use forward slash - works on Windows and avoids shell escaping issues)
    local temp_path = CONFIG.STT_TEMP_DIR .. "/stt_temp_" .. tostring(os.time()) .. "_" ..
                      tostring(math.random(10000)) .. ".wav"

    -- Use audio accessor to get samples at 16kHz
    local sr = CONFIG.STT_SAMPLE_RATE
    local num_samples = math.floor(duration * sr)

    if num_samples <= 0 then return nil end

    local accessor = reaper.CreateTakeAudioAccessor(take)
    if not accessor then return nil end

    -- Write WAV file (16-bit PCM mono)
    local f = io.open(temp_path, "wb")
    if not f then
        reaper.DestroyAudioAccessor(accessor)
        return nil
    end

    local data_size = num_samples * 2

    -- WAV header
    f:write("RIFF")
    f:write(string.pack("<I4", 36 + data_size))  -- File size - 8
    f:write("WAVEfmt ")
    f:write(string.pack("<I4", 16))   -- Subchunk1 size
    f:write(string.pack("<I2", 1))    -- Audio format (PCM)
    f:write(string.pack("<I2", 1))    -- Num channels (mono)
    f:write(string.pack("<I4", sr))   -- Sample rate
    f:write(string.pack("<I4", sr * 2))  -- Byte rate
    f:write(string.pack("<I2", 2))    -- Block align
    f:write(string.pack("<I2", 16))   -- Bits per sample
    f:write("data")
    f:write(string.pack("<I4", data_size))

    -- Export in chunks to avoid reaper.new_array size limits
    local samples_written = 0
    local buffer = reaper.new_array(EXPORT_CHUNK_SIZE)
    local max_sample_value = 0  -- Track if audio has actual content

    while samples_written < num_samples do
        local chunk_samples = math.min(EXPORT_CHUNK_SIZE, num_samples - samples_written)
        -- Read from the specified position relative to the take
        -- The audio accessor is already positioned relative to the take, not the raw source
        -- start_offset = where to start within the item
        local read_time = start_offset + (samples_written / sr)

        buffer.clear()
        reaper.GetAudioAccessorSamples(accessor, sr, 1, read_time, chunk_samples, buffer)

        -- Write samples as 16-bit
        for i = 1, chunk_samples do
            local sample = math.max(-1, math.min(1, buffer[i]))
            max_sample_value = math.max(max_sample_value, math.abs(sample))
            local int_sample = math.floor(sample * 32767)
            f:write(string.pack("<i2", int_sample))
        end

        samples_written = samples_written + chunk_samples
    end

    -- Warn if audio appears to be silent
    if max_sample_value < 0.01 then
        Log(string.format("  WARNING: Exported audio appears silent (max level: %.4f)", max_sample_value), COLORS.YELLOW)
    end

    reaper.DestroyAudioAccessor(accessor)
    f:close()
    return temp_path
end

-- MULTI-ENGINE STT FUNCTIONS

-- Get the directory path of the current script
function GetScriptPath()
    local info = debug.getinfo(1, 'S')
    local script_path = info.source:match("@?(.*[/\\])")
    -- Normalize to forward slashes
    if script_path then
        script_path = script_path:gsub("\\", "/")
    end
    return script_path or ""
end

-- Get engine index from engine ID for UI dropdown
function GetEngineIndex(engine_id, engine_ids)
    for i, id in ipairs(engine_ids) do
        if id == engine_id then
            return i
        end
    end
    return 3  -- Default to Azure (index 3) if not found
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

-- Build STT command based on engine type
function BuildSTTCommand(python, script, wav, config)
    -- Normalize all paths to forward slashes to avoid shell escaping issues
    local norm_script = NormalizePath(script)
    local norm_wav = NormalizePath(wav)

    local args = {
        python,  -- Don't quote executable - cmd.exe needs unquoted command name
        string.format('"%s"', norm_script),
        "--engine", config.engine,
        "--wav", string.format('"%s"', norm_wav),
        "--language", config.language
    }

    -- Add engine-specific arguments
    if config.engine == "azure" then
        table.insert(args, "--subscription_key")
        table.insert(args, string.format('"%s"', config.azure_key))
        table.insert(args, "--region")
        table.insert(args, config.region)
    elseif config.engine == "google_cloud" then
        table.insert(args, "--credentials_json")
        table.insert(args, string.format('"%s"', config.google_credentials_path))
    elseif config.engine == "whisper" then
        table.insert(args, "--model")
        table.insert(args, config.whisper_model or "base")
    elseif config.engine == "vosk" then
        table.insert(args, "--model_path")
        table.insert(args, string.format('"%s"', config.vosk_model_path))
    end
    -- Note: google engine needs no additional args

    return table.concat(args, " ")
end

-- Parse STT JSON response from Python script
function ParseSTTResponse(json_str, exit_code, engine)
    if not json_str or json_str == "" then
        Log(string.format("ERROR: Empty response from STT engine '%s'", engine), COLORS.RED)
        return nil
    end

    -- Simple JSON parsing (looking for success, text, confidence fields)
    local success = json_str:match('"success"%s*:%s*true')

    if not success then
        local error_msg = json_str:match('"error"%s*:%s*"([^"]*)"')
        if error_msg then
            Log(string.format("  STT Error (%s): %s", engine, error_msg), COLORS.YELLOW)
        else
            -- Try to extract useful error from output (limit to 200 chars)
            local preview = json_str:sub(1, 200):gsub("\n", " ")
            Log(string.format("  STT failed (%s): %s", engine, preview), COLORS.YELLOW)
        end
        return nil
    end

    local text = json_str:match('"text"%s*:%s*"([^"]*)"')
    local confidence = tonumber(json_str:match('"confidence"%s*:%s*([%d%.]+)')) or 0

    if not text or text == "" then
        return nil
    end

    return {
        text = text:lower(),
        confidence = confidence
    }
end

-- Generic STT transcription function that works with multiple engines
-- @param wav_path: Path to 16kHz WAV file
-- @param engine_config: Optional override config (defaults to STT_SETTINGS)
-- @return: {text=string, confidence=number} or nil on error
function TranscribeWithEngine(wav_path, engine_config)
    local config = engine_config or STT_SETTINGS
    local engine = config.engine or "azure"

    -- Build Python command based on engine type
    local python_path = config.python_path or "python"
    local script_path = GetScriptPath() .. "stt_transcribe.py"

    -- Normalize WAV path to forward slashes (defense-in-depth)
    local normalized_wav_path = NormalizePath(wav_path)

    -- Build command args based on engine
    local cmd = BuildSTTCommand(python_path, script_path, normalized_wav_path, config)

    -- Log the engine being used (without sensitive data)
    Log(string.format("  Calling STT engine: %s", engine), COLORS.GRAY)

    -- Execute and capture stdout/stderr
    local handle = io.popen(cmd .. " 2>&1")
    if not handle then
        Log(string.format("ERROR: Failed to execute STT command for engine '%s'", engine), COLORS.RED)
        return nil
    end

    local result = handle:read("*a")
    local success, exit_type, exit_code = handle:close()

    -- Parse JSON result
    return ParseSTTResponse(result, exit_code, engine)
end

-- Validate STT setup (Python, dependencies, script)
function ValidateSTTSetup()
    local python = STT_SETTINGS.python_path or "python"
    local script_path = GetScriptPath() .. "stt_transcribe.py"

    -- Check if Python is available
    local handle = io.popen(python .. " --version 2>&1")
    if not handle then
        Log("ERROR: Cannot execute Python. Check python_path in settings.", COLORS.RED)
        return false
    end

    local version = handle:read("*a")
    local success = handle:close()

    if not success then
        Log("ERROR: Python not found. Install Python or set correct path in settings.", COLORS.RED)
        return false
    end

    Log("  Python found: " .. version:gsub("\n", ""), COLORS.GRAY)

    -- Check if script exists
    local f = io.open(script_path, "r")
    if not f then
        Log("ERROR: stt_transcribe.py not found. Place it in the same directory as this script.", COLORS.RED)
        return false
    end
    f:close()

    -- Check if SpeechRecognition is installed
    handle = io.popen(python .. " -c \"import speech_recognition\" 2>&1")
    if not handle then
        Log("WARNING: Cannot check SpeechRecognition installation.", COLORS.YELLOW)
        return true  -- Continue anyway
    end

    local result = handle:read("*a")
    success = handle:close()

    if not success then
        Log("WARNING: SpeechRecognition not installed. Run: pip install SpeechRecognition", COLORS.YELLOW)
        Log("  " .. result:gsub("\n", " "):sub(1, 200), COLORS.GRAY)
        return false
    end

    Log("  SpeechRecognition library found", COLORS.GRAY)
    return true
end

-- TEXT SIMILARITY FUNCTIONS

-- Prefix-weighted similarity: prioritizes matching first words (for sync detection)
-- Combines prefix score (60%) with overall Jaccard score (40%)
-- Filters out filler words before comparison
function TextSimilarity(text1, text2)
    if not text1 or not text2 or text1 == "" or text2 == "" then
        return 0
    end

    -- Normalize: lowercase, remove punctuation
    local t1 = text1:lower():gsub("[^%w%s]", "")
    local t2 = text2:lower():gsub("[^%w%s]", "")

    -- Build word arrays (ordered) and sets (for Jaccard)
    local words1 = {}
    local set1 = {}
    for word in t1:gmatch("%S+") do
        words1[#words1 + 1] = word
        set1[word] = true
    end

    local words2 = {}
    local set2 = {}
    for word in t2:gmatch("%S+") do
        words2[#words2 + 1] = word
        set2[word] = true
    end

    if #words1 == 0 or #words2 == 0 then return 0 end

    -- 1. PREFIX SCORE: Check first N words match in order
    local prefix_len = math.min(4, #words1, #words2)  -- Check first 4 words
    local prefix_matches = 0
    for i = 1, prefix_len do
        if words1[i] == words2[i] then
            prefix_matches = prefix_matches + 1
        else
            break  -- Stop at first mismatch (order matters)
        end
    end
    local prefix_score = prefix_matches / prefix_len

    -- 2. JACCARD SCORE: Overall word overlap
    local intersection = 0
    for word in pairs(set1) do
        if set2[word] then
            intersection = intersection + 1
        end
    end
    local union = #words1 + #words2 - intersection
    local jaccard_score = union > 0 and (intersection / union) or 0

    -- 3. COMBINE: Prefix is more important (60% prefix, 40% Jaccard)
    local PREFIX_WEIGHT = 0.2
    local combined = (prefix_score * PREFIX_WEIGHT) + (jaccard_score * (1 - PREFIX_WEIGHT))

    return combined
end

-- UI HELPER FUNCTIONS FOR STT CONFIGURATION

function RenderAzureSettings(ctx)
    -- API Key
    reaper.ImGui_TableNextRow(ctx)
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_Text(ctx, "API Key:")
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    local key_changed, new_key = reaper.ImGui_InputText(ctx, "##azure_key",
        STT_SETTINGS.azure_key, reaper.ImGui_InputTextFlags_Password())
    if key_changed then
        STT_SETTINGS.azure_key = new_key
        SaveSettings(STT_SETTINGS)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Your Azure Speech Services API key")
    end

    -- Region
    reaper.ImGui_TableNextRow(ctx)
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_Text(ctx, "Region:")
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    local region_changed, new_region = reaper.ImGui_InputText(ctx, "##azure_region", STT_SETTINGS.region)
    if region_changed then
        STT_SETTINGS.region = new_region
        SaveSettings(STT_SETTINGS)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Azure region (e.g., westeurope, eastus)")
    end
end

function RenderGoogleCloudSettings(ctx)
    reaper.ImGui_TableNextRow(ctx)
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_Text(ctx, "Credentials JSON:")
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    local path_changed, new_path = reaper.ImGui_InputText(ctx, "##google_creds",
        STT_SETTINGS.google_credentials_path)
    if path_changed then
        STT_SETTINGS.google_credentials_path = new_path
        SaveSettings(STT_SETTINGS)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Path to Google Cloud service account JSON file")
    end
end

function RenderWhisperSettings(ctx)
    reaper.ImGui_TableNextRow(ctx)
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_Text(ctx, "Model Size:")
    reaper.ImGui_TableNextColumn(ctx)

    local models = {"tiny", "base", "small", "medium", "large"}
    local current_model = STT_SETTINGS.whisper_model or "base"
    local current_idx = 2  -- default to base

    for i, model in ipairs(models) do
        if model == current_model then
            current_idx = i
            break
        end
    end

    reaper.ImGui_SetNextItemWidth(ctx, -1)
    if reaper.ImGui_BeginCombo(ctx, "##whisper_model", current_model) then
        for i, model in ipairs(models) do
            local is_selected = (i == current_idx)
            if reaper.ImGui_Selectable(ctx, model, is_selected) then
                STT_SETTINGS.whisper_model = model
                SaveSettings(STT_SETTINGS)
            end
            if is_selected then
                reaper.ImGui_SetItemDefaultFocus(ctx)
            end
        end
        reaper.ImGui_EndCombo(ctx)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Larger models = more accurate but slower. First use downloads model.")
    end
end

function RenderVoskSettings(ctx)
    reaper.ImGui_TableNextRow(ctx)
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_AlignTextToFramePadding(ctx)
    reaper.ImGui_Text(ctx, "Model Path:")
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    local path_changed, new_path = reaper.ImGui_InputText(ctx, "##vosk_model",
        STT_SETTINGS.vosk_model_path)
    if path_changed then
        STT_SETTINGS.vosk_model_path = new_path
        SaveSettings(STT_SETTINGS)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, "Path to Vosk model directory (download from alphacephei.com/vosk/models)")
    end
end

function RenderEngineSettings(ctx, engine)
    if reaper.ImGui_BeginTable(ctx, "engine_settings", 2) then
        reaper.ImGui_TableSetupColumn(ctx, "label", reaper.ImGui_TableColumnFlags_WidthFixed(), 140)
        reaper.ImGui_TableSetupColumn(ctx, "input", reaper.ImGui_TableColumnFlags_WidthStretch())

        if engine == "azure" then
            RenderAzureSettings(ctx)
        elseif engine == "google_cloud" then
            RenderGoogleCloudSettings(ctx)
        elseif engine == "whisper" then
            RenderWhisperSettings(ctx)
        elseif engine == "vosk" then
            RenderVoskSettings(ctx)
        elseif engine == "google" then
            reaper.ImGui_TableNextRow(ctx)
            reaper.ImGui_TableNextColumn(ctx)
            reaper.ImGui_TextWrapped(ctx, "No configuration needed!")
            reaper.ImGui_TableNextColumn(ctx)
            reaper.ImGui_TextWrapped(ctx, "Uses free Google Speech Recognition API")
        end

        reaper.ImGui_EndTable(ctx)
    end
end

function RenderCommonSTTSettings(ctx, avail_width, slicerRightSpece)
    reaper.ImGui_Spacing(ctx)

    -- Language setting
    if reaper.ImGui_BeginTable(ctx, "common_settings", 2) then
        reaper.ImGui_TableSetupColumn(ctx, "label", reaper.ImGui_TableColumnFlags_WidthFixed(), 140)
        reaper.ImGui_TableSetupColumn(ctx, "input", reaper.ImGui_TableColumnFlags_WidthStretch())

        reaper.ImGui_TableNextRow(ctx)
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_AlignTextToFramePadding(ctx)
        reaper.ImGui_Text(ctx, "Language:")
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_SetNextItemWidth(ctx, -1)
        local lang_changed, new_lang = reaper.ImGui_InputText(ctx, "##language", STT_SETTINGS.language)
        if lang_changed then
            STT_SETTINGS.language = new_lang
            SaveSettings(STT_SETTINGS)
        end
        if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, "Language code (e.g., en-US, de-DE)")
        end

        reaper.ImGui_EndTable(ctx)
    end

    reaper.ImGui_Spacing(ctx)

    -- Sliders
    reaper.ImGui_SetNextItemWidth(ctx, avail_width - slicerRightSpece)
    local weight_changed, new_weight = reaper.ImGui_SliderDouble(ctx, "STT Weight", TUNABLE.stt_weight, 0.0, 1.0, "%.2f")
    if weight_changed then
        TUNABLE.stt_weight = new_weight
        SaveSettings(STT_SETTINGS)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, TOOLTIPS.stt_weight)
    end

    reaper.ImGui_SetNextItemWidth(ctx, avail_width - slicerRightSpece)
    local threshold_changed, new_threshold = reaper.ImGui_SliderDouble(ctx, "Peak Threshold", TUNABLE.stt_peak_threshold, 0.0, 1.0, "%.2f")
    if threshold_changed then
        TUNABLE.stt_peak_threshold = new_threshold
        SaveSettings(STT_SETTINGS)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, TOOLTIPS.stt_peak_threshold)
    end

    reaper.ImGui_SetNextItemWidth(ctx, avail_width - slicerRightSpece)
    local max_dur_changed, new_max_dur = reaper.ImGui_SliderInt(ctx, "Max Duration (s)", TUNABLE.stt_max_duration, 1, 60)
    if max_dur_changed then
        TUNABLE.stt_max_duration = new_max_dur
        SaveSettings(STT_SETTINGS)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, TOOLTIPS.stt_max_duration)
    end
end

-- REAPER ITEM FUNCTIONS

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

function AddMarkersToItem(item, transients, color, pre_extension_offset)
    local take = reaper.GetActiveTake(item)
    if not take then return false, 0 end

    -- Clear existing markers
    for i = reaper.GetNumTakeMarkers(take) - 1, 0, -1 do
        reaper.DeleteTakeMarker(take, i)
    end

    local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local take_offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local offset = pre_extension_offset or 0  -- Offset for extended short edits

    local marker_color = color or 0
    local added = 0

    for _, transient in ipairs(transients) do
        -- Adjust transient time relative to original item (subtract pre_extension)
        local adjusted_time = transient.time - offset
        if adjusted_time >= 0 and adjusted_time <= item_length then
            if reaper.SetTakeMarker(take, -1, "", take_offset + adjusted_time, marker_color) >= 0 then
                added = added + 1
            end
        end
    end

    reaper.UpdateItemInProject(item)
    return true, added
end

function InitAudioLoading(item)
    local als = processing_state.audio_load_state
    
    local take = reaper.GetActiveTake(item)
    if not take then
        return false
    end

    local source = reaper.GetMediaItemTake_Source(take)
    if not source then
        return false
    end

    local source_sample_rate = reaper.GetMediaSourceSampleRate(source)
    local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local take_offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local num_channels = reaper.GetMediaSourceNumChannels(source)

    -- Extend short edits
    local read_duration = item_len
    local pre_extension = 0
    local post_extension = 0

    if item_len < TUNABLE.short_edit_threshold and not TUNABLE.stt_enabled then
        local extension = TUNABLE.edited_extension  -- User-defined extension amount

        -- Check available source audio before item
        pre_extension = math.min(extension, take_offset)

        -- Check available source audio after item
        local source_len, _ = reaper.GetMediaSourceLength(source)
        local available_after = source_len - (take_offset + item_len)
        post_extension = math.min(extension, available_after)

        read_duration = pre_extension + item_len + post_extension
    end

    local num_samples = math.floor(read_duration * source_sample_rate)

    -- Validation
    if item_len <= 0 or num_samples <= 0 or num_channels <= 0 then
        return false
    end

    -- For extended short edits, temporarily adjust take offset to include pre-extension audio
    local original_take_offset = take_offset
    local original_item_length = item_len
    if pre_extension > 0 or post_extension > 0 then
        -- Temporarily adjust take to cover extended region
        reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", take_offset - pre_extension)
        reaper.SetMediaItemInfo_Value(item, "D_LENGTH", read_duration)
    end

    local accessor = reaper.CreateTakeAudioAccessor(take)

    -- Restore original values immediately after creating accessor
    if pre_extension > 0 or post_extension > 0 then
        reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", original_take_offset)
        reaper.SetMediaItemInfo_Value(item, "D_LENGTH", original_item_length)
    end

    if not accessor then
        return false
    end

    -- Initialize state
    als.item = item
    als.take = take
    als.accessor = accessor
    als.source_sample_rate = source_sample_rate
    als.num_channels = num_channels
    als.num_samples = num_samples
    als.current_chunk = 0
    als.total_chunks = math.ceil(num_samples / CONFIG.AUDIO_CHUNK_SIZE)
    als.audio = {}
    als.buffer = reaper.new_array(CONFIG.AUDIO_CHUNK_SIZE * num_channels)
    als.progress_percent = 0
    als.pre_extension = pre_extension
    als.post_extension = post_extension
    als.original_duration = item_len
    als.take_offset = take_offset

    processing_state.temp_sr = source_sample_rate
    processing_state.temp_offset = take_offset - pre_extension  -- Adjust for extension

    return true
end

function ProcessAudioLoadingChunk()
    local als = processing_state.audio_load_state
    
    local chunk_start = als.current_chunk * CONFIG.AUDIO_CHUNK_SIZE
    if chunk_start >= als.num_samples then
        -- Done loading
        reaper.DestroyAudioAccessor(als.accessor)
        processing_state.temp_audio = als.audio
        return true
    end
    
    local samples_to_read = math.min(CONFIG.AUDIO_CHUNK_SIZE, als.num_samples - chunk_start)
    als.buffer.clear()

    -- Read from time 0 - the accessor was created with adjusted take offset to include pre-extension
    local start_time = chunk_start / als.source_sample_rate
    reaper.GetAudioAccessorSamples(als.accessor, als.source_sample_rate, als.num_channels, start_time, samples_to_read, als.buffer)

    -- Convert to mono and store
    for i = 1, samples_to_read do
        if als.num_channels == 1 then
            als.audio[chunk_start + i] = als.buffer[i]
        else
            local sum = 0
            for ch = 0, als.num_channels - 1 do
                sum = sum + als.buffer[((i - 1) * als.num_channels) + ch + 1]
            end
            als.audio[chunk_start + i] = sum / als.num_channels
        end
    end
    
    als.current_chunk = als.current_chunk + 1
    als.progress_percent = (als.current_chunk / als.total_chunks) * 100
    
    return false  -- Not done yet
end

-- PEAK DETECTION (CHUNKED FOR ASYNC PROCESSING)
-- Optimizations:
-- - Downsampling: 10x larger chunks (500k samples) - simple abs() operations
-- - Envelope: 5x larger chunks (250k samples) - simple math operations  
-- - Smoothing: 4x larger chunks (200k samples) with O(n) sliding window
-- - Calc threshold: Sampling every Nth value to reduce sort array size
-- - Find maxima: 5x larger chunks (500k samples) - simple comparisons

function InitPeakDetection(audio, sample_rate, prominence)
    local pds = processing_state.peak_detect_state
    
    -- Reset state
    pds.phase = "downsample"
    pds.chunk_index = 1
    pds.downsampled = {}
    pds.envelope = nil
    pds.smoothed = nil
    pds.all_peaks = nil
    pds.ds_sample_rate = sample_rate / CONFIG.DOWNSAMPLE_FACTOR
    pds.prominence = prominence
    -- Calculate based on larger downsample chunk size
    local downsample_chunk_size = pds.chunk_size * 10
    pds.total_chunks = math.ceil(#audio / (CONFIG.DOWNSAMPLE_FACTOR * downsample_chunk_size))
    pds.progress_percent = 0
    pds.smooth_window_sum = 0
    pds.smooth_window_count = 0
    pds.find_peaks_subphase = "calc_threshold"
    pds.sorted_envelope = nil
    pds.threshold = nil
    pds.max_val = 0
end

function ProcessPeakDetectionChunk()
    local pds = processing_state.peak_detect_state
    local audio = processing_state.temp_audio
    
    -- Phase 1: Downsample (optimized with larger chunks)
    if pds.phase == "downsample" then
        -- Use much larger chunks for downsampling since it's just simple abs() operations
        local downsample_chunk_size = pds.chunk_size * 10  -- 500k samples per chunk
        
        local start_idx = (pds.chunk_index - 1) * downsample_chunk_size * CONFIG.DOWNSAMPLE_FACTOR + 1
        local end_idx = math.min(start_idx + downsample_chunk_size * CONFIG.DOWNSAMPLE_FACTOR - 1, #audio)
        
        for i = start_idx, end_idx, CONFIG.DOWNSAMPLE_FACTOR do
            pds.downsampled[#pds.downsampled + 1] = math.abs(audio[i])
        end
        
        local downsample_total_chunks = math.ceil(#audio / (CONFIG.DOWNSAMPLE_FACTOR * downsample_chunk_size))
        pds.progress_percent = (pds.chunk_index / downsample_total_chunks) * 20  -- 0-20%
        
        if end_idx >= #audio then
            pds.phase = "envelope"
            pds.chunk_index = 1
            pds.total_chunks = math.ceil(#pds.downsampled / pds.chunk_size)
            -- Initialize envelope with first value
            pds.envelope = {pds.downsampled[1]}
        else
            pds.chunk_index = pds.chunk_index + 1
        end
        return false  -- Not done yet
    end
    
    -- Phase 2: Create envelope (optimized with larger chunks)
    if pds.phase == "envelope" then
        local attack_coef = math.exp(-1.0 / (CONFIG.ENVELOPE_ATTACK_TIME * pds.ds_sample_rate))
        local release_coef = math.exp(-1.0 / (CONFIG.ENVELOPE_RELEASE_TIME * pds.ds_sample_rate))
        
        -- Use larger chunks for envelope since it's just simple math operations
        local envelope_chunk_size = pds.chunk_size * 5  -- 250k samples per chunk
        
        local start_idx = (pds.chunk_index - 1) * envelope_chunk_size + 2
        local end_idx = math.min(start_idx + envelope_chunk_size - 1, #pds.downsampled)
        
        for i = start_idx, end_idx do
            local input = pds.downsampled[i]
            local prev_env = pds.envelope[i - 1]
            
            if input > prev_env then
                pds.envelope[i] = attack_coef * prev_env + (1 - attack_coef) * input
            else
                pds.envelope[i] = release_coef * prev_env + (1 - release_coef) * input
            end
        end
        
        local envelope_total_chunks = math.ceil(#pds.downsampled / envelope_chunk_size)
        pds.progress_percent = 20 + (pds.chunk_index / envelope_total_chunks) * 30  -- 20-50%
        
        if end_idx >= #pds.downsampled then
            pds.phase = "smooth"
            pds.chunk_index = 1
            pds.total_chunks = math.ceil(#pds.envelope / pds.chunk_size)
            pds.smoothed = {}
        else
            pds.chunk_index = pds.chunk_index + 1
        end
        return false
    end
    
    -- Phase 3: Smooth envelope (optimized with sliding window)
    if pds.phase == "smooth" then
        local smooth_window = math.floor(pds.ds_sample_rate * CONFIG.SMOOTH_WINDOW_MS / 1000)
        
        -- Use larger chunk size for smoothing since it's now optimized
        local smooth_chunk_size = pds.chunk_size * 4  -- 4x larger chunks
        
        -- First chunk: initialize the sliding window
        if pds.chunk_index == 1 then
            -- Calculate first window sum
            local window_sum = 0
            local window_count = 0
            local start_j = math.max(1, 1 - smooth_window)
            local end_j = math.min(#pds.envelope, 1 + smooth_window)
            
            for j = start_j, end_j do
                window_sum = window_sum + pds.envelope[j]
                window_count = window_count + 1
            end
            
            pds.smoothed[1] = window_sum / window_count
            
            -- Store state for next chunks
            pds.smooth_window_sum = window_sum
            pds.smooth_window_count = window_count
        end
        
        local start_idx = (pds.chunk_index - 1) * smooth_chunk_size + 2
        local end_idx = math.min(start_idx + smooth_chunk_size - 1, #pds.envelope)
        
        local window_sum = pds.smooth_window_sum
        local window_count = pds.smooth_window_count
        
        for i = start_idx, end_idx do
            -- Remove element leaving the window (on the left)
            local left_edge = i - smooth_window - 1
            if left_edge > 0 and left_edge <= #pds.envelope then
                window_sum = window_sum - pds.envelope[left_edge]
                window_count = window_count - 1
            end
            
            -- Add element entering the window (on the right)
            local right_edge = i + smooth_window
            if right_edge > 0 and right_edge <= #pds.envelope then
                window_sum = window_sum + pds.envelope[right_edge]
                window_count = window_count + 1
            end
            
            pds.smoothed[i] = window_sum / window_count
        end
        
        -- Store state for next chunk
        pds.smooth_window_sum = window_sum
        pds.smooth_window_count = window_count
        
        -- Recalculate progress based on actual smooth_chunk_size
        local smooth_total_chunks = math.ceil(#pds.envelope / smooth_chunk_size)
        pds.progress_percent = 50 + (pds.chunk_index / smooth_total_chunks) * 30  -- 50-80%
        
        if end_idx >= #pds.envelope then
            pds.phase = "find_peaks"
            pds.chunk_index = 1
            pds.find_peaks_subphase = "calc_threshold"
            pds.envelope = pds.smoothed  -- Replace envelope with smoothed version
        else
            pds.chunk_index = pds.chunk_index + 1
        end
        return false
    end

    -- Phase 4: Find peaks (broken into sub-phases)
    if pds.phase == "find_peaks" then

        -- Sub-phase: Calculate threshold (optimized with sampling)
        if pds.find_peaks_subphase == "calc_threshold" then
            pds.progress_percent = 80

            -- Find max value
            pds.max_val = 0
            for i = 1, #pds.envelope do
                pds.max_val = math.max(pds.max_val, pds.envelope[i])
            end

            -- Filter out noise floor and SAMPLE for faster percentile calculation
            local noise_floor = pds.max_val * 0.005
            local filtered_envelope = {}
            local sample_rate = math.max(1, math.floor(#pds.envelope / 50000))  -- Sample to max 50k points

            for i = 1, #pds.envelope, sample_rate do
                if pds.envelope[i] > noise_floor then
                    filtered_envelope[#filtered_envelope + 1] = pds.envelope[i]
                end
            end

            if #filtered_envelope == 0 then
                pds.phase = "done"
                pds.all_peaks = {}
                return true
            end

            -- Sort only the sampled/filtered data (much smaller array)
            table.sort(filtered_envelope)

            -- Calculate threshold from sampled data
            local percentile_25 = filtered_envelope[math.floor(#filtered_envelope * 0.25)]
            local percentile_75 = filtered_envelope[math.floor(#filtered_envelope * 0.75)]
            local range = percentile_75 - percentile_25
            pds.threshold = percentile_25 + range * pds.prominence

            pds.find_peaks_subphase = "find_maxima"
            pds.chunk_index = 1  -- Reset for find_maxima chunks
            pds.progress_percent = 85
            return false
        end

        -- Sub-phase: Find local maxima (optimized with larger chunks)
        if pds.find_peaks_subphase == "find_maxima" then
            -- Initialize peaks array on first chunk
            if pds.chunk_index == 1 then
                pds.all_peaks = {}
            end

            -- Use larger chunks since peak detection is simple comparison
            local find_maxima_chunk_size = 500000  -- 500k samples per chunk
            local start_idx = math.max(2, (pds.chunk_index - 1) * find_maxima_chunk_size + 2)
            local end_idx = math.min(start_idx + find_maxima_chunk_size - 1, #pds.envelope - 1)

            for i = start_idx, end_idx do
                if pds.envelope[i] > pds.envelope[i - 1] and 
                   pds.envelope[i] > pds.envelope[i + 1] and 
                   pds.envelope[i] > pds.threshold then
                    pds.all_peaks[#pds.all_peaks + 1] = {
                        index = i,
                        amplitude = pds.envelope[i]
                    }
                end
            end

            local total_chunks = math.ceil(math.max(1, #pds.envelope - 2) / find_maxima_chunk_size)
            pds.progress_percent = 85 + (pds.chunk_index / total_chunks) * 5  -- 85-90%

            if end_idx >= #pds.envelope - 1 then
                pds.phase = "filter_peaks"
                pds.chunk_index = 1
                pds.progress_percent = 90
            else
                pds.chunk_index = pds.chunk_index + 1
            end
            return false
        end
    end

    -- Phase 5: Filter close peaks
    if pds.phase == "filter_peaks" then
        pds.progress_percent = 95

        if #pds.all_peaks == 0 then
            pds.phase = "done"
            return true
        end

        local min_distance = math.floor(pds.ds_sample_rate * TUNABLE.min_peak_distance_ms / 1000)
        local kept_peaks = {}

        for i = 1, #pds.all_peaks do
            local peak = pds.all_peaks[i]
            local should_keep = true

            for j = 1, #kept_peaks do
                local distance = math.abs(peak.index - kept_peaks[j].index)
                if distance < min_distance then
                    if peak.amplitude > kept_peaks[j].amplitude then
                        kept_peaks[j] = peak
                    end
                    should_keep = false
                    break
                end
            end

            if should_keep then
                kept_peaks[#kept_peaks + 1] = peak
            end
        end

        table.sort(kept_peaks, function(a, b) return a.index < b.index end)
        pds.all_peaks = kept_peaks
        pds.phase = "done"
        pds.progress_percent = 100
        return true  -- Done!
    end

    return pds.phase == "done"
end

function FinalizePeakDetection()
    local pds = processing_state.peak_detect_state
    local peaks = {}

    -- Convert to output format
    for i = 1, #pds.all_peaks do
        local original_sample = (pds.all_peaks[i].index - 1) * CONFIG.DOWNSAMPLE_FACTOR + 1
        peaks[#peaks + 1] = {
            time = sample_to_time(original_sample, processing_state.temp_sr),
            amplitude = pds.all_peaks[i].amplitude
        }
    end

    -- Create envelope data
    local envelope_data = {
        envelope = pds.envelope,
        sample_rate = pds.ds_sample_rate,
        downsample_factor = CONFIG.DOWNSAMPLE_FACTOR,
        original_sample_rate = processing_state.temp_sr
    }

    return peaks, envelope_data
end

-- PATTERN MATCHING

local function get_envelope_at_time(envelope_data, time_seconds)
    if not envelope_data then return 0 end

    local sample_index = time_to_sample(time_seconds, envelope_data.sample_rate)
    sample_index = math.max(1, math.min(#envelope_data.envelope, sample_index))

    return envelope_data.envelope[sample_index] or 0
end

local function check_envelope_mismatch(clean_env_data, edited_env_data, clean_time, edited_time, window_size)
    if not clean_env_data or not edited_env_data then
        return false, 0
    end

    local mismatches = {}

    -- Sample envelope at multiple points
    for i = 0, CONFIG.ENVELOPE_CHECK_SAMPLES - 1 do
        local progress = i / (CONFIG.ENVELOPE_CHECK_SAMPLES - 1) - 0.5  -- -0.5 to 0.5
        local offset = progress * window_size

        local clean_val = get_envelope_at_time(clean_env_data, clean_time + offset)
        local edited_val = get_envelope_at_time(edited_env_data, edited_time + offset)

        -- Check if either is active (loud)
        if clean_val > CONFIG.ENVELOPE_ACTIVE_THRESHOLD or edited_val > CONFIG.ENVELOPE_ACTIVE_THRESHOLD then
            mismatches[#mismatches + 1] = math.abs(clean_val - edited_val)
        end
    end

    if #mismatches == 0 then return false, 0 end

    -- Calculate average mismatch
    local sum = 0
    for _, val in ipairs(mismatches) do
        sum = sum + val
    end
    local avg_mismatch = sum / #mismatches
    local mismatch_ratio = #mismatches / CONFIG.ENVELOPE_CHECK_SAMPLES

    return mismatch_ratio > CONFIG.ENVELOPE_MISMATCH_THRESHOLD, avg_mismatch
end

local function normalize_amplitudes(transients)
    -- Find max amplitude
    local max_amp = 0
    for _, t in ipairs(transients) do
        max_amp = math.max(max_amp, t.amplitude or 1.0)
    end
    max_amp = math.max(max_amp, 1.0)  -- Avoid division by zero

    -- Normalize
    local normalized = {}
    for _, t in ipairs(transients) do
        normalized[#normalized + 1] = {
            time = t.time,
            amplitude = (t.amplitude or 1.0) / max_amp,
            original = t
        }
    end
    return normalized
end

function CompareTransientPatterns(clean_transients, edited_transients, clean_envelope_data, edited_envelope_data)
    if #edited_transients < 1 or #clean_transients < 1 then
        return nil
    end

    local matches = {}
    local edited_duration = edited_transients[#edited_transients].time - edited_transients[1].time
    local edited_start_offset = edited_transients[1].time

    -- Adaptive parameters based on clip length
    local is_short_clip = #edited_transients <= CONFIG.short_clip_threshold
    local is_very_short = #edited_transients <= CONFIG.VERY_SHORT_CLIP_THRESHOLD

    local max_tolerance = is_short_clip and CONFIG.max_tolerance_short or CONFIG.max_tolerance_long
    local tolerance_buffer = is_short_clip and CONFIG.TOLERANCE_BUFFER_SHORT or CONFIG.TOLERANCE_BUFFER_LONG
    local missing_peak_penalty = is_short_clip and CONFIG.missing_peak_penalty_short or CONFIG.missing_peak_penalty_long
    local extra_peak_penalty = is_short_clip and CONFIG.extra_peak_penalty_short or CONFIG.extra_peak_penalty_long

    if is_very_short then
        extra_peak_penalty = CONFIG.extra_peak_penalty_very_short
    end

    local clean_normalized = normalize_amplitudes(clean_transients)
    local edited_normalized = normalize_amplitudes(edited_transients)

    -- Try every clean peak as a potential starting position
    for start_idx = 1, #clean_normalized do
        local match_start_time = clean_normalized[start_idx].time
        local match_end_time = match_start_time + edited_duration + tolerance_buffer

        -- Check for peaks before match position (pre-silence filter)
        if TUNABLE.require_pre_silence and edited_start_offset > 0 then
            local pre_region_start = match_start_time - edited_start_offset
            local has_pre_peak = false
            for j = 1, start_idx - 1 do
                if clean_normalized[j].time >= pre_region_start and clean_normalized[j].time < match_start_time then
                    has_pre_peak = true
                    break
                end
            end
            if has_pre_peak then
                goto continue
            end
        end

        -- Get all clean peaks within this potential match region
        local clean_peaks_in_region = {}
        for j = start_idx, #clean_normalized do
            if clean_normalized[j].time >= match_start_time and clean_normalized[j].time <= match_end_time then
                clean_peaks_in_region[#clean_peaks_in_region + 1] = clean_normalized[j]
            elseif clean_normalized[j].time > match_end_time then
                break
            end
        end

        -- Check peak count ratio
        local min_peaks_ratio = is_short_clip and CONFIG.MIN_PEAKS_RATIO_SHORT or CONFIG.MIN_PEAKS_RATIO_LONG
        if #clean_peaks_in_region < #edited_normalized * min_peaks_ratio then
            goto continue
        end

        -- Envelope mismatch check
        local envelope_check_points = math.min(8, #edited_normalized + 2)
        local envelope_mismatches = 0
        local envelope_window = CONFIG.ENVELOPE_WINDOW_MS / 1000

        for i = 1, envelope_check_points do
            local progress = (i - 1) / (envelope_check_points - 1)
            local edited_time = edited_start_offset + (edited_duration * progress)
            local clean_time = match_start_time + (edited_duration * progress)

            local is_mismatch, mismatch_severity = check_envelope_mismatch(
                clean_envelope_data,
                edited_envelope_data,
                clean_time,
                edited_time,
                envelope_window
            )

            if is_mismatch then
                envelope_mismatches = envelope_mismatches + mismatch_severity
            end
        end

        -- Reject if too many envelope mismatches
        local max_envelope_mismatch = is_short_clip and CONFIG.MAX_ENVELOPE_MISMATCH_SHORT or CONFIG.MAX_ENVELOPE_MISMATCH_LONG
        if envelope_mismatches > max_envelope_mismatch then
            goto continue
        end

        -- Score peak matches
        local score = 0
        local matched_clean_indices = {}
        local amplitude_bonus = 0

        for i = 1, #edited_normalized do
            local edited_peak = edited_normalized[i]
            local time_offset_in_edited = edited_peak.time - edited_start_offset
            local expected_clean_time = match_start_time + time_offset_in_edited

            -- Find closest clean peak
            local closest_clean_idx = nil
            local smallest_time_error = math.huge

            for k = 1, #clean_peaks_in_region do
                local time_error = math.abs(clean_peaks_in_region[k].time - expected_clean_time)
                if time_error < smallest_time_error then
                    smallest_time_error = time_error
                    closest_clean_idx = k
                end
            end

            if smallest_time_error < max_tolerance then
                -- Good match
                local match_quality = 1.0 - (smallest_time_error / max_tolerance)

                -- Amplitude similarity bonus
                if closest_clean_idx then
                    local amp_diff = math.abs(clean_peaks_in_region[closest_clean_idx].amplitude - edited_peak.amplitude)
                    local amp_similarity = 1.0 - math.min(1.0, amp_diff)
                    local amp_weight = is_short_clip and CONFIG.AMP_WEIGHT_SHORT or CONFIG.AMP_WEIGHT_LONG
                    amplitude_bonus = amplitude_bonus + (amp_similarity * amp_weight)
                end

                -- Position weighting (first and last peaks more important)
                local position_weight = 1.0
                if i == 1 or i == #edited_normalized then
                    position_weight = is_short_clip and CONFIG.POSITION_WEIGHT_SHORT or CONFIG.POSITION_WEIGHT_LONG
                end

                score = score + (match_quality * position_weight)
                matched_clean_indices[closest_clean_idx] = true
            else
                score = score - missing_peak_penalty
            end
        end

        -- Count unmatched clean peaks
        local unmatched_clean_count = 0
        for k = 1, #clean_peaks_in_region do
            if not matched_clean_indices[k] then
                unmatched_clean_count = unmatched_clean_count + 1
            end
        end

        score = score - (unmatched_clean_count * extra_peak_penalty)
        score = score + amplitude_bonus
        score = score - (envelope_mismatches * CONFIG.envelope_mismatch_penalty)

        -- Normalize peak score and clamp to 1.0 (position weights + amplitude bonuses can exceed 1.0)
        local peak_score = math.min(1.0, score / #edited_normalized)

        -- Apply minimum score threshold (using peak score only - STT applied later)
        if peak_score > TUNABLE.min_score then
            matches[#matches + 1] = {
                time = match_start_time - edited_start_offset,
                score = peak_score,  -- Will be updated with STT if enabled
                position_time = match_start_time,
                edited_duration = edited_duration,  -- Store for STT region extraction
                debug_info = {
                    total_edited_peaks = #edited_normalized,
                    clean_peaks_in_region = #clean_peaks_in_region,
                    extra_clean_peaks = unmatched_clean_count,
                    envelope_mismatches = envelope_mismatches,
                    raw_score = score,
                    is_short_clip = is_short_clip,
                    peak_score = peak_score
                }
            }
        end

        ::continue::
    end

    local filter_distance = is_short_clip and CONFIG.FILTER_DISTANCE_SHORT or CONFIG.FILTER_DISTANCE_LONG
    -- When STT is enabled, keep more matches for verification (limit applied after STT re-sorting)
    local max_matches = TUNABLE.stt_enabled and 100 or TUNABLE.num_match_tracks
    return FilterCloseMatches(matches, filter_distance, max_matches)
end

function FilterCloseMatches(matches, min_distance, max_results)
    if not matches or #matches == 0 then
        return nil
    end

    table.sort(matches, function(a, b) return a.score > b.score end)

    local filtered = {}
    for i = 1, #matches do
        local too_close = false

        for j = 1, #filtered do
            if math.abs(matches[i].time - filtered[j].time) < min_distance then
                too_close = true
                break
            end
        end

        if not too_close then
            filtered[#filtered + 1] = matches[i]
            if #filtered >= max_results then
                break
            end
        end
    end

    return filtered
end

-- ITEM CREATION

function CreateMatchedItem(clean_item, start_time, duration, edited_item, target_track, edited_peaks, clean_peaks)
    local clean_take = reaper.GetActiveTake(clean_item)
    local clean_source = reaper.GetMediaItemTake_Source(clean_take)
    local edited_pos = reaper.GetMediaItemInfo_Value(edited_item, "D_POSITION")

    -- IMPORTANT: Account for the clean item's own take offset
    -- start_time is relative to the clean item's start, but we need it relative to the source file
    local clean_take_offset = reaper.GetMediaItemTakeInfo_Value(clean_take, "D_STARTOFFS")
    local absolute_start_time = clean_take_offset + start_time

    -- Calculate peak alignment offset
    local alignment_offset = 0
    local alignment_applied = false

    if TUNABLE.align_peaks and edited_peaks and clean_peaks and #edited_peaks > 0 and #clean_peaks > 0 then
        local first_edited_peak_time = edited_peaks[1].time

        -- Find first peak in matched clean region
        -- Peaks are relative to clean item start, match region is [start_time, start_time + duration)
        local first_clean_peak_in_region = nil
        for _, peak in ipairs(clean_peaks) do
            if peak.time >= start_time and peak.time < (start_time + duration) then
                first_clean_peak_in_region = peak
                break
            end
        end

        if first_clean_peak_in_region then
            -- Calculate relative position within match region
            local first_clean_peak_relative = first_clean_peak_in_region.time - start_time
            alignment_offset = first_clean_peak_relative - first_edited_peak_time

            -- Safety checks
            if alignment_offset > 0 and alignment_offset < duration then
                alignment_applied = true
            elseif alignment_offset < 0 then
                alignment_offset = 0
            else
                alignment_offset = 0
            end
        end
    end

    local new_item = reaper.AddMediaItemToTrack(target_track)
    reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", edited_pos)
    reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", duration)

    local new_take = reaper.AddTakeToMediaItem(new_item)
    reaper.SetMediaItemTake_Source(new_take, clean_source)
    reaper.SetMediaItemTakeInfo_Value(new_take, "D_STARTOFFS", absolute_start_time + alignment_offset)
    reaper.GetSetMediaItemTakeInfo_String(new_take, "P_NAME",
        alignment_applied and "Matched (aligned)" or "Matched", true)
    reaper.SetActiveTake(new_take)

    -- Copy markers from clean item (adjusted for the match position and alignment)
    local markers_copied = 0
    local adjusted_start = absolute_start_time + alignment_offset
    for i = 0, reaper.GetNumTakeMarkers(clean_take) - 1 do
        local srcpos, name, color = reaper.GetTakeMarker(clean_take, i)
        -- Check if marker falls within the matched region (relative to source file, accounting for alignment)
        if srcpos >= adjusted_start and srcpos < (adjusted_start + duration) then
            -- Set marker in new take (relative to new take's start offset)
            if reaper.SetTakeMarker(new_take, -1, name or "", srcpos, color or 0) >= 0 then
                markers_copied = markers_copied + 1
            end
        end
    end

    -- Trim extended matches back to original length
    if processing_state.edited_pre_extension and processing_state.edited_pre_extension > 0 then
        local pre_ext = processing_state.edited_pre_extension
        local original_dur = processing_state.edited_original_duration

        -- Adjust start position forward
        local current_pos = reaper.GetMediaItemInfo_Value(new_item, "D_POSITION")
        reaper.SetMediaItemInfo_Value(new_item, "D_POSITION", current_pos)

        -- Set original duration
        reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", original_dur)

        -- Adjust take offset
        local new_take_obj = reaper.GetActiveTake(new_item)
        if new_take_obj then
            local take_off = reaper.GetMediaItemTakeInfo_Value(new_take_obj, "D_STARTOFFS")
            reaper.SetMediaItemTakeInfo_Value(new_take_obj, "D_STARTOFFS", take_off + pre_ext)
        end
    end

    reaper.UpdateItemInProject(new_item)
    return new_item
end

-- SELECTION HANDLERS

function SelectEditedFiles()
    local num_selected = reaper.CountSelectedMediaItems(0)

    if num_selected == 0 then
        Log("ERROR: No items selected", COLORS.RED)
        return
    end

    -- Check all items are on the same track
    local first_track = GetTrack(reaper.GetSelectedMediaItem(0, 0))

    edited_items = {}
    for i = 0, num_selected - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        local track = GetTrack(item)

        if track ~= first_track then
            Log("ERROR: All edited items must be on the same track", COLORS.RED)
            edited_items = {}
            return
        end

        edited_items[#edited_items + 1] = item
    end

    Log(string.format("Selected %d edited item(s)", #edited_items), COLORS.GREEN)
end

function SelectCleanFiles()
    local num_selected = reaper.CountSelectedMediaItems(0)

    if num_selected == 0 then
        Log("ERROR: No items selected", COLORS.RED)
        return
    end

    clean_items = {}
    for i = 0, num_selected - 1 do
        clean_items[#clean_items + 1] = reaper.GetSelectedMediaItem(0, i)
    end

    Log(string.format("Selected %d clean recording(s)", #clean_items), COLORS.GREEN)
end

-- ASYNC PROCESSING LOGIC

local function start_load_audio(item, item_type)
    processing_state.current_item_name = GetItemName(item)
    Log(string.format("Loading %s: %s...", item_type, processing_state.current_item_name))
    
    if not InitAudioLoading(item) then
        Log(string.format("ERROR: Failed to initialize loading for %s", item_type), COLORS.RED)
        return false
    end
    
    return true
end

local function start_detect_peaks(prominence, item_type)
    Log(string.format("Detecting peaks in %s...", item_type))
    InitPeakDetection(processing_state.temp_audio, processing_state.temp_sr, prominence)
    return true
end

local function finalize_peak_detection(item)
    local peaks, envelope_data = FinalizePeakDetection()
    Log(string.format("Found %d peaks", #peaks), COLORS.CYAN)
    
    if #peaks < 1 then
        Log("ERROR: Not enough peaks. Try lowering prominence.", COLORS.RED)
        return nil, nil, nil
    end
    
    if TUNABLE.mark_peaks then
        -- Pass pre_extension offset so markers are placed relative to original item
        local pre_ext = processing_state.audio_load_state.pre_extension or 0
        AddMarkersToItem(item, peaks, nil, pre_ext)
    end
    return peaks, envelope_data, processing_state.temp_sr
end

local function setup_match_tracks(first_edited_item)
    local edited_track = GetTrack(first_edited_item)
    local edited_track_idx = reaper.GetMediaTrackInfo_Value(edited_track, "IP_TRACKNUMBER") - 1

    local target_tracks = {}
    for i = 1, TUNABLE.num_match_tracks do
        local track, is_new = get_or_create_track(edited_track_idx + i, "Match #" .. i)
        target_tracks[i] = track

        local status = is_new and "Created" or "Reusing"
        local color = is_new and COLORS.GREEN or COLORS.GRAY
        Log(string.format("%s track: Match #%d", status, i), color)
    end

    return target_tracks
end


-- Initialize processing
function StartProcessing()
    -- Validate inputs
    if #edited_items == 0 then
        Log("ERROR: No edited items selected", COLORS.RED)
        return
    end
    if #clean_items == 0 then
        Log("ERROR: No clean recordings selected", COLORS.RED)
        return
    end

    -- Reset state using helper functions
    processing_state = {
        active = true, current_item = 0, total_items = #edited_items,
        current_phase = "loading_clean", current_item_name = "",
        current_clean_item = 0,
        clean_items_peaks = {},
        clean_items_envelope_data = {},
        clean_items_sr = {},
        -- STT state
        clean_items_stt = {},
        edited_stt = nil,
        target_tracks = nil, success_count = 0, fail_count = 0, undo_started = false,
        temp_audio = nil, temp_sr = nil, temp_offset = nil,
        temp_peaks = nil, temp_envelope_data = nil,
        audio_load_state = create_audio_load_state(),
        peak_detect_state = create_peak_detect_state()
    }

    is_processing = true
    cancel_requested = false  -- Reset cancel flag
    Log(string.format("Starting matching process with %d clean recording(s)...", #clean_items))
    reaper.defer(ProcessNextStep)
end

-- Cancel the current processing operation
function CancelProcessing()
    if not is_processing then
        return
    end

    cancel_requested = true
    Log("Cancelling...", COLORS.YELLOW)
end

-- Process one step at a time
function ProcessNextStep()
    if not processing_state.active then
        return
    end

    -- Check for cancellation request
    if cancel_requested then
        Log("Processing cancelled by user", COLORS.YELLOW)
        is_processing = false
        cancel_requested = false
        processing_state.active = false

        -- Clean up any undo state
        if processing_state.undo_started then
            reaper.Undo_EndBlock("Voice Line Matcher (Cancelled)", -1)
        end

        return
    end

    -- Start undo block
    if not processing_state.undo_started then
        reaper.Undo_BeginBlock()
        processing_state.undo_started = true
    end

    -- Phase: Initialize clean recording loading
    if processing_state.current_phase == "loading_clean" then
        processing_state.current_clean_item = 1
        processing_state.current_phase = "loading_clean_audio"
        reaper.defer(ProcessNextStep)
        return
    end
    
    -- Phase: Load clean recording audio
    if processing_state.current_phase == "loading_clean_audio" then
        local clean_item = clean_items[processing_state.current_clean_item]
        if not start_load_audio(clean_item, string.format("clean recording %d/%d", processing_state.current_clean_item, #clean_items)) then
            FinishProcessing()
            return
        end
        processing_state.current_phase = "loading_clean_audio_chunked"
        reaper.defer(ProcessNextStep)
        return
    end
    
    if processing_state.current_phase == "loading_clean_audio_chunked" then
        local done = ProcessAudioLoadingChunk()
        
        if done then
            processing_state.current_phase = "detecting_clean_peaks"
        end
        
        reaper.defer(ProcessNextStep)
        return
    end
    
    if processing_state.current_phase == "detecting_clean_peaks" then
        if not start_detect_peaks(TUNABLE.peak_prominence, string.format("clean recording %d/%d", processing_state.current_clean_item, #clean_items)) then
            FinishProcessing()
            return
        end
        
        processing_state.current_phase = "processing_clean_peaks_chunked"
        reaper.defer(ProcessNextStep)
        return
    end
    
    if processing_state.current_phase == "processing_clean_peaks_chunked" then
        local done = ProcessPeakDetectionChunk()

        if done then
            local clean_item = clean_items[processing_state.current_clean_item]
            local peaks, envelope_data, sr = finalize_peak_detection(clean_item)

            if not peaks then
                FinishProcessing()
                return
            end

            -- Store results for this clean recording
            processing_state.clean_items_peaks[processing_state.current_clean_item] = peaks
            processing_state.clean_items_envelope_data[processing_state.current_clean_item] = envelope_data
            processing_state.clean_items_sr[processing_state.current_clean_item] = sr

            -- Move to next clean item or setup tracks (STT is done per-match now)
            if processing_state.current_clean_item < #clean_items then
                processing_state.current_clean_item = processing_state.current_clean_item + 1
                processing_state.current_phase = "loading_clean_audio"
            else
                processing_state.current_phase = "setup_tracks"
            end
        end

        reaper.defer(ProcessNextStep)
        return
    end

    if processing_state.current_phase == "setup_tracks" then
        processing_state.target_tracks = setup_match_tracks(edited_items[1])
        processing_state.current_phase = "processing_item"
        processing_state.current_item = 1
        reaper.defer(ProcessNextStep)
        return
    end

    -- Phase: Process each edited item
    if processing_state.current_phase == "processing_item" then
        if processing_state.current_item > #edited_items then
            FinishProcessing()
            return
        end
        
        processing_state.current_phase = "loading_edited_audio"
        reaper.defer(ProcessNextStep)
        return
    end
    
    if processing_state.current_phase == "loading_edited_audio" then
        local edited_item = edited_items[processing_state.current_item]
        Log(string.format("Processing item %d/%d", processing_state.current_item, #edited_items), COLORS.YELLOW)
        
        if not start_load_audio(edited_item, "edited item") then
            processing_state.fail_count = processing_state.fail_count + 1
            processing_state.current_item = processing_state.current_item + 1
            processing_state.current_phase = "processing_item"
            reaper.defer(ProcessNextStep)
            return
        end
        
        processing_state.current_phase = "loading_edited_audio_chunked"
        reaper.defer(ProcessNextStep)
        return
    end
    
    if processing_state.current_phase == "loading_edited_audio_chunked" then
        local done = ProcessAudioLoadingChunk()
        
        if done then
            processing_state.current_phase = "detecting_edited_peaks"
        end
        
        reaper.defer(ProcessNextStep)
        return
    end
    
    if processing_state.current_phase == "detecting_edited_peaks" then
        if not start_detect_peaks(TUNABLE.peak_prominence, "edited item") then
            processing_state.fail_count = processing_state.fail_count + 1
            processing_state.current_item = processing_state.current_item + 1
            processing_state.current_phase = "processing_item"
            reaper.defer(ProcessNextStep)
            return
        end
        
        processing_state.current_phase = "processing_edited_peaks_chunked"
        reaper.defer(ProcessNextStep)
        return
    end
    
    if processing_state.current_phase == "processing_edited_peaks_chunked" then
        local done = ProcessPeakDetectionChunk()

        if done then
            -- If STT enabled, transcribe edited item before matching
            if TUNABLE.stt_enabled then
                processing_state.current_phase = "stt_edited"
            else
                processing_state.current_phase = "matching"
            end
        end

        reaper.defer(ProcessNextStep)
        return
    end

    -- Phase: STT for edited item
    if processing_state.current_phase == "stt_edited" then
        local edited_item = edited_items[processing_state.current_item]
        Log("  Transcribing edited item...", COLORS.CYAN)

        local wav_path = ExportItemToWav(edited_item)
        if wav_path then
            local stt_result = TranscribeWithEngine(wav_path)
            os.remove(wav_path)

            if stt_result and stt_result.text ~= "" then
                processing_state.edited_stt = stt_result
                Log(string.format("  Transcribed: '%s'", stt_result.text), COLORS.GREEN)
            else
                processing_state.edited_stt = nil
                Log("  STT returned no text", COLORS.YELLOW)
            end
        else
            processing_state.edited_stt = nil
            Log("  Failed to export audio for STT", COLORS.YELLOW)
        end

        processing_state.current_phase = "matching"
        reaper.defer(ProcessNextStep)
        return
    end

    if processing_state.current_phase == "matching" then
        local edited_item = edited_items[processing_state.current_item]
        local edited_peaks, edited_envelope_data, edited_sr = finalize_peak_detection(edited_item)
        -- Store edited peaks for later use in CreateMatchedItem (peak alignment)
        processing_state.edited_peaks = edited_peaks
        -- Calculate first peak offset (audio content before first peak)
        local edited_first_peak_offset = (edited_peaks and edited_peaks[1]) and edited_peaks[1].time or 0
        processing_state.edited_first_peak_offset = edited_first_peak_offset
        local edited_duration = reaper.GetMediaItemInfo_Value(edited_item, "D_LENGTH")
        -- Store extension info for trimming matched items later
        local als = processing_state.audio_load_state
        processing_state.edited_pre_extension = als.pre_extension or 0
        processing_state.edited_post_extension = als.post_extension or 0
        processing_state.edited_original_duration = als.original_duration or edited_duration

        -- Calculate extended duration for creating matched items (will be trimmed back later)
        local extended_duration = processing_state.edited_pre_extension + edited_duration + processing_state.edited_post_extension
        processing_state.stt_edited_duration_extended = extended_duration

        -- Try matching against all clean recordings (peak matching only)
        local all_matches = {}

        for clean_idx = 1, #clean_items do
            local matches = CompareTransientPatterns(
                processing_state.clean_items_peaks[clean_idx],
                edited_peaks,
                processing_state.clean_items_envelope_data[clean_idx],
                edited_envelope_data
            )

            if matches and #matches > 0 then
                -- Tag each match with which clean recording it came from
                for _, match in ipairs(matches) do
                    match.clean_item_index = clean_idx
                    all_matches[#all_matches + 1] = match
                end
            end
        end

        if #all_matches == 0 then
            Log("  ERROR: No matches found in any clean recording", COLORS.RED)
            processing_state.fail_count = processing_state.fail_count + 1
            -- Move to next item
            processing_state.current_item = processing_state.current_item + 1
            processing_state.current_phase = "processing_item"
        else
            -- Sort all matches by peak score first
            table.sort(all_matches, function(a, b) return a.score > b.score end)

            -- Store matches for potential STT verification
            processing_state.stt_all_matches = all_matches
            -- Use extended duration if extension was applied, otherwise original
            processing_state.stt_edited_duration = processing_state.stt_edited_duration_extended or edited_duration

            -- STT verification for all candidates above threshold (if enabled)
            if TUNABLE.stt_enabled and processing_state.edited_stt and processing_state.edited_stt.text ~= "" then
                -- Count how many matches exceed the STT peak threshold
                local candidates_above_threshold = 0
                for _, match in ipairs(all_matches) do
                    if match.debug_info.peak_score >= TUNABLE.stt_peak_threshold then
                        candidates_above_threshold = candidates_above_threshold + 1
                    end
                end

                processing_state.stt_candidates_to_verify = candidates_above_threshold
                processing_state.stt_current_candidate = 1
                Log(string.format("  Verifying %d matches (peak >= %.2f) with STT...",
                    processing_state.stt_candidates_to_verify, TUNABLE.stt_peak_threshold), COLORS.CYAN)
                processing_state.current_phase = "stt_verify"
            else
                -- No STT, go directly to creating matches
                processing_state.current_phase = "create_matches"
            end
        end

        reaper.defer(ProcessNextStep)
        return
    end

    -- Phase: STT verification (one candidate per cycle for progress updates)
    if processing_state.current_phase == "stt_verify" then
        local i = processing_state.stt_current_candidate
        local all_matches = processing_state.stt_all_matches
        local edited_text = processing_state.edited_stt.text
        local edited_duration = processing_state.stt_edited_duration
        -- Use original duration for STT (not extended duration used for peak matching)
        local stt_duration = processing_state.edited_original_duration or edited_duration

        if i <= #all_matches then
            local match = all_matches[i]
            local peak_score = match.debug_info.peak_score

            -- Only do STT if peak score is above threshold
            if peak_score >= TUNABLE.stt_peak_threshold then
                local clean_item = clean_items[match.clean_item_index]

                -- Export the matching region from clean recording
                -- match.time = where extended audio starts in clean (already adjusted for first peak)
                -- Add pre_ext to get to where the ORIGINAL item starts
                -- Subtract first_peak_in_original to capture audio before first peak in original item
                local pre_ext = processing_state.edited_pre_extension or 0
                local first_peak_in_original = math.max(0, processing_state.edited_first_peak_offset - pre_ext)
                local clean_export_start = match.time + pre_ext - first_peak_in_original
                local wav_path = ExportItemToWav(clean_item, clean_export_start, stt_duration)
                if wav_path then
                    local clean_stt = TranscribeWithEngine(wav_path)
                    os.remove(wav_path)

                    if clean_stt and clean_stt.text and clean_stt.text ~= "" then
                        local stt_score = TextSimilarity(edited_text, clean_stt.text)

                        -- Combine scores
                        local combined_score = (peak_score * (1 - TUNABLE.stt_weight)) + (stt_score * TUNABLE.stt_weight)
                        match.score = combined_score
                        match.debug_info.stt_score = stt_score
                        match.debug_info.edited_text = edited_text
                        match.debug_info.matched_clean_text = clean_stt.text

                        Log(string.format("    Match %d (of %d above threshold): Peak=%.2f, STT=%.2f -> Combined=%.2f",
                            i, processing_state.stt_candidates_to_verify, peak_score, stt_score, combined_score), COLORS.GRAY)
                    else
                        -- STT failed, recalculate score with stt_score = 0 (penalizes the match)
                        local stt_score = 0
                        local combined_score = (peak_score * (1 - TUNABLE.stt_weight)) + (stt_score * TUNABLE.stt_weight)
                        match.score = combined_score
                        match.debug_info.stt_score = stt_score
                        match.debug_info.edited_text = edited_text
                        match.debug_info.matched_clean_text = "(STT failed)"
                        Log(string.format("    Match %d: STT failed, Peak=%.2f -> Combined=%.2f (penalized)",
                            i, peak_score, combined_score), COLORS.YELLOW)
                    end
                else
                    -- WAV export failed, penalize the match
                    local stt_score = 0
                    local combined_score = (peak_score * (1 - TUNABLE.stt_weight)) + (stt_score * TUNABLE.stt_weight)
                    match.score = combined_score
                    match.debug_info.stt_score = stt_score
                    match.debug_info.edited_text = edited_text
                    match.debug_info.matched_clean_text = "(Export failed)"
                    Log(string.format("    Match %d: WAV export failed, Peak=%.2f -> Combined=%.2f (penalized)",
                        i, peak_score, combined_score), COLORS.RED)
                end
            else
                -- Match below threshold, set STT score to 0 and recalculate (penalizes the match)
                local stt_score = 0
                local combined_score = (peak_score * (1 - TUNABLE.stt_weight)) + (stt_score * TUNABLE.stt_weight)
                match.score = combined_score
                match.debug_info.stt_score = stt_score
                match.debug_info.edited_text = edited_text
                match.debug_info.matched_clean_text = "(Below threshold)"
            end

            -- Move to next candidate
            processing_state.stt_current_candidate = i + 1
        else
            -- Done with STT verification, re-sort and create matches
            table.sort(all_matches, function(a, b) return a.score > b.score end)
            processing_state.current_phase = "create_matches"
        end

        reaper.defer(ProcessNextStep)
        return
    end

    -- Phase: Create matched items
    if processing_state.current_phase == "create_matches" then
        local all_matches = processing_state.stt_all_matches
        local edited_item = edited_items[processing_state.current_item]
        local edited_duration = processing_state.stt_edited_duration

        local num_matches_to_create = math.min(TUNABLE.num_match_tracks, #all_matches)
        Log(string.format("n/  Found %d total matches across %d clean recording(s):", #all_matches, #clean_items), COLORS.GREEN)

        for match_idx = 1, num_matches_to_create do
            local match = all_matches[match_idx]
            local clean_item = clean_items[match.clean_item_index]
            local clean_name = GetItemName(clean_item)

            Log(string.format("    Match #%d: %.3fs (score: %.3f) from '%s'",
                match_idx, match.time, match.score, clean_name), COLORS.CYAN)

            if match.debug_info and match.debug_info.envelope_mismatches > 0 then
                Log(string.format("      Envelope mismatches: %.2f", match.debug_info.envelope_mismatches), COLORS.ORANGE)
            end

            -- Show STT debug info if available
            if TUNABLE.stt_enabled and match.debug_info then
                if match.debug_info.stt_score and match.debug_info.stt_score > 0 then
                    Log(string.format("      Peak: %.2f, STT: %.2f",
                        match.debug_info.peak_score or 0, match.debug_info.stt_score), COLORS.GRAY)
                    if match.debug_info.edited_text and match.debug_info.edited_text ~= "" then
                        local edited_preview = string.sub(match.debug_info.edited_text, 1, 50)
                        Log(string.format("      Edited: '%s'%s", edited_preview,
                            #match.debug_info.edited_text > 50 and "..." or ""), COLORS.GRAY)
                    end
                    if match.debug_info.matched_clean_text and match.debug_info.matched_clean_text ~= "" then
                        local clean_preview = string.sub(match.debug_info.matched_clean_text, 1, 50)
                        Log(string.format("      Clean: '%s'%s", clean_preview,
                            #match.debug_info.matched_clean_text > 50 and "..." or ""), COLORS.GRAY)
                    end
                elseif match.debug_info.peak_score then
                    Log(string.format("      Peak score: %.2f (no STT)", match.debug_info.peak_score), COLORS.GRAY)
                end
            end

            -- Get peak data for alignment
            local edited_peaks = processing_state.edited_peaks
            local clean_peaks = processing_state.clean_items_peaks[match.clean_item_index]

            CreateMatchedItem(clean_item, match.time, edited_duration, edited_item,
                              processing_state.target_tracks[match_idx], edited_peaks, clean_peaks)
        end

        processing_state.success_count = processing_state.success_count + 1

        -- Clean up STT state
        processing_state.stt_all_matches = nil
        processing_state.stt_current_candidate = 0
        processing_state.stt_candidates_to_verify = 0

        -- Move to next item
        processing_state.current_item = processing_state.current_item + 1
        processing_state.current_phase = "processing_item"
        reaper.defer(ProcessNextStep)
        return
    end
end

function FinishProcessing()
    processing_state.current_phase = "complete"
    
    if processing_state.undo_started then
        reaper.Undo_EndBlock("Match waveforms", -1)
        reaper.UpdateArrange()
    end

    Log("=== Completed ===", COLORS.WHITE)
    if processing_state.success_count > 0 then
        Log(string.format("Success: %d", processing_state.success_count), COLORS.GREEN)
    end
    if processing_state.fail_count > 0 then
        Log(string.format("Failed: %d", processing_state.fail_count), COLORS.RED)
    end

    is_processing = false
    processing_state.active = false
end

-- GUI

local window_first_open = true

-- UI Style constants
local UI = {
    BUTTON_WIDTH = 180,
    BUTTON_HEIGHT = 28,
    INPUT_WIDTH = 180,
    SLIDER_WIDTH = -1,  -- -1 = stretch to fill
    SECTION_SPACING = 8,
    ITEM_SPACING = 4,
}

function Loop()
    -- Set initial window size on first open
    if window_first_open then
        reaper.ImGui_SetNextWindowSize(ctx, 450, 650, reaper.ImGui_Cond_FirstUseEver())
        window_first_open = false
    end

    local visible, open = reaper.ImGui_Begin(ctx, 'Voice Line Matcher', true, reaper.ImGui_WindowFlags_None())

    if visible then
        -- Check for ESC key to cancel processing
        if is_processing and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
            CancelProcessing()
        end

        local avail_width = reaper.ImGui_GetContentRegionAvail(ctx)
        local slicerRightSpece = 160

        -- ═══════════════════════════════════════════════════════════════════════
        -- SECTION: Input Selection
        -- ═══════════════════════════════════════════════════════════════════════
        reaper.ImGui_SetNextItemOpen(ctx, true, reaper.ImGui_Cond_Once())
        if reaper.ImGui_CollapsingHeader(ctx, "Input Selection") then
            reaper.ImGui_Spacing(ctx)

            -- Use a table for aligned layout
            if reaper.ImGui_BeginTable(ctx, "input_table", 3, reaper.ImGui_TableFlags_None()) then
                reaper.ImGui_TableSetupColumn(ctx, "btn", reaper.ImGui_TableColumnFlags_WidthFixed(), UI.BUTTON_WIDTH)
                reaper.ImGui_TableSetupColumn(ctx, "status", reaper.ImGui_TableColumnFlags_WidthStretch())
                reaper.ImGui_TableSetupColumn(ctx, "clear", reaper.ImGui_TableColumnFlags_WidthFixed(), 50)

                -- Row 1: Edited Items
                reaper.ImGui_TableNextRow(ctx)
                reaper.ImGui_TableNextColumn(ctx)
                if reaper.ImGui_Button(ctx, "Load Edited Item(s)", UI.BUTTON_WIDTH, UI.BUTTON_HEIGHT) then
                    SelectEditedFiles()
                end

                reaper.ImGui_TableNextColumn(ctx)
                local edited_color = #edited_items > 0 and COLORS.GREEN or COLORS.GRAY
                local edited_icon = #edited_items > 0 and "[OK]" or "[--]"
                reaper.ImGui_TextColored(ctx, reaper.ImGui_ColorConvertDouble4ToU32(table.unpack(edited_color)),
                    string.format(" %s %d item(s)", edited_icon, #edited_items))

                reaper.ImGui_TableNextColumn(ctx)
                if #edited_items > 0 then
                    if reaper.ImGui_SmallButton(ctx, "Clear##edited") then
                        edited_items = {}
                        Log("Cleared edited items", COLORS.GRAY)
                    end
                end

                -- Row 2: Clean Recording
                reaper.ImGui_TableNextRow(ctx)
                reaper.ImGui_TableNextColumn(ctx)
                if reaper.ImGui_Button(ctx, "Load Clean Item(s)", UI.BUTTON_WIDTH, UI.BUTTON_HEIGHT) then
                    SelectCleanFiles()
                end

                reaper.ImGui_TableNextColumn(ctx)
                local clean_color = #clean_items > 0 and COLORS.GREEN or COLORS.GRAY
                local clean_icon = #clean_items > 0 and "[OK]" or "[--]"
                reaper.ImGui_TextColored(ctx, reaper.ImGui_ColorConvertDouble4ToU32(table.unpack(clean_color)),
                    string.format(" %s %d item(s)", clean_icon, #clean_items))

                reaper.ImGui_TableNextColumn(ctx)
                if #clean_items > 0 then
                    if reaper.ImGui_SmallButton(ctx, "Clear##clean") then
                        clean_items = {}
                        Log("Cleared clean items", COLORS.GRAY)
                    end
                end

                reaper.ImGui_EndTable(ctx)
            end

            reaper.ImGui_Spacing(ctx)
        end

        -- ═══════════════════════════════════════════════════════════════════════
        -- SECTION: Matching Settings
        -- ═══════════════════════════════════════════════════════════════════════
        reaper.ImGui_SetNextItemOpen(ctx, true, reaper.ImGui_Cond_Once())
        if reaper.ImGui_CollapsingHeader(ctx, "Matching Settings") then
            reaper.ImGui_Spacing(ctx)

            -- Peak Prominence
            reaper.ImGui_SetNextItemWidth(ctx, avail_width - slicerRightSpece)
            local changed, new_val = reaper.ImGui_SliderDouble(ctx, "Peak Prominence", TUNABLE.peak_prominence, 0.0, 1.0, "%.2f")
            if changed then
                TUNABLE.peak_prominence = new_val
                SaveSettings(STT_SETTINGS)
            end
            if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx, TOOLTIPS.peak_prominence)
            end

            -- Number of matches
            reaper.ImGui_SetNextItemWidth(ctx, avail_width - slicerRightSpece)
            local changed2, new_val2 = reaper.ImGui_SliderInt(ctx, "Nr Of matches", TUNABLE.num_match_tracks, 1, 10)
            if changed2 then
                TUNABLE.num_match_tracks = new_val2
                SaveSettings(STT_SETTINGS)
            end
            if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx, TOOLTIPS.num_match_tracks)
            end

            reaper.ImGui_Spacing(ctx)
        end

        -- ═══════════════════════════════════════════════════════════════════════
        -- SECTION: Speech-to-Text (STT)
        -- ═══════════════════════════════════════════════════════════════════════
        
        reaper.ImGui_SetNextItemOpen(ctx, true, reaper.ImGui_Cond_Once())
        if reaper.ImGui_CollapsingHeader(ctx, "Speech-to-Text Configuration") then
            reaper.ImGui_Spacing(ctx)

            -- Enable checkbox with validation
            local stt_changed, stt_enabled = reaper.ImGui_Checkbox(ctx, "Enable STT Comparison", TUNABLE.stt_enabled)
            if stt_changed then
                TUNABLE.stt_enabled = stt_enabled
                if stt_enabled then
                    if ValidateSTTSetup() then
                        Log("STT enabled", COLORS.GREEN)
                    else
                        Log("STT enabled but setup incomplete - check messages above", COLORS.YELLOW)
                    end
                else
                    Log("STT disabled", COLORS.GRAY)
                end
                SaveSettings(STT_SETTINGS)
            end
            if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx, TOOLTIPS.stt_enabled)
            end

            if TUNABLE.stt_enabled then
                reaper.ImGui_Spacing(ctx)
                reaper.ImGui_Indent(ctx, 10)

                -- Engine Selection Dropdown
                local engines = {"Google (Free)", "Google Cloud", "Azure", "Whisper (Local)", "Vosk (Local)"}
                local engine_ids = {"google", "google_cloud", "azure", "whisper", "vosk"}
                local current_idx = GetEngineIndex(STT_SETTINGS.engine, engine_ids)

                reaper.ImGui_Text(ctx, "STT Engine:")
                reaper.ImGui_SameLine(ctx)
                reaper.ImGui_SetNextItemWidth(ctx, 200)
                if reaper.ImGui_BeginCombo(ctx, "##engine", engines[current_idx]) then
                    for i, name in ipairs(engines) do
                        local is_selected = (i == current_idx)
                        if reaper.ImGui_Selectable(ctx, name, is_selected) then
                            STT_SETTINGS.engine = engine_ids[i]
                            SaveSettings(STT_SETTINGS)
                            Log(string.format("STT engine changed to: %s", name), COLORS.GREEN)
                        end
                        if is_selected then
                            reaper.ImGui_SetItemDefaultFocus(ctx)
                        end
                    end
                    reaper.ImGui_EndCombo(ctx)
                end
                if reaper.ImGui_IsItemHovered(ctx) then
                    reaper.ImGui_SetTooltip(ctx, "Choose which speech-to-text engine to use")
                end

                reaper.ImGui_Spacing(ctx)

                -- Dynamic engine-specific settings
                RenderEngineSettings(ctx, STT_SETTINGS.engine)

                -- Common settings (language, sliders)
                RenderCommonSTTSettings(ctx, avail_width, slicerRightSpece)

                reaper.ImGui_Unindent(ctx, 10)
            end

            reaper.ImGui_Spacing(ctx)
        end

        -- ═══════════════════════════════════════════════════════════════════════
        -- SECTION: Advanced Settings
        -- ═══════════════════════════════════════════════════════════════════════
        if reaper.ImGui_CollapsingHeader(ctx, "Advanced Settings") then
            reaper.ImGui_Spacing(ctx)
            reaper.ImGui_Indent(ctx, 10)

            reaper.ImGui_SetNextItemWidth(ctx, avail_width - slicerRightSpece)
            local c1, v1 = reaper.ImGui_SliderDouble(ctx, "Min peak distance(ms)", TUNABLE.min_peak_distance_ms, 10, 100, "%.0f")
            if c1 then
                TUNABLE.min_peak_distance_ms = v1
                SaveSettings(STT_SETTINGS)
            end
            if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx, TOOLTIPS.min_peak_distance_ms)
            end

            reaper.ImGui_SetNextItemWidth(ctx, avail_width - slicerRightSpece)
            local c3, v3 = reaper.ImGui_SliderDouble(ctx, "Min Score", TUNABLE.min_score, 0.0, 1.0, "%.2f")
            if c3 then
                TUNABLE.min_score = v3
                SaveSettings(STT_SETTINGS)
            end
            if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx, TOOLTIPS.min_score)
            end

            local makrPeaks_changed, makrPeaks_enabled = reaper.ImGui_Checkbox(ctx, "Show Debug Peak Markers", TUNABLE.mark_peaks)
            if makrPeaks_changed then
                TUNABLE.mark_peaks = makrPeaks_enabled
                SaveSettings(STT_SETTINGS)
            end
            if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx, TOOLTIPS.mark_peaks)
            end

            local alignPeaks_changed, alignPeaks_enabled = reaper.ImGui_Checkbox(ctx, "Align First Peaks", TUNABLE.align_peaks)
            if alignPeaks_changed then
                TUNABLE.align_peaks = alignPeaks_enabled
                SaveSettings(STT_SETTINGS)
            end
            if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx, TOOLTIPS.align_peaks)
            end

            local preSilence_changed, preSilence_enabled = reaper.ImGui_Checkbox(ctx, "Require Pre-Silence", TUNABLE.require_pre_silence)
            if preSilence_changed then
                TUNABLE.require_pre_silence = preSilence_enabled
                SaveSettings(STT_SETTINGS)
            end
            if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx, TOOLTIPS.require_pre_silence)
            end

            reaper.ImGui_Spacing(ctx)
            reaper.ImGui_Separator(ctx)
            reaper.ImGui_Spacing(ctx)

            -- Short Edit Extension settings
            reaper.ImGui_Text(ctx, "Short Edit Extension:")
            reaper.ImGui_SetNextItemWidth(ctx, avail_width - slicerRightSpece)
            local thresh_changed, new_thresh = reaper.ImGui_SliderDouble(ctx, "Threshold (s)", TUNABLE.short_edit_threshold, 1.0, 30.0, "%.1f")
            if thresh_changed then
                TUNABLE.short_edit_threshold = new_thresh
                SaveSettings(STT_SETTINGS)
            end
            if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx, TOOLTIPS.short_edit_threshold)
            end

            reaper.ImGui_SetNextItemWidth(ctx, avail_width - slicerRightSpece)
            local ext_amt_changed, new_ext_amt = reaper.ImGui_SliderDouble(ctx, "Extension (s)", TUNABLE.edited_extension, 0.5, 10.0, "%.1f")
            if ext_amt_changed then
                TUNABLE.edited_extension = new_ext_amt
                SaveSettings(STT_SETTINGS)
            end
            if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx, TOOLTIPS.edited_extension)
            end

            reaper.ImGui_Spacing(ctx)
            reaper.ImGui_Separator(ctx)
            reaper.ImGui_Spacing(ctx)

            reaper.ImGui_Unindent(ctx, 10)
            reaper.ImGui_Spacing(ctx)
        end

        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Spacing(ctx)

        -- ═══════════════════════════════════════════════════════════════════════
        -- SECTION: Run Button & Progress
        -- ═══════════════════════════════════════════════════════════════════════

        local can_match = #edited_items > 0 and #clean_items > 0 and not is_processing

        -- Match Waveforms button (disabled when processing)
        if not can_match then
            reaper.ImGui_BeginDisabled(ctx)
        end
        if reaper.ImGui_Button(ctx, "Match Waveforms", 200, 40) then
            StartProcessing()
        end
        if not can_match then
            reaper.ImGui_EndDisabled(ctx)
        end

        -- Cancel button (only shown during processing)
        if is_processing then
            reaper.ImGui_SameLine(ctx)
            if reaper.ImGui_Button(ctx, "Cancel", 100, 40) then
                CancelProcessing()
            end
            if reaper.ImGui_IsItemHovered(ctx) then
                reaper.ImGui_SetTooltip(ctx, "Cancel the current matching process")
            end
        end

        -- Reset to Defaults button (right-aligned)
        reaper.ImGui_SameLine(ctx)
        local cursor_x = reaper.ImGui_GetCursorPosX(ctx)
        local log_avail_width = reaper.ImGui_GetContentRegionAvail(ctx)
        reaper.ImGui_SetCursorPosX(ctx, cursor_x + log_avail_width - 150)
        if reaper.ImGui_Button(ctx, "Reset Settings", 150, 40) then
            ResetToDefaults()
        end
        if reaper.ImGui_IsItemHovered(ctx) then
            reaper.ImGui_SetTooltip(ctx, "Reset all settings to their default values")
        end




        -- Progress bar
        if is_processing and processing_state.active then
            reaper.ImGui_Spacing(ctx)
            
            -- Progress allocation configuration (adjust these to rebalance)
            local PROGRESS_CONFIG = {
                loading_clean_start = 0.01,
                loading_clean_range = 0.09,      -- 1-10%
                detecting_clean_start = 0.10,
                detecting_clean_range = 0.60,    -- 10-70%
                setup_tracks = 0.70,
                items_start = 0.70,
                items_range = 0.30,              -- 70-100%
                item_audio_portion = 0.08,       -- Within each item
                item_peaks_portion = 0.12,       -- Within each item
                item_match_portion = 0.02,       -- Within each item (matching peak patterns)
                item_stt_portion = 0.06,         -- Within each item (STT verification)
                item_create_portion = 0.02       -- Within each item (creating matched items)
            }
            
            local progress = 0
            local phase_desc = ""
            local cp = processing_state.current_phase
            
            -- Calculate progress based on current phase
            if cp == "loading_clean" then
                progress = PROGRESS_CONFIG.loading_clean_start
                phase_desc = "Initializing"
                
            elseif cp == "loading_clean_audio" or cp == "loading_clean_audio_chunked" then
                -- Calculate which portion of the total clean processing range this item occupies
                local per_item_loading = PROGRESS_CONFIG.loading_clean_range / #clean_items
                local per_item_detecting = PROGRESS_CONFIG.detecting_clean_range / #clean_items
                
                -- Base progress for this clean item (accounts for all previous items)
                local item_base = PROGRESS_CONFIG.loading_clean_start
                item_base = item_base + ((processing_state.current_clean_item - 1) * (per_item_loading + per_item_detecting))
                
                -- Add progress within the loading phase for this item
                local als = processing_state.audio_load_state
                local within_phase = (als.progress_percent / 100) * per_item_loading
                progress = item_base + within_phase
                phase_desc = string.format("Loading clean audio (%d/%d)", processing_state.current_clean_item, #clean_items)
                
            elseif cp == "detecting_clean_peaks" or cp == "processing_clean_peaks_chunked" then
                local pds = processing_state.peak_detect_state
                local phase_names = {
                    downsample = "Downsampling",
                    envelope = "Creating envelope",
                    smooth = "Smoothing",
                    filter_peaks = "Filtering peaks"
                }
                phase_desc = phase_names[pds.phase] or "Detecting peaks"
                
                if pds.phase == "find_peaks" then
                    phase_desc = pds.find_peaks_subphase == "calc_threshold" and "Calculating threshold" or "Finding peaks"
                end
                
                phase_desc = string.format("%s (%d/%d)", phase_desc, processing_state.current_clean_item, #clean_items)
                
                -- Calculate which portion of the total clean processing range this item occupies
                local per_item_loading = PROGRESS_CONFIG.loading_clean_range / #clean_items
                local per_item_detecting = PROGRESS_CONFIG.detecting_clean_range / #clean_items
                
                -- Base progress for this clean item (includes loading phase for this item)
                local item_base = PROGRESS_CONFIG.loading_clean_start
                item_base = item_base + ((processing_state.current_clean_item - 1) * (per_item_loading + per_item_detecting))
                item_base = item_base + per_item_loading  -- Add the completed loading phase
                
                -- Add progress within the detecting phase for this item
                local within_phase = (pds.progress_percent / 100) * per_item_detecting
                progress = item_base + within_phase
                
            elseif cp == "setup_tracks" then
                progress = PROGRESS_CONFIG.setup_tracks
                phase_desc = "Setting up tracks"
                
            else
                -- All item processing phases (edited items)
                local base = PROGRESS_CONFIG.items_start
                local item_idx = processing_state.current_item - 1
                local total = processing_state.total_items
                
                -- Calculate per-item range allocation
                local per_item_range = PROGRESS_CONFIG.items_range / total
                local per_item_audio = PROGRESS_CONFIG.item_audio_portion / total
                local per_item_peaks = PROGRESS_CONFIG.item_peaks_portion / total
                local per_item_match = PROGRESS_CONFIG.item_match_portion / total
                local per_item_stt = PROGRESS_CONFIG.item_stt_portion / total

                -- Base progress accounting for all completed items
                local item_base = base + (item_idx * per_item_range)
                
                if cp == "processing_item" then
                    progress = item_base
                    phase_desc = string.format("Item %d/%d", processing_state.current_item, total)
                    
                elseif cp == "loading_edited_audio" or cp == "loading_edited_audio_chunked" then
                    local als = processing_state.audio_load_state
                    local within_phase = (als.progress_percent / 100) * per_item_audio
                    progress = item_base + within_phase
                    phase_desc = string.format("Loading audio (%d/%d)", processing_state.current_item, total)
                    
                elseif cp == "detecting_edited_peaks" or cp == "processing_edited_peaks_chunked" then
                    local pds = processing_state.peak_detect_state
                    
                    -- Base includes completed audio loading phase
                    local subphase_base = item_base + per_item_audio
                    local within_phase = (pds.progress_percent / 100) * per_item_peaks
                    progress = subphase_base + within_phase
                    
                    local phase_names = {
                        downsample = "Downsampling",
                        envelope = "Creating envelope",
                        smooth = "Smoothing"
                    }
                    phase_desc = phase_names[pds.phase] or "Detecting peaks"
                    
                    if pds.phase == "find_peaks" then
                        phase_desc = pds.find_peaks_subphase == "calc_threshold" and "Calculating threshold" or "Finding peaks"
                    end
                    phase_desc = string.format("%s (%d/%d)", phase_desc, processing_state.current_item, total)

                elseif cp == "stt_edited" then
                    -- Transcribing edited item (happens once per item before matching)
                    local base_progress = item_base + per_item_audio + per_item_peaks
                    progress = base_progress
                    phase_desc = string.format("Transcribing edited item (%d/%d)", processing_state.current_item, total)

                elseif cp == "matching" then
                    -- Base includes completed audio loading and peak detection phases
                    progress = item_base + per_item_audio + per_item_peaks
                    phase_desc = string.format("Matching item %d/%d", processing_state.current_item, total)

                elseif cp == "stt_verify" then
                    -- STT verification in progress
                    local base_progress = item_base + per_item_audio + per_item_peaks + per_item_match
                    local stt_progress = 0
                    local total_matches = processing_state.stt_all_matches and #processing_state.stt_all_matches or 1
                    if total_matches > 0 then
                        stt_progress = (processing_state.stt_current_candidate / total_matches) * per_item_stt
                    end
                    progress = base_progress + stt_progress
                    phase_desc = string.format("STT verification: %d above threshold (%d/%d)",
                        processing_state.stt_candidates_to_verify,
                        processing_state.current_item,
                        total)

                elseif cp == "create_matches" then
                    -- Creating matched items
                    progress = item_base + per_item_audio + per_item_peaks + per_item_match + per_item_stt
                    phase_desc = string.format("Creating matches (%d/%d)", processing_state.current_item, total)

                elseif cp == "complete" then
                    progress = 1.0
                    phase_desc = "Complete"
                end
            end
            
            local progress_text = string.format("%s: %d%%", phase_desc, math.floor(progress * 100))
            reaper.ImGui_ProgressBar(ctx, progress, avail_width, 0, progress_text)
        end

        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Spacing(ctx)

        -- ═══════════════════════════════════════════════════════════════════════
        -- SECTION: Log (expands to fill remaining space)
        -- ═══════════════════════════════════════════════════════════════════════
        reaper.ImGui_Text(ctx, "Log:")
        reaper.ImGui_SameLine(ctx)

        -- Clear log button (right-aligned)
        local cursor_x = reaper.ImGui_GetCursorPosX(ctx)
        local log_avail_width = reaper.ImGui_GetContentRegionAvail(ctx)
        reaper.ImGui_SetCursorPosX(ctx, cursor_x + log_avail_width - 45)
        if reaper.ImGui_SmallButton(ctx, "Clear") then
            report_log = {}
        end

        -- Build log text for selectable display
        local log_text = ""
        for i = #report_log, 1, -1 do
            log_text = log_text .. report_log[i].text .. "\n"
        end

        -- Use remaining height for the log (minimum 100px)
        local log_width, log_height = reaper.ImGui_GetContentRegionAvail(ctx)
        log_height = math.max(log_height, 100)

        -- Use InputTextMultiline with ReadOnly flag for selectable/copyable text
        reaper.ImGui_InputTextMultiline(ctx, "##log", log_text, log_width, log_height,
            reaper.ImGui_InputTextFlags_ReadOnly())

        reaper.ImGui_End(ctx)
    end

    if open then
        reaper.defer(Loop)
    end
end

-- INITIALIZATION

Log("Voice Line Matcher v2.0")
Log("Load edited items and clean recording(s), then click Match.")

reaper.defer(Loop)