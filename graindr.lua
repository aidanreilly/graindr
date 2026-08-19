--- graindr v0.0.1
-- A polyphonic granular synth by @oootini
--
-- ▼ controls ▼
-- E1 - density
-- E2 - size
-- E3 - jitter
-- K2 - panic
-- K3 - record
-- grid - col 1 selects, rest triggers
-- midi - play the keys
--
-- engine based on glut
-- by @artfwo

engine.name = "Graindr"

local Waveform = include("graindr/lib/waveform")
local Delay = include("graindr/lib/delay")

local NUM_VOICES = 8
local LFO_SHAPES = {"sine", "triangle", "saw", "square", "random"}
local REFRESH = 1 / 15
local RAND_MAX = 16
-- grace period after a trigger, before the envelope poll catches up
local TRIG_GUARD = 0.25
-- encoder readout: hold at full, then fade
local HUD_HOLD = 0.4
local HUD_FADE = 0.4

-- column 1 selects a row and sets its brace mode
local CONTROL_COL = 1
local MODE_ONESHOT = 1
local MODE_LOOP = 2

local waveform
local g
local grid_cols = 16

local voices = {}
local phase_polls = {}
local env_polls = {}

-- first pad held on each row; a second press while it is held sets a brace
local grid_anchor = {}

-- per-row brace mode. governs the next gesture only, so a running loop survives.
local row_mode = {}
-- row MIDI lands on, or nil to fall back to any free voice
local selected_row = nil

local recording = false
local rec_time = 0
local rec_metro

local hud_text = nil
local hud_time = 0

-- scsynth load. density and size multiply into one core's budget.
local cpu_load = 0
local cpu_poll

-- the smooth macro writes to other params; not while init is still banging
local params_ready = false

local sample_name = ""
local sample_duration = 0
-- longer files are cut to this, and the duration is marked
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

-- positions start after the control column: 15 steps on a 16 wide grid
local function grid_span()
  return math.max(grid_cols - CONTROL_COL - 1, 1)
end

local function grid_pos(x)
  return util.clamp((x - CONTROL_COL - 1) / grid_span(), 0, 1)
end

local function pos_to_grid(pos)
  return pos * grid_span() + CONTROL_COL + 1
end

-- slow enough to read as a blink
local function blink_on()
  return math.floor(util.time() * 2) % 2 == 0
end

-- the polled envelope is the real amplitude. the guard covers poll lag.
local function sounding(i)
  local v = voices[i]
  return v.midi_note ~= nil
    or v.env > 0.001
    or (util.time() - v.trig_time) < TRIG_GUARD
end

-- transposition multiplies the voice's pitch rather than replacing it
local function apply_pitch(i)
  local v = voices[i]
  if v.midi_note then
    engine.pitch(i, v.base_ratio * semitones_to_ratio(v.midi_note - root_note))
  else
    engine.pitch(i, v.base_ratio)
  end
end

-- bipolar offset scaled to each param's range. at 0 every voice is identical.
local function rand_offset(amt, range)
  if amt <= 0 then return 0 end
  return (math.random() * 2 - 1) * range * (amt / RAND_MAX)
end

-- voice params are shared, so this is what makes voices differ. rolled per trigger.
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

-- a grid press has no gate to close, so its envelope carries its own held
-- stage. that length is the rest of the envelope summed rather than a control
-- of its own: a slow attack and long release hold for a while, a fast one does
-- not.
local function update_sustain_time()
  engine.sustain_time(params:get("attack")
    + params:get("decay")
    + params:get("release"))
end

-- one envelope cycle from the parked playhead. braced rows are freed before here.
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

-- a brace always bounds the playhead; the row mode decides the envelope over it
local function set_loop(i, ax, bx)
  local v = voices[i]
  local pa, pb = grid_pos(ax), grid_pos(bx)
  v.loop_a, v.loop_b = ax, bx
  v.loop_lo, v.loop_hi = math.min(pa, pb), math.max(pa, pb)
  v.loop_dir = (bx > ax) and 1 or -1
  engine.loop(i, v.loop_lo, v.loop_hi, v.loop_dir)
  if row_mode[i] == MODE_LOOP then
    engine.hold(i, 1)
    v.trig_time = util.time()
  end
end

-- releasing the sustain fades the voice out over the release time
local function clear_loop(i)
  local v = voices[i]
  v.loop_a, v.loop_b = nil, nil
  v.loop_lo, v.loop_hi, v.loop_dir = 0, 1, 1
  engine.loop_clear(i)
  engine.hold(i, 0)
end

-- braces point into a buffer that is about to be replaced
local function clear_all_loops()
  for i = 1, NUM_VOICES do
    if voices[i].loop_a then clear_loop(i) end
  end
end

-- from the selected row downward, wrapping. top to bottom when none is selected.
local function midi_order()
  local order = {}
  local start = (selected_row or 1) - 1
  for n = 0, NUM_VOICES - 1 do
    order[n + 1] = ((start + n) % NUM_VOICES) + 1
  end
  return order
end

