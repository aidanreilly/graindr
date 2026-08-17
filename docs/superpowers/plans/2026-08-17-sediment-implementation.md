# sediment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a focused norns granular instrument using the Sediment UGen with MIDI polyphony, grid 128 spatial control, and waveform display.

**Architecture:** New dedicated SuperCollider engine (Engine_Sediment.sc) with a BufRd→Sediment SynthDef for 8 polyphonic voices. MIDI note-on/off allocates and releases voices at chromatic pitches. Grid rows reposition each voice's buffer read position. Lua-side position tracking at 30fps drives waveform and grid LED display.

**Tech Stack:** Lua (norns), SuperCollider (CroneEngine), Sediment UGen plugin

**Spec:** docs/superpowers/specs/2026-08-17-sediment-design.md

## Global Constraints

- Maximum 8 simultaneous voices (RPi resource limit).
- Sediment UGen must be pre-installed on norns (from the Sediment plugin package).
- Voice slot indices: engine 0-7, grid rows 1-8. Convert at boundary with `slot + 1` (Lua→display) and `row - 1` (grid→engine).
- MIDI pitch mapping: `pitch = midi_note - root_note` in semitones. Sediment clamps to -48..48 internally.
- All Sediment params are global (affect all active voices equally). Per-voice differentiation: pitch (MIDI), buffer position (grid), pan (auto-spread), amplitude (MIDI velocity × master volume).
- Buffer is mono (1 channel). BufRd reads channel 0.
- OSC waveform path: `/sediment/waveform` (256 ints: 128 min/max pairs, each 0-126).
- OSC buffer info path: `/sediment/buf_info` (frames, sampleRate).

---

### Task 1: SuperCollider Engine

**Files:**
- Create: `lib/Engine_Sediment.sc`

**Interfaces:**
- Consumes: Sediment UGen (from installed plugin), CroneEngine base class
- Produces: Engine commands consumed by sediment.lua — `note_on(slot, pitch, amp)`, `note_off(slot)`, `voice_pos(slot, pos)`, `scatter(val)`, `bloom(val)`, `drift(val)`, `position(val)`, `feedback(val)`, `dry_wet(val)`, `freeze(val)`, `mode(val)`, `speed(val)`, `volume(val)`, `spread(val)`, `buf_load(path)`, `rec_start()`, `rec_stop()`. OSC messages: `/sediment/waveform` (256 ints), `/sediment/buf_info` (frames, sampleRate).

- [ ] **Step 1: Write the Engine_Sediment.sc file with SynthDefs and all commands**

