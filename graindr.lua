-- graindr.lua

engine.name = "Graindr"

local Waveform = include("graindr/lib/waveform")
local GridUI = include("graindr/lib/grid_ui")

local waveform
local grid_ui
local g

local recording = false
local rec_time = 0
local rec_metro
local sample_name = ""
local sample_duration = 0
local ugen_names = { "Silt", "Clast", "Sediment", "Talus", "Scree", "Loess", "Creep", "Moraine", "Tuff" }
local current_ugen = 1

-- playhead scanning state (Lua-side)
local head_positions = {}
local head_speeds = {}
local head_directions = {}
local head_active = {}

for i = 1, 7 do
  head_positions[i] = 0
  head_speeds[i] = 0.02
  head_directions[i] = 1
  head_active[i] = false
end

function init()
  g = grid.connect()
  g.key = function(x, y, z) grid_ui:key(x, y, z) end

  waveform = Waveform.new(0, 10, 128, 38)
  grid_ui = GridUI.new()

  grid_ui.on_head_start = function(head, position)
    head_active[head] = true
    head_positions[head] = position
    engine.head_start(head - 1, position)
    waveform:set_head_active(head, true)
  end

  grid_ui.on_head_reposition = function(head, position)
    head_positions[head] = position
    engine.head_position(head - 1, position)
  end

  grid_ui.on_head_stop = function(head)
    head_active[head] = false
    engine.head_stop(head - 1)
    waveform:set_head_active(head, false)
  end

  grid_ui.on_mute_toggle = function(head, state)
    if state then
      head_active[head] = false
      waveform:set_head_active(head, false)
    end
  end

  osc.event = function(path, args)
    if path == "/graindr/waveform" then
      waveform:set_samples(args)
    end
  end

  rec_metro = metro.init()
  rec_metro.time = 0.1
  rec_metro.event = function()
    if recording then
      rec_time = rec_time + 0.1
      if rec_time >= 60 then stop_recording() end
    end
  end

  build_params()
  params:bang()

  -- screen redraw 15fps
  local screen_m = metro.init()
  screen_m.time = 1 / 15
  screen_m.event = function() redraw() end
  screen_m:start()

  -- grid redraw 40fps
  local grid_m = metro.init()
  grid_m.time = 1 / 40
  grid_m.event = function() grid_ui:refresh(g) end
  grid_m:start()

  -- playhead scanning 30fps
  local scan_m = metro.init()
  scan_m.time = 1 / 30
  scan_m.event = scan_playheads
  scan_m:start()
end

function scan_playheads()
  local dt = 1 / 30
  for i = 1, 7 do
    if head_active[i] and not grid_ui:is_muted(i) then
      head_positions[i] = head_positions[i] + head_speeds[i] * head_directions[i] * dt

      -- wrap
      if head_positions[i] > 1 then
        head_positions[i] = head_positions[i] - 1
      elseif head_positions[i] < 0 then
        head_positions[i] = head_positions[i] + 1
      end

      engine.head_position(i - 1, head_positions[i])
      waveform:set_head_pos(i, head_positions[i])
      grid_ui:set_head_pos(i, head_positions[i])
    end
  end
end

