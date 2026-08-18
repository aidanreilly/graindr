--- graindr v0.0.1
-- A polyphonic granular synth by @oootini
--
-- ▼ controls ▼
-- E1 - density
-- E2 - size
-- E3 - jitter
-- K2 - panic
-- K3 - record
-- grid - trigger, hold+tap to loop
-- midi - play the keys
--
-- engine based on glut
-- by @artfwo

engine.name = "Graindr"

local Waveform = include("graindr/lib/waveform")

local NUM_VOICES = 8
local LFO_SHAPES = {"sine", "triangle", "saw", "square", "random"}
local REFRESH = 1 / 15
local RAND_MAX = 16
-- must match maxStreams in Engine_Graindr.sc
local MAX_STREAMS = 4
-- sustain time reads "inf" at the top of its range, sent to the engine as a
-- sustain node long enough that nothing will outlast it
local SUSTAIN_INF_AT = 30
local SUSTAIN_INF = 1e9
-- the envelope poll runs at REFRESH, so a voice needs a short grace period
-- after a trigger before the polled envelope can be trusted to say it is alive
local TRIG_GUARD = 0.25
-- the encoder readout sits at full brightness while you are still turning,
-- then fades out over about the same time again
local HUD_HOLD = 0.4
local HUD_FADE = 0.4

local waveform
local g
local grid_cols = 16

local voices = {}
local phase_polls = {}
local env_polls = {}

-- x of the first pad held down on each row, or nil. the loop gesture reads
-- this: a second press while a row has an anchor sets a brace between them
-- instead of triggering a note.
local grid_anchor = {}

local recording = false
local rec_time = 0
local rec_metro

local hud_text = nil
local hud_time = 0

-- scsynth's average load, polled from crone. grains, density and size all
-- multiply into the same budget on one core, so this is the number to watch
-- while pushing them.
local cpu_load = 0
local cpu_poll

local sample_name = ""
local sample_duration = 0
-- the engine loads at most MAX_SAMPLE_SECONDS of a file. a longer one is cut
-- rather than refused, and the duration is marked so it is not a silent lie.
local MAX_SAMPLE_SECONDS = 60
local sample_truncated = false

local midi_device
local midi_channel = 0
local root_note = 60

local function db_to_amp(db)
  return 10 ^ (db / 20)
end

local function semitones_to_ratio(st)
  return 2 ^ (st / 12)
end

local function grid_pos(x)
  local span = math.max(grid_cols - 1, 1)
  return util.clamp((x - 1) / span, 0, 1)
end

-- the engine owns the envelope and polls its value back, so this is the real
-- amplitude of the voice rather than an estimate of it. the guard covers the
-- gap between firing a trigger and the first poll that reflects it.
local function sounding(i)
  local v = voices[i]
  return v.midi_note ~= nil
    or v.env > 0.001
    or (util.time() - v.trig_time) < TRIG_GUARD
end

-- MIDI transposition multiplies the voice's own pitch rather than replacing
-- it, so a voice detuned by the pitch param keeps its character
local function apply_pitch(i)
  local v = voices[i]
  if v.midi_note then
    engine.pitch(i, v.base_ratio * semitones_to_ratio(v.midi_note - root_note))
  else
    engine.pitch(i, v.base_ratio)
  end
end

-- rand amt spreads a bipolar offset across each voice param, scaled to that
-- param's own useful range. at 0 every voice is identical.
local function rand_offset(amt, range)
  if amt <= 0 then return 0 end
  return (math.random() * 2 - 1) * range * (amt / RAND_MAX)
end

-- the voice params are shared by all eight voices, so the variation between
-- them comes from here: fresh offsets are rolled for the voice being
-- triggered, which is why repeated hits on one pad never sound quite alike.
local function randomize_voice(i)
  local amt = params:get("rand_amt")

  engine.speed(i, util.clamp(
    params:get("speed") + rand_offset(amt, 1.0), -2, 2))
  engine.pan(i, util.clamp(
    params:get("pan") + rand_offset(amt, 1.0), -1, 1))
  engine.level(i, db_to_amp(util.clamp(
    params:get("level") + rand_offset(amt, 12), -60, 20)))
  engine.lfo_rate(i, util.clamp(
    params:get("lfo_rate") + rand_offset(amt, 5), 0.01, 10))
  engine.lfo_depth(i, util.clamp(
    params:get("lfo_depth") + rand_offset(amt, 2), 0, 4))

  voices[i].base_ratio =
    semitones_to_ratio(params:get("pitch") + rand_offset(amt, RAND_MAX))
  apply_pitch(i)