```supercollider
Engine_Sediment : CroneEngine {
    var buffer;
    var <voices;
    var <voiceVel;
    var <recSynth;
    var params;
    var spreadVal;

    *new { arg context, doneCallback;
        ^super.new(context, doneCallback);
    }

    alloc {
        voices = Array.fill(8, { nil });
        voiceVel = Array.fill(8, { 0.0 });
        spreadVal = 0.5;

        buffer = Buffer.alloc(context.server, 48000 * 60, 1);

        params = Dictionary[
            \scatter -> 0.5, \bloom -> 0.3, \drift -> 0.3,
            \position -> 0.5, \feedback -> 0.0, \dryWet -> 0.5,
            \freeze -> 0, \mode -> 0, \speed -> 1.0, \amp -> 0.8
        ];

        SynthDef(\sediment_voice, { arg out=0, bufnum, gate=1,
            t_jump=0, bufPos=0.5, speed=1,
            pitch=0, position=0.5, scatter=0.5, bloom=0.3,
            drift=0.3, feedback=0, dryWet=0.5, freeze=0,
            mode=0,
            amp=0.8, pan=0;
            var frames = BufFrames.kr(bufnum);
            var rate = BufRateScale.kr(bufnum) * speed;
            var phase = Phasor.ar(t_jump, rate, 0, frames, bufPos * frames);
            var inMono = BufRd.ar(1, bufnum, phase, interpolation: 4);
            var sig = Sediment.ar(inMono, inMono, pitch, position, scatter,
                                  bloom, drift, feedback, dryWet, freeze, mode);
            var env = EnvGen.kr(Env.asr(0.01, 1, 0.1), gate, doneAction: 2);
            Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
        }).add;

        SynthDef(\sediment_rec, { arg bufnum, gate=1;
            var in = SoundIn.ar(0);
            var env = EnvGen.kr(Env.asr(0, 1, 0.01), gate, doneAction: 2);
            RecordBuf.ar(in * env, bufnum, loop: 0);
        }).add;

        this.addCommand("note_on", "iff", { arg msg;
            var slot = msg[1].asInteger.clip(0, 7);
            var pitch = msg[2].asFloat;
            var amp = msg[3].asFloat;

            if(voices[slot].notNil, {
                voices[slot].set(\gate, 0);
            });

            voiceVel[slot] = amp;
            voices[slot] = Synth(\sediment_voice, [
                \out, 0, \bufnum, buffer.bufnum,
                \bufPos, 0.5, \speed, params[\speed],
                \pitch, pitch, \position, params[\position],
                \scatter, params[\scatter], \bloom, params[\bloom],
                \drift, params[\drift], \feedback, params[\feedback],
                \dryWet, params[\dryWet], \freeze, params[\freeze],
                \mode, params[\mode],
                \amp, amp * params[\amp],
                \pan, (slot - 3.5) / 3.5 * spreadVal,
                \t_jump, 1
            ], context.server);
        });

        this.addCommand("note_off", "i", { arg msg;
            var slot = msg[1].asInteger.clip(0, 7);
            if(voices[slot].notNil, {
                voices[slot].set(\gate, 0);
                voices[slot] = nil;
                voiceVel[slot] = 0.0;
            });
        });

        this.addCommand("voice_pos", "if", { arg msg;
            var slot = msg[1].asInteger.clip(0, 7);
            var pos = msg[2].asFloat.clip(0, 1);
            if(voices[slot].notNil, {
                voices[slot].set(\bufPos, pos, \t_jump, 1);
            });
        });

        this.addCommand("scatter", "f", { arg msg;
            params[\scatter] = msg[1].asFloat;
            voices.do({ arg synth;
                if(synth.notNil, { synth.set(\scatter, params[\scatter]) });
            });
        });

        this.addCommand("bloom", "f", { arg msg;
            params[\bloom] = msg[1].asFloat;
            voices.do({ arg synth;
                if(synth.notNil, { synth.set(\bloom, params[\bloom]) });
            });
        });

        this.addCommand("drift", "f", { arg msg;
            params[\drift] = msg[1].asFloat;
            voices.do({ arg synth;
                if(synth.notNil, { synth.set(\drift, params[\drift]) });
            });
        });

        this.addCommand("position", "f", { arg msg;
            params[\position] = msg[1].asFloat;
            voices.do({ arg synth;
                if(synth.notNil, { synth.set(\position, params[\position]) });
            });
        });

        this.addCommand("feedback", "f", { arg msg;
            params[\feedback] = msg[1].asFloat;
            voices.do({ arg synth;
                if(synth.notNil, { synth.set(\feedback, params[\feedback]) });
            });
        });

        this.addCommand("dry_wet", "f", { arg msg;
            params[\dryWet] = msg[1].asFloat;
            voices.do({ arg synth;
                if(synth.notNil, { synth.set(\dryWet, params[\dryWet]) });
            });
        });

        this.addCommand("freeze", "f", { arg msg;
            params[\freeze] = msg[1].asFloat;
            voices.do({ arg synth;
                if(synth.notNil, { synth.set(\freeze, params[\freeze]) });
            });
        });

        this.addCommand("mode", "i", { arg msg;
            params[\mode] = msg[1].asInteger.clip(0, 2);
            voices.do({ arg synth;
                if(synth.notNil, { synth.set(\mode, params[\mode]) });
            });
        });

        this.addCommand("speed", "f", { arg msg;
            params[\speed] = msg[1].asFloat;
            voices.do({ arg synth;
                if(synth.notNil, { synth.set(\speed, params[\speed]) });
            });
        });

        this.addCommand("volume", "f", { arg msg;
            params[\amp] = msg[1].asFloat;
            voices.do({ arg synth, i;
                if(synth.notNil, {
                    synth.set(\amp, voiceVel[i] * params[\amp]);
                });
            });
        });

        this.addCommand("spread", "f", { arg msg;
            spreadVal = msg[1].asFloat;
            voices.do({ arg synth, i;
                if(synth.notNil, {
                    synth.set(\pan, (i - 3.5) / 3.5 * spreadVal);
                });
            });
        });

        this.addCommand("buf_load", "s", { arg msg;
            var path = msg[1].asString;
            voices.do({ arg synth, i;
                if(synth.notNil, { synth.set(\gate, 0); voices[i] = nil });
            });
            Buffer.read(context.server, path, action: { arg newBuf;
                buffer.free;
                buffer = newBuf;
                context.server.addr.sendMsg("/sediment/buf_info",
                    newBuf.numFrames, newBuf.sampleRate);
                this.sendWaveform();
            });
        });

        this.addCommand("rec_start", "", { arg msg;
            if(recSynth.notNil, { recSynth.free });
            recSynth = Synth(\sediment_rec, [\bufnum, buffer.bufnum], context.server);
        });

        this.addCommand("rec_stop", "", { arg msg;
            if(recSynth.notNil, {
                recSynth.set(\gate, 0);
                recSynth = nil;
                AppClock.sched(0.1, { this.sendWaveform(); nil });
            });
        });
    }

    sendWaveform {
        buffer.loadToFloatArray(action: { arg data;
            var numChans = buffer.numChannels;
            var monoFrames = data.size div: numChans;
            var segSize = (monoFrames / 128).asInteger.max(1);
            var waveData = Array.new(256);

            128.do({ arg i;
                var startIdx = i * segSize * numChans;
                var minVal = 1.0, maxVal = -1.0;

                segSize.do({ arg j;
                    var idx = startIdx + (j * numChans);
                    if(idx < data.size, {
                        var samp = data[idx];
                        if(samp < minVal, { minVal = samp });
                        if(samp > maxVal, { maxVal = samp });
                    });
                });

                waveData = waveData.add(minVal.linlin(-1, 1, 0, 126).asInteger.clip(0, 126));
                waveData = waveData.add(maxVal.linlin(-1, 1, 0, 126).asInteger.clip(0, 126));
            });

            context.server.addr.sendMsg("/sediment/waveform", *waveData);
        });
    }

    free {
        voices.do({ arg synth; if(synth.notNil, { synth.free }) });
        if(recSynth.notNil, { recSynth.free });
        buffer.free;
    }
}
```

