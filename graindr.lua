--- graindr v0.0.1
-- A polyphonic granular synth by @oootini
--
-- ▼ controls ▼
-- E1 - density
-- E2 - size 
-- E3 - jitter
-- K2 - panic 
-- K3 - record
-- grid - seek and play
-- midi - play the keys
--
-- engine based on glut
-- by @artfwo

engine.name = "Graindr"

local Waveform = include("graindr/lib/waveform")

local NUM_VOICES = 8
local LFO_SHAPES = {"sine", "triangle", "saw", "square", "random"}
local REFRESH = 1 / 15

local waveform
local g
local grid_cols = 16

local voices = {}
local phase_polls = {}

local sustain_infinite = false
local sustain_time = 2.0
local release_time = 1.0

local recording = false
local rec_time = 0
local rec_metro

local sample_name = ""
local sample_duration = 0

local midi_device
local midi_channel = 0
local root_note = 60

local function db_to_amp(db)
  return 10 ^ (db / 20)
end

local function semitones_to_ratio(st)
  return 2 ^ (st / 12)
end

-- display only. the engine owns the envelope, so this is an estimate of
-- whether a voice is still making sound: a held MIDI note, a latched grid
-- press, or a timed trigger that has not yet run out its sustain and release.
local function sounding(i)
  local v = voices[i]
  return v.midi_note ~= nil or v.latched or util.time() < v.trig_until
end

-- a grid press fires one complete envelope cycle. with sustain set to
-- infinite it latches the gate open instead, and only K2 closes it again.
local function trigger(i)
  if sustain_infinite then
    voices[i].latched = true
    engine.latch(i, 1)
  else
    voices[i].trig_until = util.time() + sustain_time + release_time
    engine.trig(i)
  end
end

local function silence(i)
  local v = voices[i]
  v.latched = false
  v.midi_note = nil
  v.trig_until = 0
  engine.latch(i, 0)
  engine.gate(i, 0)
end

-- MIDI transposition multiplies the voice's own pitch param rather than
-- replacing it, so a voice detuned in the params menu keeps its character
local function apply_pitch(i)
  local v = voices[i]
  if v.midi_note then
    engine.pitch(i, v.base_ratio * semitones_to_ratio(v.midi_note - root_note))
  else
    engine.pitch(i, v.base_ratio)
  end
end

local function allocate_voice()
  -- prefer a silent voice, so MIDI does not interrupt a drone you started
  for i = 1, NUM_VOICES do
    if voices[i].midi_note == nil and not sounding(i) then return i end
  end
  for i = 1, NUM_VOICES do
    if voices[i].midi_note == nil then return i end
  end
  local oldest, oldest_time = 1, math.huge
  for i = 1, NUM_VOICES do
    if voices[i].midi_time < oldest_time then
      oldest_time = voices[i].midi_time
      oldest = i
    end
  end
  return oldest
end

local function find_voice_by_note(note)
  for i = 1, NUM_VOICES do
    if voices[i].midi_note == note then return i end
  end
  return nil
end

function midi_event(data)
  local msg = midi.to_msg(data)
  if midi_channel > 0 and msg.ch ~= midi_channel then return end

  if msg.type == "note_on" and msg.vel > 0 then
    local i = allocate_voice()
    voices[i].midi_note = msg.note
    voices[i].midi_time = util.time()
    apply_pitch(i)
    engine.gate(i, 1)
  elseif msg.type == "note_off" or (msg.type == "note_on" and msg.vel == 0) then
    local i = find_voice_by_note(msg.note)
    if i then
      voices[i].midi_note = nil
      apply_pitch(i)
      engine.gate(i, 0)
    end
  end
end

function grid_key(x, y, z)
  if z == 0 then return end
  if y < 1 or y > NUM_VOICES then return end

  local span = math.max(grid_cols - 1, 1)
  local pos = util.clamp((x - 1) / span, 0, 1)
  engine.seek(y, pos)
  trigger(y)
end

function grid_refresh()
  g:all(0)
  local span = math.max(grid_cols - 1, 1)
  for i = 1, NUM_VOICES do
    -- brightness is the only cue for which voices are live, now that there
    -- is no mute column
    local peak = sounding(i) and 15 or 4
    local float_x = voices[i].phase * span + 1
    local x_lo = math.floor(float_x)
    local x_hi = x_lo + 1
    local frac = float_x - x_lo
    if x_lo >= 1 and x_lo <= grid_cols then
      g:led(x_lo, i, math.floor((1 - frac) * peak))
    end
    if x_hi >= 1 and x_hi <= grid_cols then
      g:led(x_hi, i, math.floor(frac * peak))
    end
  end
  g:refresh()