end

-- every voice starts from rest. a trigger rolls its random offsets, parks the
-- playhead at the last position seeked on the grid, and fires one envelope
-- cycle that runs itself out. a braced row is unbraced before it gets here,
-- so a trigger is always the one-shot.
local function trigger(i)
  local v = voices[i]
  randomize_voice(i)
  engine.seek(i, v.pos)
  engine.trig(i)
  v.trig_time = util.time()
end

local function gate_on(i)
  local v = voices[i]
  randomize_voice(i)
  engine.seek(i, v.pos)
  engine.gate(i, 1)
  v.trig_time = util.time()
end

local function silence(i)
  local v = voices[i]
  v.midi_note = nil
  v.trig_time = -math.huge
  engine.panic(i)
end

-- setting a loop takes the ADSR out of the picture: the voice sustains at
-- full level for as long as the loop is set, rather than running out its
-- envelope underneath it.
local function set_loop(i, ax, bx)
  local v = voices[i]
  local pa, pb = grid_pos(ax), grid_pos(bx)
  v.loop_a, v.loop_b = ax, bx
  v.loop_lo, v.loop_hi = math.min(pa, pb), math.max(pa, pb)
  v.loop_dir = (bx > ax) and 1 or -1
  engine.loop(i, v.loop_lo, v.loop_hi, v.loop_dir)
  engine.hold(i, 1)
  v.trig_time = util.time()
end

-- clearing the loop lets the sustain go, and the voice fades out over the
-- release time
local function clear_loop(i)
  local v = voices[i]
  v.loop_a, v.loop_b = nil, nil
  v.loop_lo, v.loop_hi, v.loop_dir = 0, 1, 1
  engine.loop_clear(i)
  engine.hold(i, 0)
end

-- a brace marks a region of the sample. when the buffer underneath it is
-- replaced there is nothing left for it to point at, so every loop is
-- dropped and the voices holding them are let go.
local function clear_all_loops()
  for i = 1, NUM_VOICES do
    if voices[i].loop_a then clear_loop(i) end
  end
end

local function allocate_voice()
  -- prefer a silent voice, so a new note does not cut off one still ringing
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
    gate_on(i)
  elseif msg.type == "note_off" or (msg.type == "note_on" and msg.vel == 0) then
    local i = find_voice_by_note(msg.note)
    if i then
      voices[i].midi_note = nil
      apply_pitch(i)
      engine.gate(i, 0)
    end
  end
end

-- one pad is a note. two pads on a row are a loop: hold the first, tap the
-- second, and the playhead runs between them in the direction you pressed.
--
-- a single press on a braced row frees the brace and plays the one-shot, so
-- the way out of a loop is the same gesture as the way into a note. holding
-- that pad and tapping a second still sets a new brace, which simply replaces
-- the one the press just dropped.
function grid_key(x, y, z)
  if y < 1 or y > NUM_VOICES then return end

  if z == 1 then
    local anchor = grid_anchor[y]
    if anchor == nil then
      grid_anchor[y] = x
      if voices[y].loop_a then clear_loop(y) end
      voices[y].pos = grid_pos(x)
      trigger(y)
    elseif x ~= anchor then
      set_loop(y, anchor, x)
    end
  else
    if grid_anchor[y] == x then grid_anchor[y] = nil end
  end
end