- [ ] **Step 2: Verify syntactic completeness**

```
Verification:
1. Check that both SynthDefs are defined (\sediment_voice, \sediment_rec)
2. Count commands: note_on, note_off, voice_pos, scatter, bloom, drift, position,
   feedback, dry_wet, freeze, mode, speed, volume, spread, buf_load, rec_start,
   rec_stop = 17 commands
3. Confirm sendWaveform method exists with /sediment/waveform OSC path
4. Confirm buf_load sends /sediment/buf_info OSC with numFrames and sampleRate
5. Confirm free method releases voices, recSynth, buffer
Expected: all elements present, no syntax errors in SC structure
```

- [ ] **Step 3: Commit**

```bash
git add lib/Engine_Sediment.sc
git commit -m "feat: add Engine_Sediment with buffer-fed Sediment SynthDef, 8 voice slots, MIDI commands, auto-spread"
```

---

### Task 2: Main Script and Waveform Update

**Files:**
- Modify: `lib/waveform.lua`
- Create: `sediment.lua`

**Interfaces:**
- Consumes: `Engine_Sediment` commands (`note_on`, `note_off`, `voice_pos`, `scatter`, `bloom`, `drift`, `position`, `feedback`, `dry_wet`, `freeze`, `mode`, `speed`, `volume`, `spread`, `buf_load`, `rec_start`, `rec_stop`), OSC paths (`/sediment/waveform` 256 ints, `/sediment/buf_info` frames+sampleRate), `Waveform` module (`new`, `set_samples`, `set_head_pos`, `set_head_active`, `draw`, `clear`), norns APIs (`grid`, `midi`, `metro`, `params`, `screen`, `osc`, `audio`, `util`, `controlspec`)
- Produces: Complete norns script (final deliverable)