local function allocate_voice()
  local order = midi_order()
  -- prefer a silent voice, so a new note does not cut off one still ringing
  for _, i in ipairs(order) do
    if voices[i].midi_note == nil and not sounding(i) then return i end
  end
  for _, i in ipairs(order) do
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

-- one pad triggers. hold one and tap another to brace, in the direction pressed.
-- a single press on a braced row frees the brace and triggers.
function grid_key(x, y, z)
  if y < 1 or y > NUM_VOICES then return end

  -- dim, lit for one-shot, blinking for loop, then dim. selection is exclusive,
  -- and the cycle always restarts from one-shot.
  if x <= CONTROL_COL then
    if z == 0 then return end
    if selected_row ~= y then
      selected_row = y
      row_mode[y] = MODE_ONESHOT
    elseif row_mode[y] == MODE_ONESHOT then
      row_mode[y] = MODE_LOOP
    else
      selected_row = nil
      row_mode[y] = MODE_ONESHOT
    end
    return
  end

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
  local lit = blink_on()

  for i = 1, NUM_VOICES do
    local v = voices[i]

    -- lowest level throughout, full on the selected row, blinking there for loop
    local ctl = 1
    if selected_row == i then
      ctl = (row_mode[i] == MODE_LOOP and not lit) and 1 or 15
    end
    g:led(CONTROL_COL, i, ctl)

    -- braces stay visible while the voice is silent
    if v.loop_a then
      local lo = math.min(v.loop_a, v.loop_b)
      local hi = math.max(v.loop_a, v.loop_b)
      for x = lo, hi do g:led(x, i, 1) end
      g:led(v.loop_a, i, 4)
      g:led(v.loop_b, i, 4)
    end

    -- drawn only while the envelope is open, fading with it. zero levels are
    -- skipped so the dim half cannot erase a brace marker.
    local peak = math.floor(v.env * 15)
    if peak > 0 then
      local float_x = pos_to_grid(v.phase)
      local x_lo = math.floor(float_x)
      local x_hi = x_lo + 1
      local frac = float_x - x_lo
      local l_lo = math.floor((1 - frac) * peak)
      local l_hi = math.floor(frac * peak)
      if l_lo > 0 and x_lo > CONTROL_COL and x_lo <= grid_cols then
        g:led(x_lo, i, l_lo)
      end
      if l_hi > 0 and x_hi > CONTROL_COL and x_hi <= grid_cols then
        g:led(x_hi, i, l_hi)
      end
    end
  end

  g:refresh()
end

-- what the encoder just changed, on a black plate below the waveform
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
  screen.rect(64 - (w / 2) - 3, 43, w + 6, 11)
  screen.fill()
  screen.level(level)
  screen.move(64, 52)
  screen.text_center(hud_text)
end

function redraw()
  screen.clear()

  screen.level(15)
  screen.move(0, 7)
  screen.text("GRAINDR")

  -- dim until it is worth looking at
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
    -- * means the file was longer than the engine holds
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
    -- params:string gives the same units and rounding as the params menu
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
  -- the trim rescales every position, so a brace set while recording would move
  clear_all_loops()
  -- the engine trims its 60s capture buffer down to this duration
  engine.rec_stop(rec_time)
  sample_name = "[recorded]"
  sample_duration = rec_time
end

-- sweeps density and size exponentially, so overlap runs from under one grain
-- to a wash. the midpoint is the defaults.
local SMOOTH_MAP = {
  density = {15, 105},
  size = {50, 450},
  scatter = {0, 60}
}

local function apply_smooth(t)
  -- not while init is banging: the defaults already stand. a pset needs no guard
  -- either, since smooth is added before the params it writes, so a pset read in
  -- param order lands the stored values on top.
  if not params_ready then return end

  local function sweep(lo, hi) return lo * ((hi / lo) ^ t) end
  params:set("density", sweep(SMOOTH_MAP.density[1], SMOOTH_MAP.density[2]))
  params:set("size", sweep(SMOOTH_MAP.size[1], SMOOTH_MAP.size[2]))
  params:set("scatter", util.linlin(0, 1, SMOOTH_MAP.scatter[1], SMOOTH_MAP.scatter[2], t))
end