end

function redraw()
  screen.clear()

  screen.level(15)
  screen.move(0, 7)
  screen.text("GRAINDR")

  local n = 0
  for i = 1, NUM_VOICES do
    local s = sounding(i)
    waveform:set_head_active(i, s)
    if s then n = n + 1 end
  end
  screen.level(8)
  screen.move(64, 7)
  screen.text_center(n .. (n == 1 and " voice" or " voices"))

  if recording then
    screen.level(15)
    screen.move(128, 7)
    local secs = math.floor(rec_time)
    screen.text_right(string.format("REC %d:%02d", math.floor(secs / 60), secs % 60))
  end

  waveform:draw()

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
    params:delta("density", d)
  elseif n == 2 then
    params:delta("size", d)
  elseif n == 3 then
    params:delta("jitter", d)
  end
end

function key(n, z)
  if z == 0 then return end
  if n == 2 then
    for i = 1, NUM_VOICES do
      silence(i)
      apply_pitch(i)
    end
  elseif n == 3 then
    if recording then stop_recording() else start_recording() end
  end
end

function load_sample(path)
  engine.buf_load(path)
  sample_name = path:match("([^/]+)$") or path
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
  -- the engine trims its 60s capture buffer down to this duration
  engine.rec_stop(rec_time)
  sample_name = "[recorded]"
  sample_duration = rec_time
end