- [ ] **Step 1: Update waveform.lua for configurable head count**

Change the constructor to accept an optional `num_heads` parameter (default 7 for backward compatibility). Replace all hardcoded `7` references in loops with `self.num_heads`.

In `Waveform.new`:
```lua
function Waveform.new(x, y, w, h, num_heads)
  local wf = setmetatable({}, Waveform)
  wf.x = x
  wf.y = y
  wf.w = w
  wf.h = h
  wf.num_heads = num_heads or 7
  wf.samples = {}
  wf.head_pos = {}
  wf.head_active = {}
  for i = 1, wf.num_heads do
    wf.head_pos[i] = -1
    wf.head_active[i] = false
  end
  return wf
end
```

In `set_head_pos` and `set_head_active`, replace `7` with `self.num_heads`:
```lua
function Waveform:set_head_pos(head, pos)
  if head >= 1 and head <= self.num_heads then
    self.head_pos[head] = pos
  end
end

function Waveform:set_head_active(head, active)
  if head >= 1 and head <= self.num_heads then
    self.head_active[head] = active
  end
end
```

In `clear`, replace `7` with `self.num_heads`:
```lua
function Waveform:clear()
  self.samples = {}
  for i = 1, self.num_heads do
    self.head_pos[i] = -1
    self.head_active[i] = false
  end
end
```

In `draw`, replace `7` with `self.num_heads`:
```lua
  for i = 1, self.num_heads do
    local pos = self.head_pos[i]
    if self.head_active[i] and pos >= 0 and pos <= 1 then
      ...
    end
  end
```

- [ ] **Step 2: Verify waveform.lua syntax**

Run: `luac -p lib/waveform.lua`
Expected: no errors

- [ ] **Step 3: Write sediment.lua**

```lua
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
```

- [ ] **Step 4: Verify syntax of both Lua files**

Run: `luac -p sediment.lua && luac -p lib/waveform.lua`
Expected: no errors from either file

- [ ] **Step 5: Verify waveform backward compatibility**

```
Verification:
1. Read graindr.lua and confirm it calls Waveform.new(0, 10, 128, 38) with 4 args
2. Confirm waveform.lua defaults num_heads to 7 when 5th arg omitted
3. Confirm set_head_pos and set_head_active validate against self.num_heads
Expected: graindr.lua unchanged, waveform.lua backward compatible
```

- [ ] **Step 6: Verify sediment.lua completeness against spec**