function grid_refresh()
  g:all(0)
  local span = math.max(grid_cols - 1, 1)

  for i = 1, NUM_VOICES do
    local v = voices[i]

    -- a loop stays visible while the voice is silent, so you can see what a
    -- row is armed to do before you play it
    if v.loop_a then
      local lo = math.min(v.loop_a, v.loop_b)
      local hi = math.max(v.loop_a, v.loop_b)
      for x = lo, hi do g:led(x, i, 1) end
      g:led(v.loop_a, i, 4)
      g:led(v.loop_b, i, 4)
    end

    -- the playhead is drawn only while the envelope is open, and fades with
    -- it, so the grid follows the same shape you hear. the dim half of an
    -- interpolated head is skipped rather than written as 0, so it cannot
    -- punch a hole in the loop markers underneath.
    local peak = math.floor(v.env * 15)
    if peak > 0 then
      local float_x = v.phase * span + 1
      local x_lo = math.floor(float_x)
      local x_hi = x_lo + 1
      local frac = float_x - x_lo
      local l_lo = math.floor((1 - frac) * peak)
      local l_hi = math.floor(frac * peak)
      if l_lo > 0 and x_lo >= 1 and x_lo <= grid_cols then
        g:led(x_lo, i, l_lo)
      end
      if l_hi > 0 and x_hi >= 1 and x_hi <= grid_cols then
        g:led(x_hi, i, l_hi)
      end
    end
  end

  g:refresh()
end

-- what the encoder just changed, over the middle of the waveform. it is laid
-- on a black plate so the waveform behind it cannot make it unreadable, and
-- it is gone a second after you stop turning.
local function draw_hud()
  if hud_text == nil then return end

  local age = util.time() - hud_time
  local level = 15
  if age > HUD_HOLD then
    level = math.floor(15 * (1 - (age - HUD_HOLD) / HUD_FADE))
  end
  if level < 1 then
    hud_text = nil
    return
  end

  local w = screen.text_extents(hud_text)
  screen.level(0)
  screen.rect(64 - (w / 2) - 3, 22, w + 6, 14)
  screen.fill()
  screen.level(level)
  screen.move(64, 32)
  screen.text_center(hud_text)
end

function redraw()
  screen.clear()

  screen.level(15)
  screen.move(0, 7)
  screen.text("GRAINDR")

  -- dim until it is worth looking at, so it does not compete with the
  -- waveform until you are actually near the edge
  screen.level(cpu_load >= 80 and 15 or 3)
  screen.move(64, 7)
  screen.text_center(string.format("%d%%", math.floor(cpu_load + 0.5)))

  for i = 1, NUM_VOICES do
    waveform:set_head_level(i, voices[i].env)
  end

  if recording then
    screen.level(15)
    screen.move(128, 7)
    local secs = math.floor(rec_time)
    screen.text_right(string.format("REC %d:%02d", math.floor(secs / 60), secs % 60))
  end

  waveform:draw()
  draw_hud()

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
    -- a leading * means the file was longer than the engine will hold and
    -- only its first MAX_SAMPLE_SECONDS are loaded
    screen.text_right(string.format("%s%d:%02d",
      sample_truncated and "*" or "", mins, secs))
  end

  screen.update()
end

function enc(n, d)
  local id
  if n == 1 then
    id = "density"
  elseif n == 2 then
    id = "size"
  elseif n == 3 then
    id = "jitter"
  end
  if id then
    params:delta(id, d)
    -- params:string is what the params menu itself renders with, so the
    -- readout carries the same units and rounding you would see in there
    hud_text = id .. "  " .. params:string(id)
    hud_time = util.time()
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
  clear_all_loops()
  engine.buf_load(path)
  sample_name = path:match("([^/]+)$") or path
end

function start_recording()
  clear_all_loops()
  recording = true
  rec_time = 0
  sample_truncated = false
  sample_name = "[recording]"
  engine.rec_start()
  rec_metro:start()
end

function stop_recording()
  recording = false
  rec_metro:stop()
  -- the trim rescales every position in the buffer, so a brace set while
  -- recording would end up pointing somewhere else entirely
  clear_all_loops()
  -- the engine trims its 60s capture buffer down to this duration
  engine.rec_stop(rec_time)
  sample_name = "[recorded]"
  sample_duration = rec_time
end