function build_params()
  params:add_group("GLOBAL", 15)

  params:add_control("density", "density", controlspec.new(1, 512, "exp", 0, 20, "hz"))
  params:set_action("density", function(x) engine.density(x) end)

  params:add_control("size", "size", controlspec.new(1, 500, "exp", 0, 100, "ms"))
  params:set_action("size", function(x) engine.size(x / 1000) end)

  params:add_control("jitter", "jitter", controlspec.new(0, 500, "lin", 0, 0, "ms"))
  params:set_action("jitter", function(x) engine.jitter(x / 1000) end)

  params:add_control("spread", "spread", controlspec.new(0, 100, "lin", 0, 0, "%"))
  params:set_action("spread", function(x) engine.spread(x / 100) end)

  params:add_control("attack", "attack", controlspec.new(0.001, 10, "exp", 0, 0.5, "s"))
  params:set_action("attack", function(x) engine.attack(x) end)

  params:add_control("decay", "decay", controlspec.new(0.001, 10, "exp", 0, 0.3, "s"))
  params:set_action("decay", function(x) engine.decay(x) end)

  params:add_control("sustain", "sustain level", controlspec.new(0, 1, "lin", 0, 1.0))
  params:set_action("sustain", function(x) engine.sustain(x) end)

  -- infinite sustain is what turns a grid press into a drone. the engine
  -- needs no special case for it: lua latches the gate instead of firing
  -- the timed trigger.
  params:add_option("sustain_mode", "sustain mode", {"timed", "infinite"}, 1)
  params:set_action("sustain_mode", function(x) sustain_infinite = (x == 2) end)

  params:add_control("sustain_time", "sustain time", controlspec.new(0.05, 30, "exp", 0, 2.0, "s"))
  params:set_action("sustain_time", function(x)
    sustain_time = x
    engine.sustain_time(x)
  end)

  params:add_control("release", "release", controlspec.new(0.001, 10, "exp", 0, 1.0, "s"))
  params:set_action("release", function(x)
    release_time = x
    engine.release(x)
  end)

  params:add_control("volume", "volume", controlspec.new(-60, 20, "db", 0, 0, "dB"))
  params:set_action("volume", function(x) engine.volume(db_to_amp(x)) end)

  params:add_control("reverb_mix", "reverb mix", controlspec.new(0, 1, "lin", 0, 0.3))
  params:set_action("reverb_mix", function(x) engine.reverb_mix(x) end)

  params:add_control("reverb_room", "reverb room", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("reverb_room", function(x) engine.reverb_room(x) end)

  params:add_control("reverb_damp", "reverb damp", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("reverb_damp", function(x) engine.reverb_damp(x) end)

  params:add_file("sample", "sample", "/home/we/dust/audio/")
  params:set_action("sample", function(path)
    if path ~= "" and path ~= "/home/we/dust/audio/" then
      load_sample(path)
    end
  end)

  for i = 1, NUM_VOICES do
    params:add_group("voice " .. i, 7)

    params:add_control("speed_" .. i, "speed", controlspec.new(-2, 2, "lin", 0, 1.0, "x"))
    params:set_action("speed_" .. i, function(x) engine.speed(i, x) end)

    params:add_number("pitch_" .. i, "pitch", -24, 24, 0)
    params:set_action("pitch_" .. i, function(x)
      voices[i].base_ratio = semitones_to_ratio(x)
      apply_pitch(i)
    end)

    params:add_control("pan_" .. i, "pan", controlspec.new(-1, 1, "lin", 0, 0))
    params:set_action("pan_" .. i, function(x) engine.pan(i, x) end)

    params:add_control("level_" .. i, "level", controlspec.new(-60, 20, "db", 0, 0, "dB"))
    params:set_action("level_" .. i, function(x) engine.level(i, db_to_amp(x)) end)

    params:add_option("lfo_shape_" .. i, "lfo shape", LFO_SHAPES, 1)
    params:set_action("lfo_shape_" .. i, function(x) engine.lfo_shape(i, x - 1) end)

    params:add_control("lfo_rate_" .. i, "lfo rate", controlspec.new(0.01, 10, "exp", 0, 0.2, "hz"))
    params:set_action("lfo_rate_" .. i, function(x) engine.lfo_rate(i, x) end)

    params:add_control("lfo_depth_" .. i, "lfo depth", controlspec.new(0, 4, "lin", 0, 0))
    params:set_action("lfo_depth_" .. i, function(x) engine.lfo_depth(i, x) end)
  end

  params:add_group("MIDI", 2)

  local ch_names = {"all"}
  for i = 1, 16 do ch_names[i + 1] = tostring(i) end
  params:add_option("midi_channel", "channel", ch_names, 1)
  params:set_action("midi_channel", function(x) midi_channel = x - 1 end)

  params:add_number("root_note", "root note", 0, 127, 60)
  params:set_action("root_note", function(x)
    root_note = x
    for i = 1, NUM_VOICES do apply_pitch(i) end
  end)

  params:add_group("INPUT", 1)
  params:add_option("monitor", "monitor", {"off", "on"}, 1)
  params:set_action("monitor", function(x)
    audio.level_monitor(x == 2 and 1 or 0)
  end)
end

function init()
  for i = 1, NUM_VOICES do
    voices[i] = {
      latched = false,
      trig_until = 0,
      midi_note = nil,
      midi_time = 0,
      base_ratio = 1.0,
      phase = (i - 1) / NUM_VOICES
    }
  end

  waveform = Waveform.new(0, 10, 128, 38, NUM_VOICES)
  for i = 1, NUM_VOICES do
    waveform:set_head_pos(i, voices[i].phase)
  end

  g = grid.connect()
  g.key = grid_key
  if g.cols and g.cols > 0 then grid_cols = g.cols end

  osc.event = function(path, args)
    if path == "/graindr/waveform" then
      waveform:set_samples(args)
    elseif path == "/graindr/buf_info" then
      local frames, sr = args[1], args[2]
      if sr and sr > 0 then
        sample_duration = frames / sr
      end
    end
  end

  -- playhead position comes from the engine, which owns the Phasor and the
  -- LFO driving it. no dead reckoning on the lua side.
  for i = 1, NUM_VOICES do
    local p = poll.set("phase_" .. i, function(val)
      voices[i].phase = val
      waveform:set_head_pos(i, val)
    end)
    p.time = REFRESH
    p:start()
    phase_polls[i] = p
  end

  rec_metro = metro.init()
  rec_metro.time = 0.1
  rec_metro.event = function()
    if recording then
      rec_time = rec_time + 0.1
      if rec_time >= 60 then stop_recording() end
    end
  end

  midi_device = midi.connect()
  midi_device.event = midi_event

  build_params()
  params:bang()

  local ui_metro = metro.init()
  ui_metro.time = REFRESH
  ui_metro.event = function()
    redraw()
    if g then grid_refresh() end
  end
  ui_metro:start()
end

function cleanup()
  if recording then stop_recording() end
  for i = 1, NUM_VOICES do
    if phase_polls[i] then phase_polls[i]:stop() end
    engine.gate(i, 0)
    engine.latch(i, 0)
  end
end