function build_params()
  params:add_separator("GRAINDR")

  params:add_option("ugen", "ugen", ugen_names, 1)
  params:set_action("ugen", function(x)
    current_ugen = x
    engine.ugen_select(x - 1)
    -- stop all playheads on UGen switch
    for i = 1, 7 do
      head_active[i] = false
      waveform:set_head_active(i, false)
      grid_ui:set_head_active(i, false)
    end
    grid_ui:stop_all()
  end)

  -- FILE
  params:add_separator("FILE")
  params:add_file("sample", "sample", "/home/we/dust/audio/")
  params:set_action("sample", function(path)
    if path ~= "" and path ~= "/home/we/dust/audio/" then
      load_sample(path)
    end
  end)

  -- PLAYHEADS
  params:add_separator("PLAYHEADS")
  for i = 1, 7 do
    params:add_control("head_" .. i .. "_speed", "head " .. i .. " speed",
      controlspec.new(0, 0.5, "lin", 0.001, 0.02))
    params:set_action("head_" .. i .. "_speed", function(x)
      head_speeds[i] = x
    end)
    params:add_option("head_" .. i .. "_dir", "head " .. i .. " dir",
      {"forward", "reverse"}, 1)
    params:set_action("head_" .. i .. "_dir", function(x)
      head_directions[i] = (x == 1) and 1 or -1
    end)
    params:add_control("head_" .. i .. "_vol", "head " .. i .. " vol",
      controlspec.new(0, 1, "lin", 0, 0.8))
    params:set_action("head_" .. i .. "_vol", function(x)
      engine.head_volume(i - 1, x)
    end)
    params:add_control("head_" .. i .. "_pan", "head " .. i .. " pan",
      controlspec.new(-1, 1, "lin", 0, 0))
    params:set_action("head_" .. i .. "_pan", function(x)
      engine.head_pan(i - 1, x)
    end)
  end

  -- SILT
  params:add_separator("SILT")
  params:add_control("silt_density", "density", controlspec.new(1, 200, "lin", 0.1, 20))
  params:set_action("silt_density", function(x) engine.silt_density(x) end)
  params:add_control("silt_dur", "dur", controlspec.new(0.001, 1.0, "exp", 0, 0.1, "s"))
  params:set_action("silt_dur", function(x) engine.silt_dur(x) end)
  params:add_control("silt_scatter", "scatter", controlspec.new(0, 1, "lin", 0, 0.3))
  params:set_action("silt_scatter", function(x) engine.silt_scatter(x) end)
  params:add_option("silt_dist", "distribution", {"uniform", "normal", "exponential"}, 1)
  params:set_action("silt_dist", function(x) engine.silt_dist(x - 1) end)
  params:add_control("silt_distParam", "dist param", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("silt_distParam", function(x) engine.silt_distParam(x) end)
  params:add_control("silt_pitch", "pitch", controlspec.new(-24, 24, "lin", 0.01, 0, "st"))
  params:set_action("silt_pitch", function(x) engine.silt_pitch(x) end)
  params:add_control("silt_shape", "shape", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("silt_shape", function(x) engine.silt_shape(x) end)

  -- CLAST
  params:add_separator("CLAST")
  params:add_control("clast_cycles", "cycles", controlspec.new(1, 64, "lin", 1, 4))
  params:set_action("clast_cycles", function(x) engine.clast_cycles(x) end)
  params:add_control("clast_density", "density", controlspec.new(1, 200, "lin", 0.1, 40))
  params:set_action("clast_density", function(x) engine.clast_density(x) end)
  params:add_control("clast_scan", "scan", controlspec.new(-1, 1, "lin", 0, 0))
  params:set_action("clast_scan", function(x) engine.clast_scan(x) end)
  params:add_control("clast_pitch", "pitch", controlspec.new(-24, 24, "lin", 0.01, 0, "st"))
  params:set_action("clast_pitch", function(x) engine.clast_pitch(x) end)
  params:add_control("clast_spread", "spread", controlspec.new(0, 1, "lin", 0, 0.4))
  params:set_action("clast_spread", function(x) engine.clast_spread(x) end)
  params:add_control("clast_shape", "shape", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("clast_shape", function(x) engine.clast_shape(x) end)

  -- SEDIMENT
  params:add_separator("SEDIMENT")
  params:add_control("sed_pitch", "pitch", controlspec.new(-24, 24, "lin", 0.01, 0, "st"))
  params:set_action("sed_pitch", function(x) engine.sed_pitch(x) end)
  params:add_control("sed_scatter", "scatter", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("sed_scatter", function(x) engine.sed_scatter(x) end)
  params:add_control("sed_bloom", "bloom", controlspec.new(0, 1, "lin", 0, 0.3))
  params:set_action("sed_bloom", function(x) engine.sed_bloom(x) end)
  params:add_control("sed_drift", "drift", controlspec.new(0, 1, "lin", 0, 0.3))
  params:set_action("sed_drift", function(x) engine.sed_drift(x) end)
  params:add_control("sed_feedback", "feedback", controlspec.new(0, 1, "lin", 0, 0))
  params:set_action("sed_feedback", function(x) engine.sed_feedback(x) end)
  params:add_control("sed_dryWet", "dry/wet", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("sed_dryWet", function(x) engine.sed_dryWet(x) end)
  params:add_option("sed_freeze", "freeze", {"off", "on"}, 1)
  params:set_action("sed_freeze", function(x) engine.sed_freeze(x - 1) end)
  params:add_option("sed_mode", "mode", {"granular", "stretch", "looping delay"}, 1)
  params:set_action("sed_mode", function(x) engine.sed_mode(x - 1) end)

  -- TALUS
  params:add_separator("TALUS")
  params:add_control("talus_density", "density", controlspec.new(1, 200, "lin", 0.1, 20))
  params:set_action("talus_density", function(x) engine.talus_density(x) end)
  params:add_control("talus_dur", "dur", controlspec.new(0.001, 1.0, "exp", 0, 0.2, "s"))
  params:set_action("talus_dur", function(x) engine.talus_dur(x) end)
  params:add_control("talus_pitch", "pitch", controlspec.new(-24, 24, "lin", 0.01, 0, "st"))
  params:set_action("talus_pitch", function(x) engine.talus_pitch(x) end)
  params:add_control("talus_feedback", "feedback", controlspec.new(0, 0.95, "lin", 0, 0.3))
  params:set_action("talus_feedback", function(x) engine.talus_feedback(x) end)
  params:add_control("talus_spread", "spread", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("talus_spread", function(x) engine.talus_spread(x) end)

  -- SCREE
  params:add_separator("SCREE")
  params:add_control("scree_jump", "jump", controlspec.new(0, 1, "lin", 0, 0.3))
  params:set_action("scree_jump", function(x) engine.scree_jump(x) end)
  params:add_control("scree_repeats", "repeats", controlspec.new(1, 16, "lin", 1, 2))
  params:set_action("scree_repeats", function(x) engine.scree_repeats(x) end)
  params:add_control("scree_pitch", "pitch", controlspec.new(-24, 24, "lin", 0.01, 0, "st"))
  params:set_action("scree_pitch", function(x) engine.scree_pitch(x) end)
  params:add_control("scree_scatter", "scatter", controlspec.new(0, 1, "lin", 0, 0.3))
  params:set_action("scree_scatter", function(x) engine.scree_scatter(x) end)

  -- LOESS
  params:add_separator("LOESS")
  params:add_control("loess_density", "density", controlspec.new(10, 1000, "exp", 1, 300))
  params:set_action("loess_density", function(x) engine.loess_density(x) end)
  params:add_control("loess_grainDur", "grain dur", controlspec.new(0.001, 0.05, "exp", 0, 0.006, "s"))
  params:set_action("loess_grainDur", function(x) engine.loess_grainDur(x) end)
  params:add_control("loess_pitch", "pitch", controlspec.new(-24, 24, "lin", 0.01, 0, "st"))
  params:set_action("loess_pitch", function(x) engine.loess_pitch(x) end)
  params:add_control("loess_pitchSpread", "pitch spread", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("loess_pitchSpread", function(x) engine.loess_pitchSpread(x) end)

  -- CREEP
  params:add_separator("CREEP")
  params:add_control("creep_ambitus", "ambitus", controlspec.new(0.01, 2.0, "lin", 0, 1.0, "s"))
  params:set_action("creep_ambitus", function(x) engine.creep_ambitus(x) end)
  params:add_control("creep_grainDur", "grain dur", controlspec.new(0.01, 0.5, "exp", 0, 0.12, "s"))
  params:set_action("creep_grainDur", function(x) engine.creep_grainDur(x) end)
  params:add_control("creep_overlap", "overlap", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("creep_overlap", function(x) engine.creep_overlap(x) end)
  params:add_control("creep_pitch", "pitch", controlspec.new(-24, 24, "lin", 0.01, 0, "st"))
  params:set_action("creep_pitch", function(x) engine.creep_pitch(x) end)
  params:add_control("creep_pause", "pause", controlspec.new(0, 1, "lin", 0, 0))
  params:set_action("creep_pause", function(x) engine.creep_pause(x) end)
  params:add_control("creep_spread", "spread", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("creep_spread", function(x) engine.creep_spread(x) end)

  -- MORAINE
  params:add_separator("MORAINE")
  params:add_option("moraine_mode", "mode", {"omit", "duplicate", "reorder", "timewarp"}, 1)
  params:set_action("moraine_mode", function(x) engine.moraine_mode(x - 1) end)
  params:add_control("moraine_gate", "gate", controlspec.new(0.001, 0.5, "exp", 0, 0.05))
  params:set_action("moraine_gate", function(x) engine.moraine_gate(x) end)
  params:add_control("moraine_minHole", "min hole", controlspec.new(0.001, 0.2, "exp", 0, 0.02, "s"))
  params:set_action("moraine_minHole", function(x) engine.moraine_minHole(x) end)
  params:add_control("moraine_pitch", "pitch", controlspec.new(-24, 24, "lin", 0.01, 0, "st"))
  params:set_action("moraine_pitch", function(x) engine.moraine_pitch(x) end)

  -- TUFF
  params:add_separator("TUFF")
  params:add_control("tuff_form", "formant", controlspec.new(100, 5000, "exp", 0, 700, "Hz"))
  params:set_action("tuff_form", function(x) engine.tuff_form(x) end)
  params:add_control("tuff_attack", "attack", controlspec.new(0.0005, 0.05, "exp", 0, 0.003, "s"))
  params:set_action("tuff_attack", function(x) engine.tuff_attack(x) end)
  params:add_control("tuff_decay", "decay", controlspec.new(0.005, 0.2, "exp", 0, 0.02, "s"))
  params:set_action("tuff_decay", function(x) engine.tuff_decay(x) end)
  params:add_control("tuff_dur", "dur", controlspec.new(0.01, 0.2, "exp", 0, 0.05, "s"))
  params:set_action("tuff_dur", function(x) engine.tuff_dur(x) end)
  params:add_control("tuff_band", "bandwidth", controlspec.new(10, 500, "exp", 0, 60, "Hz"))
  params:set_action("tuff_band", function(x) engine.tuff_band(x) end)
  params:add_control("tuff_oct", "octave", controlspec.new(-2, 2, "lin", 1, 0))
  params:set_action("tuff_oct", function(x) engine.tuff_oct(x) end)
  params:add_control("tuff_spread", "spread", controlspec.new(0, 1, "lin", 0, 0))
  params:set_action("tuff_spread", function(x) engine.tuff_spread(x) end)

  -- INPUT
  params:add_separator("INPUT")
  params:add_control("input_level", "input level", controlspec.new(0, 1, "lin", 0, 1.0))
  params:add_option("monitor", "monitor", {"off", "on"}, 1)
  params:set_action("monitor", function(x)
    if x == 2 then audio.level_monitor(1)
    else audio.level_monitor(0) end
  end)
end

function redraw()
  screen.clear()

  -- header: UGen name
  screen.level(15)
  screen.move(0, 7)
  screen.text(ugen_names[current_ugen]:upper())

  -- recording indicator
  if recording then
    screen.level(15)
    screen.move(80, 7)
    local secs = math.floor(rec_time)
    screen.text(string.format("REC %d:%02d", math.floor(secs / 60), secs % 60))
  end

  -- waveform
  waveform:draw()

  -- footer: sample name and duration
  screen.level(4)
  screen.move(0, 63)
  local display_name = sample_name
  if #display_name > 20 then
    display_name = display_name:sub(1, 20) .. "..."
  end
  screen.text(display_name)
  if sample_duration > 0 then
    local mins = math.floor(sample_duration / 60)
    local secs = math.floor(sample_duration % 60)
    screen.move(128, 63)
    screen.text_right(string.format("%d:%02d", mins, secs))
  end

  screen.update()
end

function enc(n, d)
  if n == 1 then
    -- cycle UGen
    current_ugen = util.clamp(current_ugen + (d > 0 and 1 or -1), 1, 9)
    params:set("ugen", current_ugen)
  elseif n == 2 then
    -- global playhead speed
    for i = 1, 7 do
      local current = head_speeds[i]
      head_speeds[i] = util.clamp(current + d * 0.002, 0, 0.5)
      params:set("head_" .. i .. "_speed", head_speeds[i], true)
    end
  end
end

function key(n, z)
  if z == 0 then return end

  if n == 2 then
    -- stop all playheads
    for i = 1, 7 do
      head_active[i] = false
      engine.head_stop(i - 1)
      waveform:set_head_active(i, false)
      grid_ui:set_head_active(i, false)
    end
    grid_ui:stop_all()
  elseif n == 3 then
    -- toggle recording
    if recording then
      stop_recording()
    else
      start_recording()
    end
  end
end

function load_sample(path)
  engine.buf_load(path)
  sample_name = path:match("([^/]+)$") or path
  params:set("sample", path, true)
end

function start_recording()
  recording = true
  rec_time = 0
  sample_name = "[recording]"
  engine.rec_start()
  rec_metro:start()
end

function stop_recording()
  recording = false
  rec_metro:stop()
  engine.rec_stop()
  sample_name = "[recorded]"
  sample_duration = rec_time
end

function cleanup()
  if recording then stop_recording() end
  for i = 0, 6 do engine.head_stop(i) end
end