-- norns renders one level of grouping, so the sections inside GRAINDR are
-- separators rather than nested groups. everything the script owns lives
-- under the one menu item.
function build_params()
  params:add_group("graindr", 32)

  params:add_separator("sep_sample", "sample")

  params:add_file("sample", "sample", "/home/we/dust/audio/")
  params:set_action("sample", function(path)
    if path ~= "" and path ~= "/home/we/dust/audio/" then
      load_sample(path)
    end
  end)

  params:add_separator("sep_grains", "grains")

  -- parallel grain clouds over the one playhead, not a faster clock. each
  -- stream draws its own jitter and pan, so this thickens and diffuses where
  -- density only makes the same cloud denser.
  params:add_number("grains", "grains", 1, MAX_STREAMS, 1)
  params:set_action("grains", function(x) engine.grains(x) end)

  params:add_control("density", "density", controlspec.new(1, 512, "exp", 0, 20, "hz"))
  params:set_action("density", function(x) engine.density(x) end)

  params:add_control("size", "size", controlspec.new(1, 500, "exp", 0, 100, "ms"))
  params:set_action("size", function(x) engine.size(x / 1000) end)

  params:add_control("jitter", "jitter", controlspec.new(0, 500, "lin", 0, 0, "ms"))
  params:set_action("jitter", function(x) engine.jitter(x / 1000) end)

  params:add_control("spread", "spread", controlspec.new(0, 100, "lin", 0, 0, "%"))
  params:set_action("spread", function(x) engine.spread(x / 100) end)

  -- one set of voice params shared by all eight voices. rand amt is what
  -- makes them differ: it is applied per voice as each one is triggered.
  params:add_separator("sep_voices", "voices")

  params:add_control("attack", "attack", controlspec.new(0.001, 10, "exp", 0, 0.5, "s"))
  params:set_action("attack", function(x) engine.attack(x) end)

  params:add_control("decay", "decay", controlspec.new(0.001, 10, "exp", 0, 0.3, "s"))
  params:set_action("decay", function(x) engine.decay(x) end)

  params:add_control("sustain", "sustain", controlspec.new(0, 1, "lin", 0, 1.0))
  params:set_action("sustain", function(x) engine.sustain(x) end)

  -- the top of the range is infinite sustain: a press holds at the sustain
  -- level until you press again or hit K2. the engine needs no special case
  -- for it, since a sustain node long enough is indistinguishable from one
  -- that never ends.
  -- the formatter is the fourth argument to add_control, which Control passes
  -- to its constructor and calls with the param itself
  params:add_control("sustain_time", "sustain time",
    controlspec.new(0.05, 30, "exp", 0, 2.0, "s"),
    function(p)
      local x = p:get()
      if x >= SUSTAIN_INF_AT then return "inf" end
      return string.format("%.2f s", x)
    end)
  params:set_action("sustain_time", function(x)
    engine.sustain_time(x >= SUSTAIN_INF_AT and SUSTAIN_INF or x)
  end)

  params:add_control("release", "release", controlspec.new(0.001, 10, "exp", 0, 1.0, "s"))
  params:set_action("release", function(x) engine.release(x) end)

  params:add_control("speed", "speed", controlspec.new(-2, 2, "lin", 0, 1.0, "x"))
  params:set_action("speed", function(x)
    for i = 1, NUM_VOICES do engine.speed(i, x) end
  end)

  params:add_number("pitch", "pitch", -24, 24, 0)
  params:set_action("pitch", function(x)
    for i = 1, NUM_VOICES do
      voices[i].base_ratio = semitones_to_ratio(x)
      apply_pitch(i)
    end
  end)

  params:add_control("pan", "pan", controlspec.new(-1, 1, "lin", 0, 0))
  params:set_action("pan", function(x)
    for i = 1, NUM_VOICES do engine.pan(i, x) end
  end)

  params:add_control("level", "level", controlspec.new(-60, 20, "db", 0, 0, "dB"))
  params:set_action("level", function(x)
    for i = 1, NUM_VOICES do engine.level(i, db_to_amp(x)) end
  end)

  params:add_option("lfo_shape", "lfo shape", LFO_SHAPES, 1)
  params:set_action("lfo_shape", function(x)
    for i = 1, NUM_VOICES do engine.lfo_shape(i, x - 1) end
  end)

  params:add_control("lfo_rate", "lfo rate", controlspec.new(0.01, 10, "exp", 0, 0.2, "hz"))
  params:set_action("lfo_rate", function(x)
    for i = 1, NUM_VOICES do engine.lfo_rate(i, x) end
  end)

  params:add_control("lfo_depth", "lfo depth", controlspec.new(0, 4, "lin", 0, 0))
  params:set_action("lfo_depth", function(x)
    for i = 1, NUM_VOICES do engine.lfo_depth(i, x) end
  end)

  params:add_number("rand_amt", "rand amt", 0, RAND_MAX, 0)

  params:add_separator("sep_output", "output")

  params:add_control("volume", "volume", controlspec.new(-60, 20, "db", 0, 0, "dB"))
  params:set_action("volume", function(x) engine.volume(db_to_amp(x)) end)

  params:add_control("reverb_mix", "reverb mix", controlspec.new(0, 1, "lin", 0, 0.3))
  params:set_action("reverb_mix", function(x) engine.reverb_mix(x) end)

  params:add_control("reverb_room", "reverb room", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("reverb_room", function(x) engine.reverb_room(x) end)

  params:add_control("reverb_damp", "reverb damp", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("reverb_damp", function(x) engine.reverb_damp(x) end)

  params:add_separator("sep_midi", "midi")

  local ch_names = {"all"}
  for i = 1, 16 do ch_names[i + 1] = tostring(i) end
  params:add_option("midi_channel", "channel", ch_names, 1)
  params:set_action("midi_channel", function(x) midi_channel = x - 1 end)

  params:add_number("root_note", "root note", 0, 127, 60)
  params:set_action("root_note", function(x)
    root_note = x
    for i = 1, NUM_VOICES do apply_pitch(i) end
  end)

  params:add_separator("sep_input", "input")

  params:add_option("monitor", "monitor", {"off", "on"}, 1)
  params:set_action("monitor", function(x)
    audio.level_monitor(x == 2 and 1 or 0)
  end)
end

function init()
  math.randomseed(math.floor(util.time() * 1000))

  for i = 1, NUM_VOICES do
    voices[i] = {
      midi_note = nil,
      midi_time = 0,
      trig_time = -math.huge,
      base_ratio = 1.0,
      pos = (i - 1) / NUM_VOICES,
      phase = (i - 1) / NUM_VOICES,
      env = 0,
      loop_a = nil,
      loop_b = nil,
      loop_lo = 0,
      loop_hi = 1,
      loop_dir = 1
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
      -- TEMPORARY: tracing why a newly loaded sample can leave the previous
      -- waveform on screen. remove once that is understood.
      print("graindr: waveform received, " .. tostring(#args) .. " args")
      waveform:set_samples(args)
    elseif path == "/graindr/buf_info" then
      local frames, sr, truncated = args[1], args[2], args[3]
      if sr and sr > 0 then
        sample_duration = frames / sr
      end
      sample_truncated = (truncated == 1)
    end
  end

  -- playhead position and envelope both come from the engine, which owns the
  -- Phasor and the ADSR. no dead reckoning on the lua side.
  for i = 1, NUM_VOICES do
    local p = poll.set("phase_" .. i, function(val)
      voices[i].phase = val
      waveform:set_head_pos(i, val)
    end)
    p.time = REFRESH
    p:start()
    phase_polls[i] = p

    local e = poll.set("env_" .. i, function(val)
      voices[i].env = val
    end)
    e.time = REFRESH
    e:start()
    env_polls[i] = e
  end

  -- slower than the ui: an average does not need redrawing every frame, and
  -- the point of the meter is to not cost anything itself
  cpu_poll = poll.set("cpu_avg", function(val) cpu_load = val end)
  cpu_poll.time = 0.25
  cpu_poll:start()

  rec_metro = metro.init()
  rec_metro.time = 0.1
  rec_metro.event = function()
    if recording then
      rec_time = rec_time + 0.1
      if rec_time >= MAX_SAMPLE_SECONDS then stop_recording() end
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
  if cpu_poll then cpu_poll:stop() end
  for i = 1, NUM_VOICES do
    if phase_polls[i] then phase_polls[i]:stop() end
    if env_polls[i] then env_polls[i]:stop() end
    engine.gate(i, 0)
  end
end
