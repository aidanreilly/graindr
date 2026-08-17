engine.name = "Sediment"

local Waveform = include("graindr/lib/waveform")

local waveform
local g

local recording = false
local rec_time = 0
local rec_metro

local sample_name = ""
local sample_duration = 0
local buf_duration = 0

local mode_names = {"granular", "stretch", "delay"}
local current_mode = 1

local midi_device
local midi_channel = 0
local root_note = 60
local speed = 1.0
local spread_val = 0.5
local master_vol = 0.8

local NUM_VOICES = 8
local voices = {}

for i = 0, NUM_VOICES - 1 do
  voices[i] = nil
end

function init()
  g = grid.connect()
  g.key = grid_key

  waveform = Waveform.new(0, 10, 128, 38, 8)

  osc.event = function(path, args)
    if path == "/sediment/waveform" then
      waveform:set_samples(args)
    elseif path == "/sediment/buf_info" then
      local frames = args[1]
      local sr = args[2]
      if sr and sr > 0 then
        buf_duration = frames / sr
        sample_duration = buf_duration
      end
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

  midi_device = midi.connect()
  midi_device.event = midi_event

  build_params()
  params:bang()

  local screen_m = metro.init()
  screen_m.time = 1 / 15
  screen_m.event = function() redraw() end
  screen_m:start()

  local scan_m = metro.init()
  scan_m.time = 1 / 30
  scan_m.event = function()
    update_positions()
    if g then grid_refresh() end
  end
  scan_m:start()
end

function allocate_voice()
  for i = 0, NUM_VOICES - 1 do
    if voices[i] == nil then return i end
  end
  local oldest_slot = 0
  local oldest_time = math.huge
  for i = 0, NUM_VOICES - 1 do
    if voices[i].time < oldest_time then
      oldest_time = voices[i].time
      oldest_slot = i
    end
  end
  engine.note_off(oldest_slot)
  waveform:set_head_active(oldest_slot + 1, false)
  return oldest_slot
end

function find_voice_by_note(note)
  for i = 0, NUM_VOICES - 1 do
    if voices[i] and voices[i].note == note then return i end
  end
  return nil
end

function midi_event(data)
  local msg = midi.to_msg(data)
  if midi_channel > 0 and msg.ch ~= midi_channel then return end

  if msg.type == "note_on" and msg.vel > 0 then
    local slot = allocate_voice()
    local pitch = msg.note - root_note
    local amp = msg.vel / 127
    voices[slot] = {note = msg.note, time = util.time(), bufPos = 0.5}
    engine.note_on(slot, pitch, amp)
    waveform:set_head_active(slot + 1, true)
    waveform:set_head_pos(slot + 1, 0.5)
  elseif msg.type == "note_off" or (msg.type == "note_on" and msg.vel == 0) then
    local slot = find_voice_by_note(msg.note)
    if slot then
      engine.note_off(slot)
      voices[slot] = nil
      waveform:set_head_active(slot + 1, false)
    end
  end
end

function update_positions()
  if buf_duration <= 0 then return end
  local dt = 1 / 30
  for i = 0, NUM_VOICES - 1 do
    if voices[i] then
      voices[i].bufPos = voices[i].bufPos + (dt / buf_duration) * speed
      if voices[i].bufPos > 1 then voices[i].bufPos = voices[i].bufPos - 1 end
      if voices[i].bufPos < 0 then voices[i].bufPos = voices[i].bufPos + 1 end
      waveform:set_head_pos(i + 1, voices[i].bufPos)
    end
  end
end

function grid_key(x, y, z)
  if z == 0 then return end
  local slot = y - 1
  if slot >= 0 and slot < NUM_VOICES and voices[slot] then
    local pos = (x - 1) / 15
    voices[slot].bufPos = pos
    engine.voice_pos(slot, pos)
    waveform:set_head_pos(slot + 1, pos)
  end
end

function grid_refresh()
  g:all(0)
  for slot = 0, NUM_VOICES - 1 do
    if voices[slot] then
      local pos = voices[slot].bufPos
      local float_x = pos * 15 + 1
      local x_lo = math.floor(float_x)
      local x_hi = x_lo + 1
      local frac = float_x - x_lo
      local row = slot + 1
      if x_lo >= 1 and x_lo <= 16 then
        g:led(x_lo, row, math.floor((1 - frac) * 12))
      end
      if x_hi >= 1 and x_hi <= 16 then
        g:led(x_hi, row, math.floor(frac * 12))
      end
    end
  end
  g:refresh()