```
Verification:
1. engine.name = "Sediment" matches Engine_Sediment class name
2. MIDI: note_on allocates slot, maps pitch = note - root_note, amp = vel/127
3. MIDI: note_off finds slot by note, releases
4. MIDI: voice stealing when all 8 occupied (oldest by time)
5. Grid: row press repositions active voice, pos = (x-1)/15
6. Grid: inactive rows ignored
7. Grid LED: interpolated two-LED indicator per active voice
8. Position tracking: pos += (dt / buf_duration) * speed, wraps at 0/1
9. Screen: header "SEDIMENT" + mode name + REC indicator
10. Screen: waveform with 8 playhead indicators
11. Screen: footer with sample name + duration
12. E1 = mode, E2 = scatter, E3 = bloom
13. K2 = panic, K3 = recording toggle
14. Params: mode, scatter, bloom, drift, position, feedback, dry_wet, freeze, speed
15. Params: volume, spread
16. Params: sample file picker
17. Params: midi_channel (all/1-16), root_note (0-127, default 60)
18. Params: monitor
19. OSC: /sediment/waveform and /sediment/buf_info handled
20. cleanup() releases all voices and stops recording
Expected: all 20 items present
```

- [ ] **Step 7: Commit**

```bash
git add lib/waveform.lua sediment.lua
git commit -m "feat: add sediment instrument with MIDI polyphony, grid position control, waveform display"
```

---

## Self-Review Checklist

**Spec coverage:**
- [x] Engine_Sediment.sc with \sediment_voice SynthDef (Task 1 Step 1)
- [x] BufRd→Sediment chain with Phasor and t_jump reposition (Task 1 Step 1)
- [x] \sediment_rec SynthDef for recording (Task 1 Step 1)
- [x] 8 voice slots with per-voice velocity tracking (Task 1 Step 1)
- [x] All 17 engine commands (Task 1 Step 1)
- [x] Auto-spread pan calculation (Task 1 Step 1: note_on + spread command)
- [x] Volume × velocity multiplication (Task 1 Step 1: note_on + volume command)
- [x] Waveform OSC /sediment/waveform (Task 1 Step 1)
- [x] Buffer info OSC /sediment/buf_info (Task 1 Step 1)
- [x] sendWaveform handles mono and stereo buffers (Task 1 Step 1)
- [x] free method (Task 1 Step 1)
- [x] waveform.lua configurable num_heads, default 7 (Task 2 Step 1)
- [x] Backward compatibility with graindr (Task 2 Step 5)
- [x] MIDI voice allocation: first-free + steal-oldest (Task 2 Step 3)
- [x] MIDI pitch mapping: note - root_note (Task 2 Step 3)
- [x] MIDI channel filter (Task 2 Step 3)
- [x] Grid rows 1-8 = voice slots 0-7 (Task 2 Step 3)
- [x] Grid press repositions active voice only (Task 2 Step 3)
- [x] Grid LED interpolated two-LED indicator (Task 2 Step 3)
- [x] Lua-side position tracking at 30fps with wrap (Task 2 Step 3)
- [x] Screen: header + waveform + footer (Task 2 Step 3)
- [x] E1 mode, E2 scatter, E3 bloom (Task 2 Step 3)
- [x] K2 panic, K3 recording toggle (Task 2 Step 3)
- [x] All params with correct specs and actions (Task 2 Step 3)
- [x] Recording with 60s auto-stop (Task 2 Step 3)
- [x] cleanup() (Task 2 Step 3)
- [x] Single screen page, no grid_ui.lua dependency (Task 2 Step 3)

**Placeholder scan:** No TBD, TODO, or vague steps. All code is complete.

**Type consistency:**
- Voice slot indices: engine 0-7, grid rows 1-8, waveform heads 1-8. Conversion with `slot + 1` and `row - 1` consistent across Task 1 and Task 2.
- Engine command names match between SC `addCommand` strings and Lua `engine.*` calls.
- `params[\amp]` in SC matches `volume` command. `voiceVel[i] * params[\amp]` in both note_on and volume.
- `spreadVal` in SC matches `spread` command. Pan formula `(i - 3.5) / 3.5 * spreadVal` in both note_on and spread.
- OSC paths `/sediment/waveform` and `/sediment/buf_info` consistent between engine and Lua.
- `Waveform.new(0, 10, 128, 38, 8)` in sediment.lua uses the new 5-arg constructor from Task 2 Step 1.
- `self.num_heads` used consistently in all waveform.lua methods.