-- norns renders one level of grouping, so the sections are separators
function build_params()
  params:add_group("graindr", 39)

  params:add_separator("sep_sample", "sample")

  params:add_file("sample", "sample", "/home/we/dust/audio/")
  params:set_action("sample", function(path)
    if path ~= "" and path ~= "/home/we/dust/audio/" then
      load_sample(path)
    end
  end)

  params:add_separator("sep_grains", "grains")

  -- one dial along the grainy-to-fluid axis, writing to the params underneath
  params:add_control("smooth", "smooth", controlspec.new(0, 100, "lin", 0, 50, "%"))
  params:set_action("smooth", function(x) apply_smooth(x / 100) end)

  -- density x size is the overlap, which is what fluid means. defaults sit at six.
  params:add_control("density", "density", controlspec.new(1, 512, "exp", 0, 40, "hz"))
  params:set_action("density", function(x) engine.density(x) end)

  params:add_control("size", "size", controlspec.new(1, 2000, "exp", 0, 150, "ms"))
  params:set_action("size", function(x) engine.size(x / 1000) end)

  -- how far onsets and lengths wander from the clock. at 0 the rate is audible.
  params:add_control("scatter", "scatter", controlspec.new(0, 100, "lin", 0, 30, "%"))
  params:set_action("scatter", function(x) engine.scatter(x / 100) end)

  params:add_control("jitter", "jitter", controlspec.new(0, 500, "lin", 0, 0, "ms"))
  params:set_action("jitter", function(x) engine.jitter(x / 1000) end)

  params:add_control("spread", "spread", controlspec.new(0, 100, "lin", 0, 0, "%"))
  params:set_action("spread", function(x) engine.spread(x / 100) end)

  -- one set of params for all eight voices; rand amt is what makes them differ
  params:add_separator("sep_voices", "voices")

  params:add_control("attack", "attack", controlspec.new(0.001, 10, "exp", 0, 0.5, "s"))
  params:set_action("attack", function(x)
    engine.attack(x)
    update_sustain_time()
  end)

  params:add_control("decay", "decay", controlspec.new(0.001, 10, "exp", 0, 0.3, "s"))
  params:set_action("decay", function(x)
    engine.decay(x)
    update_sustain_time()
  end)

  params:add_control("sustain", "sustain", controlspec.new(0, 1, "lin", 0, 1.0))
  params:set_action("sustain", function(x) engine.sustain(x) end)

  params:add_control("release", "release", controlspec.new(0.001, 10, "exp", 0, 1.0, "s"))
  params:set_action("release", function(x)
    engine.release(x)
    update_sustain_time()
  end)

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


  params:add_separator("sep_delay", "delay")

  params:add_control("delay_level", "level", controlspec.new(0, 1, "lin", 0, 0.2))
  params:set_action("delay_level", function(x) Delay.set_level(x) end)

  params:add_control("delay_time", "time", controlspec.new(0.05, 4, "exp", 0, 0.5, "s"))
  params:set_action("delay_time", function(x) Delay.set_time(x) end)

  params:add_control("delay_feedback", "feedback", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("delay_feedback", function(x) Delay.set_feedback(x) end)

  -- rate re-pitches the repeats, which is the tape half of halfsecond
  params:add_control("delay_rate", "rate", controlspec.new(0.5, 2, "lin", 0, 1))
  params:set_action("delay_rate", function(x) Delay.set_rate(x) end)

  params:add_control("delay_pan", "pan", controlspec.new(-1, 1, "lin", 0, 0))
  params:set_action("delay_pan", function(x) Delay.set_pan(x) end)

  params:add_control("delay_fc", "filter", controlspec.new(100, 18000, "exp", 0, 4000, "hz"))
  params:set_action("delay_fc", function(x) Delay.set_filter_fc(x) end)

  params:add_control("delay_rq", "resonance", controlspec.new(0.1, 4, "exp", 0, 2.0))
  params:set_action("delay_rq", function(x) Delay.set_filter_rq(x) end)

  -- crone's reverb, shared with the rest of the system. only the sends live
  -- here; its character stays in SYSTEM > AUDIO rather than existing twice.
  params:add_separator("sep_reverb", "reverb")

  params:add_control("rev_return", "return", controlspec.new(0, 1, "lin", 0, 1.0))
  params:set_action("rev_return", function(x) audio.level_rev_dac(x) end)

  params:add_control("rev_dry_send", "dry send", controlspec.new(0, 1, "lin", 0, 0.2))
  params:set_action("rev_dry_send", function(x) audio.level_eng_rev(x) end)

  params:add_control("rev_delay_send", "delay send", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("rev_delay_send", function(x) audio.level_cut_rev(x) end)

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

end

function init()
  math.randomseed(math.floor(util.time() * 1000))

  Delay.init()
  audio.rev_on()

  for i = 1, NUM_VOICES do
    row_mode[i] = MODE_ONESHOT
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

  -- half height, same centre line
  waveform = Waveform.new(0, 20, 128, 19, NUM_VOICES)
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
      local frames, sr, truncated = args[1], args[2], args[3]
      if sr and sr > 0 then
        sample_duration = frames / sr
      end
      sample_truncated = (truncated == 1)
    end
  end

  -- position and envelope come from the engine. no dead reckoning here.
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

  -- an average does not need redrawing every frame
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
  params_ready = true

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
  -- the sends are global state. norns has no getter for them, so the previous
  -- values cannot be restored — zeroing what this script opened is the most
  -- it can do. the reverb is left on, since turning it off would be as
  -- likely wrong as leaving it.
  Delay.stop()
  audio.level_cut_rev(0)
  audio.level_eng_rev(0)
  if cpu_poll then cpu_poll:stop() end
  for i = 1, NUM_VOICES do
    if phase_polls[i] then phase_polls[i]:stop() end
    if env_polls[i] then env_polls[i]:stop() end
    engine.gate(i, 0)
  end
end