end

function redraw()
  screen.clear()

  screen.level(15)
  screen.move(0, 7)
  screen.text("SEDIMENT")

  screen.level(8)
  screen.move(64, 7)
  screen.text_center(mode_names[current_mode])

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
    current_mode = util.clamp(current_mode + (d > 0 and 1 or -1), 1, 3)
    params:set("mode", current_mode)
  elseif n == 2 then
    params:delta("scatter", d)
  elseif n == 3 then
    params:delta("bloom", d)
  end
end

function key(n, z)
  if z == 0 then return end
  if n == 2 then
    for i = 0, NUM_VOICES - 1 do
      if voices[i] then
        engine.note_off(i)
        voices[i] = nil
        waveform:set_head_active(i + 1, false)
      end
    end
  elseif n == 3 then
    if recording then stop_recording()
    else start_recording() end
  end
end

function load_sample(path)
  engine.buf_load(path)
  for i = 0, NUM_VOICES - 1 do
    voices[i] = nil
    waveform:set_head_active(i + 1, false)
  end
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
  engine.rec_stop()
  sample_name = "[recorded]"
  sample_duration = rec_time
  buf_duration = rec_time
end

function build_params()
  params:add_separator("SEDIMENT")

  params:add_option("mode", "mode", mode_names, 1)
  params:set_action("mode", function(x)
    current_mode = x
    engine.mode(x - 1)
  end)

  params:add_control("scatter", "scatter", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("scatter", function(x) engine.scatter(x) end)

  params:add_control("bloom", "bloom", controlspec.new(0, 1, "lin", 0, 0.3))
  params:set_action("bloom", function(x) engine.bloom(x) end)

  params:add_control("drift", "drift", controlspec.new(0, 1, "lin", 0, 0.3))
  params:set_action("drift", function(x) engine.drift(x) end)

  params:add_control("position", "position", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("position", function(x) engine.position(x) end)

  params:add_control("feedback", "feedback", controlspec.new(0, 1, "lin", 0, 0.0))
  params:set_action("feedback", function(x) engine.feedback(x) end)

  params:add_control("dry_wet", "dry/wet", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("dry_wet", function(x) engine.dry_wet(x) end)

  params:add_option("freeze", "freeze", {"off", "on"}, 1)
  params:set_action("freeze", function(x) engine.freeze(x - 1) end)

  params:add_control("speed", "speed", controlspec.new(0, 2, "lin", 0.01, 1.0))
  params:set_action("speed", function(x)
    speed = x
    engine.speed(x)
  end)

  params:add_separator("VOICES")

  params:add_control("volume", "volume", controlspec.new(0, 1, "lin", 0, 0.8))
  params:set_action("volume", function(x)
    master_vol = x
    engine.volume(x)
  end)

  params:add_control("spread", "spread", controlspec.new(0, 1, "lin", 0, 0.5))
  params:set_action("spread", function(x)
    spread_val = x
    engine.spread(x)
  end)

  params:add_separator("FILE")
  params:add_file("sample", "sample", "/home/we/dust/audio/")
  params:set_action("sample", function(path)
    if path ~= "" and path ~= "/home/we/dust/audio/" then
      load_sample(path)
    end
  end)

  params:add_separator("MIDI")

  local ch_names = {"all"}
  for i = 1, 16 do ch_names[i + 1] = tostring(i) end
  params:add_option("midi_channel", "channel", ch_names, 1)
  params:set_action("midi_channel", function(x)
    midi_channel = x - 1
  end)

  params:add_number("root_note", "root note", 0, 127, 60)
  params:set_action("root_note", function(x) root_note = x end)

  params:add_separator("INPUT")
  params:add_option("monitor", "monitor", {"off", "on"}, 1)
  params:set_action("monitor", function(x)
    if x == 2 then audio.level_monitor(1)
    else audio.level_monitor(0) end
  end)
end

function cleanup()
  if recording then stop_recording() end
  for i = 0, NUM_VOICES - 1 do
    if voices[i] then engine.note_off(i) end
  end
end
