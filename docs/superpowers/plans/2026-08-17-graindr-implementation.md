# graindr Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a monome norns granular instrument with 7 scanning playheads, 9 Sediment UGens, grid 128 performance interface, and latkes-style waveform display.

**Architecture:** A SuperCollider engine (`CroneEngine` subclass) wraps all 9 Sediment UGens as SynthDefs, manages a shared buffer, 7 playhead synth slots, and waveform OSC. The Lua side has three modules: waveform rendering, grid UI, and the main script that handles params, screen, encoder-driven UGen switching, and a 30fps playhead scanning metro.

**Tech Stack:** SuperCollider (engine), Lua (norns script), monome grid 128

**Spec:** `docs/superpowers/specs/2026-08-17-graindr-design.md`

## Global Constraints

- Sediment UGens must be pre-installed on norns at `~/.local/share/SuperCollider/Extensions/Sediment/`
- Grid 128 (16x8) required
- Screen: 128x64 pixels, 16 brightness levels
- Audio: 48kHz stereo
- Maximum buffer: 60 seconds (48000 * 60 frames, stereo)
- 7 playheads maximum
- All 9 UGens present; global UGen selection (all playheads share one type)
- RPi: one UGen type at a time, shared params
- norns has no automated test framework; verification is manual via maiden REPL and on-device interaction

## File Map

| File | Responsibility |
|------|---------------|
| `graindr.lua` | Main script: init, params, single screen page, enc/key, OSC handlers, playhead scanning metro |
| `lib/Engine_Graindr.sc` | SuperCollider engine: 9 SynthDefs, buffer, playhead management, commands, waveform OSC, recording |
| `lib/waveform.lua` | Waveform data storage, screen rendering, playhead position indicators |
| `lib/grid_ui.lua` | Grid key routing, LED feedback, mute state, pattern recorder |

---

### Task 1: SuperCollider Engine

**Files:**
- Create: `lib/Engine_Graindr.sc`

**Interfaces:**
- Consumes: nothing (foundation layer)
- Produces: CroneEngine subclass `Engine_Graindr` with commands: `ugen_select(i)`, `head_start(i, f)`, `head_stop(i)`, `head_position(i, f)`, `head_volume(i, f)`, `head_pan(i, f)`, `buf_load(s)`, `rec_start()`, `rec_stop()`, plus one command per UGen parameter (e.g. `silt_density(f)`, `sed_bloom(f)`, etc). Sends OSC message `"/graindr/waveform"` (256 ints: 128 min/max pairs).

- [ ] **Step 1: Create engine file with class skeleton, buffer, and SynthDefs**

Create `lib/Engine_Graindr.sc` with the full engine. This is a single file containing the CroneEngine subclass with all SynthDefs defined in `alloc`, all commands, the `sendWaveform` method, and the `free` method. The grid-mapped param for each UGen is stored in a lookup so `head_position` knows which synth arg to set.

```supercollider
Engine_Graindr : CroneEngine {
    var buffer;
    var <heads;          // Array of 7 synth slots (nil when inactive)
    var <headParams;     // Array of 7 Dictionaries: amp, pan
    var <ugenMode;       // 0-8 index
    var <recSynth;
    var ugenNames;
    var ugenCategories;
    var gridMappedParam; // which synth arg head_position sets, per UGen mode
    var gridParamRanges; // [min, max] for the grid-mapped param per UGen mode
    var params;          // Dictionary of all UGen param current values

    *new { arg context, doneCallback;
        ^super.new(context, doneCallback);
    }

    alloc {
        ugenNames = [
            \graindr_silt, \graindr_clast, \graindr_sediment,
            \graindr_talus, \graindr_scree, \graindr_loess,
            \graindr_creep, \graindr_moraine, \graindr_tuff
        ];
        ugenCategories = [
            \buffer, \buffer, \live, \live, \live, \live, \live, \live, \synth
        ];
        gridMappedParam = [
            \position, \position, \position,
            \delay, \sliceDur, \timeSpread,
            \step, \amount, \fund
        ];
        gridParamRanges = [
            [0, 1], [0, 1], [0, 1],
            [0.01, 2.0], [0.01, 1.0], [0, 1],
            [0, 1], [0, 1], [20, 2000]
        ];

        ugenMode = 0;
        heads = Array.fill(7, { nil });
        headParams = Array.fill(7, { Dictionary[\amp -> 0.8, \pan -> 0] });

        buffer = Buffer.alloc(context.server, 48000 * 60, 2);

        params = Dictionary[
            \silt_density -> 20, \silt_dur -> 0.1,
            \silt_scatter -> 0.3, \silt_dist -> 0, \silt_distParam -> 0.5,
            \silt_pitch -> 0, \silt_shape -> 0.5,
            \clast_cycles -> 4, \clast_density -> 40,
            \clast_scan -> 0.0, \clast_pitch -> 0, \clast_spread -> 0.4,
            \clast_shape -> 0.5,
            \sed_pitch -> 0, \sed_scatter -> 0.5,
            \sed_bloom -> 0.3, \sed_drift -> 0.3, \sed_feedback -> 0,
            \sed_dryWet -> 0.5, \sed_freeze -> 0, \sed_mode -> 0,
            \talus_density -> 20, \talus_dur -> 0.2,
            \talus_pitch -> 0, \talus_feedback -> 0.3, \talus_spread -> 0.5,
            \scree_jump -> 0.3, \scree_repeats -> 2,
            \scree_pitch -> 0, \scree_scatter -> 0.3,
            \loess_density -> 300, \loess_grainDur -> 0.006,
            \loess_pitch -> 0, \loess_pitchSpread -> 0.5,
            \creep_ambitus -> 1, \creep_grainDur -> 0.12,
            \creep_overlap -> 0.5, \creep_pitch -> 0, \creep_pause -> 0.0,
            \creep_spread -> 0.5,
            \moraine_mode -> 0, \moraine_gate -> 0.05, \moraine_minHole -> 0.02,
            \moraine_pitch -> 0,
            \tuff_form -> 700, \tuff_attack -> 0.003,
            \tuff_decay -> 0.02, \tuff_dur -> 0.05, \tuff_band -> 60,
            \tuff_oct -> 0, \tuff_spread -> 0.0
        ];

        // ── SynthDefs ──

        SynthDef(\graindr_silt, { arg out=0, bufnum, gate=1,
            density=20, dur=0.1, position=0.5, scatter=0.3,
            dist=0, distParam=0.5, pitch=0, shape=0.5,
            amp=1, pan=0;
            var sig = Silt.ar(bufnum, density, dur, position, scatter,
                              dist, distParam, pitch, shape);
            var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
            Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
        }).add;

        SynthDef(\graindr_clast, { arg out=0, bufnum, gate=1,
            cycles=4, density=40, position=0.5, scan=0.0,
            pitch=0, spread=0.4, shape=0.5,
            amp=1, pan=0;
            var sig = Clast.ar(bufnum, cycles, density, position, scan,
                               pitch, spread, shape);
            var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
            Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
        }).add;

        SynthDef(\graindr_sediment, { arg out=0, gate=1,
            pitch=0, position=0.5, scatter=0.5, bloom=0.3,
            drift=0.3, feedback=0, dryWet=0.5, freeze=0,
            mode=0, trigger=0,
            amp=1, pan=0;
            var inL = SoundIn.ar(0), inR = SoundIn.ar(1);
            var sig = Sediment.ar(inL, inR, pitch, position, scatter,
                                  bloom, drift, feedback, dryWet, freeze, mode, trigger);
            var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
            Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
        }).add;

        SynthDef(\graindr_talus, { arg out=0, gate=1,
            delay=0.25, density=20, dur=0.2, pitch=0,
            feedback=0.3, spread=0.5,
            amp=1, pan=0;
            var in = SoundIn.ar(0);
            var sig = Talus.ar(in, 2, delay, density, dur, pitch, feedback, spread);
            var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
            Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
        }).add;

        SynthDef(\graindr_scree, { arg out=0, gate=1,
            sliceDur=0.1, jump=0.3, repeats=2, pitch=0, scatter=0.3,
            amp=1, pan=0;
            var in = SoundIn.ar(0);
            var sig = Scree.ar(in, 2, sliceDur, jump, repeats, pitch, scatter);
            var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
            Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
        }).add;

        SynthDef(\graindr_loess, { arg out=0, gate=1,
            density=300, grainDur=0.006, timeSpread=0.5,
            pitch=0, pitchSpread=0.5,
            amp=1, pan=0;
            var in = SoundIn.ar(0);
            var sig = Loess.ar(in, density, grainDur, timeSpread, pitch, pitchSpread);
            var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
            Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
        }).add;

        SynthDef(\graindr_creep, { arg out=0, gate=1,
            ambitus=1, step=0.2, grainDur=0.12, overlap=0.5,
            pitch=0, pause=0.0, spread=0.5,
            amp=1, pan=0;
            var in = SoundIn.ar(0);
            var sig = Creep.ar(in, 2, ambitus, step, grainDur, overlap,
                               pitch, pause, spread);
            var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
            Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
        }).add;

        SynthDef(\graindr_moraine, { arg out=0, gate=1,
            mode=0, gateThresh=0.05, minHole=0.02, amount=0.5, pitch=0,
            amp=1, pan=0;
            var in = SoundIn.ar(0);
            var sig = Moraine.ar(in, 4, mode, gateThresh, minHole, amount, pitch);
            var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
            Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
        }).add;

        SynthDef(\graindr_tuff, { arg out=0, gate=1,
            fund=100, form=700, attack=0.003, decay=0.02,
            dur=0.05, band=60, oct=0, spread=0.0,
            amp=1, pan=0;
            var sig = Tuff.ar(fund, form, attack, decay, dur, band, oct, spread);
            var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
            Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
        }).add;

        SynthDef(\graindr_rec, { arg bufnum, gate=1;
            var in = SoundIn.ar([0, 1]);
            var env = EnvGen.kr(Env.asr(0, 1, 0.01), gate, doneAction: 2);
            RecordBuf.ar(in * env, bufnum, loop: 0);
        }).add;

        // ── Commands ── (next step)
    }

    free {
        heads.do({ arg synth; if(synth.notNil, { synth.free }) });
        if(recSynth.notNil, { recSynth.free });
        buffer.free;
    }
}
```

- [ ] **Step 2: Add all engine commands inside alloc**

Add the playhead, buffer, recording, UGen select, and per-param commands. The `head_start` command builds the synth arg list based on current UGen mode and params. `head_position` maps the 0-1 grid value through the UGen's range and sets the grid-mapped param on the synth.

```supercollider
        // ── buildArgs helper ──
        var buildArgs = { arg headIdx, position;
            var argList = [\out, 0, \amp, headParams[headIdx][\amp],
                           \pan, headParams[headIdx][\pan]];
            var cat = ugenCategories[ugenMode];
            var mappedParam = gridMappedParam[ugenMode];
            var range = gridParamRanges[ugenMode];
            var mappedVal;

            if(cat == \buffer, {
                argList = argList ++ [\bufnum, buffer.bufnum];
            });

            // Map position 0-1 to the UGen's param range
            if(ugenMode == 8, {
                // Tuff: exponential mapping for frequency
                mappedVal = position.linexp(0, 1, range[0], range[1]);
            }, {
                mappedVal = position.linlin(0, 1, range[0], range[1]);
            });
            argList = argList ++ [mappedParam, mappedVal];

            // Add all current params for this UGen mode
            switch(ugenMode,
                0, {
                    argList = argList ++ [
                        \density, params[\silt_density], \dur, params[\silt_dur],
                        \scatter, params[\silt_scatter], \dist, params[\silt_dist],
                        \distParam, params[\silt_distParam],
                        \pitch, params[\silt_pitch], \shape, params[\silt_shape]
                    ];
                },
                1, {
                    argList = argList ++ [
                        \cycles, params[\clast_cycles], \density, params[\clast_density],
                        \scan, params[\clast_scan],
                        \pitch, params[\clast_pitch], \spread, params[\clast_spread],
                        \shape, params[\clast_shape]
                    ];
                },
                2, {
                    argList = argList ++ [
                        \pitch, params[\sed_pitch],
                        \scatter, params[\sed_scatter], \bloom, params[\sed_bloom],
                        \drift, params[\sed_drift], \feedback, params[\sed_feedback],
                        \dryWet, params[\sed_dryWet], \freeze, params[\sed_freeze],
                        \mode, params[\sed_mode], \trigger, 1
                    ];
                },
                3, {
                    argList = argList ++ [
                        \density, params[\talus_density], \dur, params[\talus_dur],
                        \pitch, params[\talus_pitch],
                        \feedback, params[\talus_feedback], \spread, params[\talus_spread]
                    ];
                },
                4, {
                    argList = argList ++ [
                        \jump, params[\scree_jump], \repeats, params[\scree_repeats],
                        \pitch, params[\scree_pitch], \scatter, params[\scree_scatter]
                    ];
                },
                5, {
                    argList = argList ++ [
                        \density, params[\loess_density],
                        \grainDur, params[\loess_grainDur],
                        \pitch, params[\loess_pitch],
                        \pitchSpread, params[\loess_pitchSpread]
                    ];
                },
                6, {
                    argList = argList ++ [
                        \ambitus, params[\creep_ambitus],
                        \grainDur, params[\creep_grainDur],
                        \overlap, params[\creep_overlap],
                        \pitch, params[\creep_pitch], \pause, params[\creep_pause],
                        \spread, params[\creep_spread]
                    ];
                },
                7, {
                    argList = argList ++ [
                        \mode, params[\moraine_mode],
                        \gateThresh, params[\moraine_gate],
                        \minHole, params[\moraine_minHole],
                        \pitch, params[\moraine_pitch]
                    ];
                },
                8, {
                    argList = argList ++ [
                        \form, params[\tuff_form], \attack, params[\tuff_attack],
                        \decay, params[\tuff_decay], \dur, params[\tuff_dur],
                        \band, params[\tuff_band], \oct, params[\tuff_oct],
                        \spread, params[\tuff_spread]
                    ];
                }
            );
            argList;
        };

        this.addCommand("ugen_select", "i", { arg msg;
            var newMode = msg[1].asInteger.clip(0, 8);
            heads.do({ arg synth, i;
                if(synth.notNil, {
                    synth.set(\gate, 0);
                    heads[i] = nil;
                });
            });
            ugenMode = newMode;
        });

        this.addCommand("head_start", "if", { arg msg;
            var idx = msg[1].asInteger.clip(0, 6);
            var position = msg[2].asFloat.clip(0, 1);
            var name = ugenNames[ugenMode];
            var args;

            if(heads[idx].notNil, {
                heads[idx].set(\gate, 0);
            });

            args = buildArgs.value(idx, position);
            heads[idx] = Synth(name, args, context.server);
        });

        this.addCommand("head_stop", "i", { arg msg;
            var idx = msg[1].asInteger.clip(0, 6);
            if(heads[idx].notNil, {
                heads[idx].set(\gate, 0);
                heads[idx] = nil;
            });
        });

        this.addCommand("head_position", "if", { arg msg;
            var idx = msg[1].asInteger.clip(0, 6);
            var position = msg[2].asFloat.clip(0, 1);
            var mappedParam = gridMappedParam[ugenMode];
            var range = gridParamRanges[ugenMode];
            var mappedVal;

            if(heads[idx].notNil, {
                if(ugenMode == 8, {
                    mappedVal = position.linexp(0, 1, range[0], range[1]);
                }, {
                    mappedVal = position.linlin(0, 1, range[0], range[1]);
                });
                heads[idx].set(mappedParam, mappedVal);
            });
        });

        this.addCommand("head_volume", "if", { arg msg;
            var idx = msg[1].asInteger.clip(0, 6);
            var val = msg[2].asFloat;
            headParams[idx][\amp] = val;
            if(heads[idx].notNil, { heads[idx].set(\amp, val) });
        });

        this.addCommand("head_pan", "if", { arg msg;
            var idx = msg[1].asInteger.clip(0, 6);
            var val = msg[2].asFloat;
            headParams[idx][\pan] = val;
            if(heads[idx].notNil, { heads[idx].set(\pan, val) });
        });

        this.addCommand("buf_load", "s", { arg msg;
            var path = msg[1].asString;
            heads.do({ arg synth, i;
                if(synth.notNil, { synth.set(\gate, 0); heads[i] = nil });
            });
            Buffer.read(context.server, path, action: { arg newBuf;
                buffer.free;
                buffer = newBuf;
                this.sendWaveform();
            });
        });

        this.addCommand("rec_start", "", { arg msg;
            if(recSynth.notNil, { recSynth.free });
            recSynth = Synth(\graindr_rec, [\bufnum, buffer.bufnum], context.server);
        });

        this.addCommand("rec_stop", "", { arg msg;
            if(recSynth.notNil, {
                recSynth.set(\gate, 0);
                recSynth = nil;
                AppClock.sched(0.1, { this.sendWaveform(); nil });
            });
        });

        // Per-UGen param commands
        params.keysDo({ arg key;
            this.addCommand(key.asString, "f", { arg msg;
                var val = msg[1].asFloat;
                var synthArg;
                params[key] = val;
                synthArg = key.asString;
                synthArg = synthArg[(synthArg.indexOf($_) + 1)..].asSymbol;
                heads.do({ arg synth;
                    if(synth.notNil, { synth.set(synthArg, val) });
                });
            });
        });
```

- [ ] **Step 3: Add sendWaveform method after alloc**

```supercollider
    sendWaveform {
        buffer.loadToFloatArray(action: { arg data;
            var numFrames = data.size div: 2;
            var segSize = (numFrames / 128).asInteger.max(1);
            var waveData = Array.new(256);

            128.do({ arg i;
                var startIdx = i * segSize * 2;
                var minVal = 1.0, maxVal = -1.0;

                segSize.do({ arg j;
                    var idx = startIdx + (j * 2);
                    if(idx < data.size, {
                        var samp = (data[idx] + data[idx + 1]) * 0.5;
                        if(samp < minVal, { minVal = samp });
                        if(samp > maxVal, { maxVal = samp });
                    });
                });

                waveData = waveData.add(minVal.linlin(-1, 1, 0, 126).asInteger.clip(0, 126));
                waveData = waveData.add(maxVal.linlin(-1, 1, 0, 126).asInteger.clip(0, 126));
            });

            context.server.addr.sendMsg("/graindr/waveform", *waveData);
        });
    }
```

- [ ] **Step 4: Verify engine compiles**

```
Verification: Copy lib/Engine_Graindr.sc to norns SC extensions and restart SC.
Check maiden/SC post window for compile errors.
Expected: no errors (Sediment UGens must be installed)
```

- [ ] **Step 5: Commit**

```bash
git add lib/Engine_Graindr.sc
git commit -m "feat: add SuperCollider engine with 9 Sediment SynthDefs, playhead management, scanning position, buffer/recording, waveform OSC"
```

---

### Task 2: Waveform Display Module

**Files:**
- Create: `lib/waveform.lua`

**Interfaces:**
- Consumes: nothing (standalone module)
- Produces: `Waveform.new(x, y, w, h)`, `Waveform:set_samples(data)`, `Waveform:set_head_pos(head, pos)`, `Waveform:draw()`, `Waveform:clear()`

- [ ] **Step 1: Create waveform module**

```lua
-- lib/waveform.lua

local Waveform = {}
Waveform.__index = Waveform

function Waveform.new(x, y, w, h)
  local wf = setmetatable({}, Waveform)
  wf.x = x
  wf.y = y
  wf.w = w
  wf.h = h
  wf.samples = {}
  wf.head_pos = {}
  wf.head_active = {}
  for i = 1, 7 do
    wf.head_pos[i] = -1
    wf.head_active[i] = false
  end
  return wf
end

function Waveform:set_samples(data)
  self.samples = {}
  for i = 1, 128 do
    local min_val = util.linlin(0, 126, -1, 1, data[(i - 1) * 2 + 1] or 63)
    local max_val = util.linlin(0, 126, -1, 1, data[(i - 1) * 2 + 2] or 63)
    self.samples[i] = { min_val, max_val }
  end
end

function Waveform:set_head_pos(head, pos)
  if head >= 1 and head <= 7 then
    self.head_pos[head] = pos
  end
end

function Waveform:set_head_active(head, active)
  if head >= 1 and head <= 7 then
    self.head_active[head] = active
  end
end

function Waveform:clear()
  self.samples = {}
  for i = 1, 7 do
    self.head_pos[i] = -1
    self.head_active[i] = false
  end
end

function Waveform:draw()
  local center_y = self.y + self.h / 2
  local half_h = self.h / 2

  if #self.samples > 0 then
    screen.level(6)
    for i = 1, math.min(#self.samples, self.w) do
      local s = self.samples[i]
      local px = self.x + i - 1
      local y_top = center_y - s[2] * half_h
      local y_bot = center_y - s[1] * half_h
      screen.move(px, y_top)
      screen.line(px, y_bot)
      screen.stroke()
    end
  else
    screen.level(2)
    screen.move(self.x, center_y)
    screen.line(self.x + self.w, center_y)
    screen.stroke()
  end

  for i = 1, 7 do
    local pos = self.head_pos[i]
    if self.head_active[i] and pos >= 0 and pos <= 1 then
      local px = self.x + math.floor(pos * (self.w - 1))
      screen.level(15)
      screen.move(px, self.y)
      screen.line(px, self.y + self.h)
      screen.stroke()
      screen.move(px - 1, self.y + self.h + 6)
      screen.level(10)
      screen.text(tostring(i))
    end
  end
end

return Waveform
```

- [ ] **Step 2: Commit**

```bash
git add lib/waveform.lua
git commit -m "feat: add waveform display module with playhead position indicators"
```

---

### Task 3: Grid UI Module

**Files:**
- Create: `lib/grid_ui.lua`

**Interfaces:**
- Consumes: nothing (standalone; callbacks injected by main script)
- Produces: `GridUI.new()`, `GridUI:key(x, y, z)`, `GridUI:refresh(g)`, `GridUI:set_head_pos(head, pos)`, `GridUI:set_head_active(head, active)`, `GridUI:is_muted(head)`. Callbacks: `on_head_start(head, position)`, `on_head_reposition(head, position)`, `on_head_stop(head)`, `on_mute_toggle(head, state)`.

- [ ] **Step 1: Create grid UI with toggle-and-reposition key handling**

First press on an inactive row starts the playhead. Subsequent presses reposition it. Row 1 handles mute and pattern controls.

```lua
-- lib/grid_ui.lua

local GridUI = {}
GridUI.__index = GridUI

function GridUI.new()
  local gui = setmetatable({}, GridUI)
  gui.mutes = {}
  gui.head_active = {}
  gui.head_pos = {}
  gui.alt_held = false

  gui.patterns = {}
  for i = 1, 7 do
    gui.mutes[i] = false
    gui.head_active[i] = false
    gui.head_pos[i] = -1
    gui.patterns[i] = {
      armed = false,
      playing = false,
      events = {},
      metro = nil,
      rec_start = 0,
      play_idx = 0,
      length = 0
    }
  end

  gui.on_head_start = function(head, position) end
  gui.on_head_reposition = function(head, position) end
  gui.on_head_stop = function(head) end
  gui.on_mute_toggle = function(head, state) end

  return gui
end

function GridUI:key(x, y, z)
  if y == 1 then
    self:handle_control_row(x, z)
  elseif y >= 2 and y <= 8 and z == 1 then
    local head = y - 1
    if not self.mutes[head] then
      local position = (x - 1) / 15

      if self.head_active[head] then
        self.on_head_reposition(head, position)
      else
        self.head_active[head] = true
        self.on_head_start(head, position)
      end

      self.head_pos[head] = position

      if self.patterns[head].armed then
        local t = util.time() - self.patterns[head].rec_start
        table.insert(self.patterns[head].events, { t = t, x = x })
      end
    end
  end
end

function GridUI:handle_control_row(x, z)
  if z == 0 then
    if x == 16 then self.alt_held = false end
    return
  end

  if x == 16 then
    self.alt_held = true
    return
  end

  if x >= 1 and x <= 7 then
    local head = x
    self.mutes[head] = not self.mutes[head]
    self.on_mute_toggle(head, self.mutes[head])
    if self.mutes[head] then
      self.head_active[head] = false
      self.on_head_stop(head)
    end
    return
  end

  if x >= 9 and x <= 15 then
    local head = x - 8
    local pat = self.patterns[head]

    if self.alt_held then
      self:pattern_stop(head)
      pat.events = {}
      pat.length = 0
      return
    end

    if pat.armed then
      pat.armed = false
      pat.length = util.time() - pat.rec_start
      if #pat.events > 0 then
        self:pattern_play(head)
      end
    elseif pat.playing then
      self:pattern_stop(head)
    elseif #pat.events > 0 then
      self:pattern_play(head)
    else
      pat.armed = true
      pat.events = {}
      pat.rec_start = util.time()
    end
  end
end

return GridUI
```

- [ ] **Step 2: Add pattern playback and LED refresh**

```lua
function GridUI:pattern_play(head)
  local pat = self.patterns[head]
  if #pat.events == 0 then return end

  pat.playing = true
  pat.play_idx = 1

  if pat.metro then
    metro.free(pat.metro.id)
  end

  pat.metro = metro.init()
  pat.metro.time = math.max(pat.events[1].t, 0.001)
  pat.metro.event = function()
    if not pat.playing then return end
    local evt = pat.events[pat.play_idx]
    if evt and not self.mutes[head] then
      local position = (evt.x - 1) / 15
      if self.head_active[head] then
        self.on_head_reposition(head, position)
      else
        self.head_active[head] = true
        self.on_head_start(head, position)
      end
      self.head_pos[head] = position
    end

    pat.play_idx = pat.play_idx + 1
    if pat.play_idx > #pat.events then
      local remaining = pat.length - pat.events[#pat.events].t
      pat.metro.time = math.max(remaining, 0.01)
      pat.play_idx = 1
    else
      local next_t = pat.events[pat.play_idx].t - pat.events[pat.play_idx - 1].t
      pat.metro.time = math.max(next_t, 0.001)
    end
  end
  pat.metro:start()
end

function GridUI:pattern_stop(head)
  local pat = self.patterns[head]
  pat.playing = false
  pat.armed = false
  if pat.metro then pat.metro:stop() end
end

function GridUI:set_head_pos(head, pos)
  if head >= 1 and head <= 7 then
    self.head_pos[head] = pos
  end
end

function GridUI:set_head_active(head, active)
  if head >= 1 and head <= 7 then
    self.head_active[head] = active
  end
end

function GridUI:is_muted(head)
  return self.mutes[head] or false
end

function GridUI:stop_all()
  for i = 1, 7 do
    self.head_active[i] = false
    self:pattern_stop(i)
  end
end

function GridUI:refresh(g)
  if g == nil then return end

  g:all(0)

  for i = 1, 7 do
    g:led(i, 1, self.mutes[i] and 4 or 15)
  end

  for i = 1, 7 do
    local pat = self.patterns[i]
    local level = 0
    if pat.armed then
      level = (math.floor(util.time() * 4) % 2 == 0) and 12 or 0
    elseif pat.playing then
      level = 15
    elseif #pat.events > 0 then
      level = 4
    end
    g:led(i + 8, 1, level)
  end

  g:led(16, 1, self.alt_held and 15 or 2)

  for head = 1, 7 do
    local pos = self.head_pos[head]
    if self.head_active[head] and not self.mutes[head] and pos >= 0 and pos <= 1 then
      local float_x = pos * 15 + 1
      local x_lo = math.floor(float_x)
      local x_hi = x_lo + 1
      local frac = float_x - x_lo
      local row = head + 1

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
```

- [ ] **Step 3: Commit**

```bash
git add lib/grid_ui.lua
git commit -m "feat: add grid UI module with toggle-and-reposition playheads, mute, pattern recorder, LED feedback"
```

---

### Task 4: Main Script and Integration

**Files:**
- Create: `graindr.lua`

**Interfaces:**
- Consumes: `Engine_Graindr` (commands), `Waveform` (lib/waveform.lua), `GridUI` (lib/grid_ui.lua)
- Produces: Complete norns script (final deliverable)

- [ ] **Step 1: Create main script with module setup, playhead state, and init**

```lua
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
```

- [ ] **Step 2: Write the playhead scanning function**

```lua
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
```

- [ ] **Step 3: Write build_params with all UGen params, playhead params, file/recording**

```lua
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
```

- [ ] **Step 4: Write screen redraw, enc, key, and helper functions**

```lua
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
```

- [ ] **Step 5: Verify the full script loads on norns**

```
Verification:
1. Copy graindr/ folder to norns ~/dust/code/graindr/
2. Ensure Sediment UGens are installed
3. In maiden, load graindr
4. Check REPL for errors
5. Screen should show "SILT" header with empty waveform
6. Grid row 1 should light up (mute LEDs bright, alt dim)
7. E1 should cycle UGen name on screen
Expected: script loads without errors, screen and grid responsive
```

- [ ] **Step 6: Verify playhead scanning and grid interaction**

```
Verification:
1. Load a .wav file via params menu (PARAMS > FILE > sample)
2. Verify waveform appears on screen
3. Press grid (8, 2) -- playhead 1 starts at center, vertical line appears on waveform
4. Watch the playhead line slowly scan forward across the waveform
5. Press grid (3, 2) -- playhead 1 repositions to column 3
6. Press grid (5, 3) -- playhead 2 starts at a different position
7. Grid rows 2 and 3 should show scanning LED indicators
8. Press grid (1, 1) to mute playhead 1 -- row 2 goes dark, audio stops
9. E1 to switch to Talus -- all playheads stop, screen shows "TALUS"
Expected: playheads scan, reposition on grid press, mute works, UGen switching clears all
```

- [ ] **Step 7: Verify recording**

```
Verification:
1. Connect audio input
2. Press K3 to start recording -- "REC" with timer on screen
3. Press K3 again to stop -- waveform updates
4. Start playheads from grid -- grains play from recorded buffer
Expected: recorded audio immediately playable
```

- [ ] **Step 8: Commit**

```bash
git add graindr.lua
git commit -m "feat: add main graindr script with encoder UGen switching, playhead scanning, single-page waveform UI, all params, recording"
```

---

## Self-Review Checklist

**Spec coverage:**
- [x] 9 Sediment UGens as SynthDefs (Task 1 Step 1)
- [x] Shared buffer, buffer load (Task 1 Steps 1-2)
- [x] 7 playhead slots with toggle-and-reposition (Task 1 Step 2, Task 3 Step 1)
- [x] UGen select frees all playheads (Task 1 Step 2)
- [x] head_position with per-UGen param mapping (Task 1 Step 2)
- [x] Per-playhead speed/direction scanning (Task 4 Step 2)
- [x] Per-UGen param commands (Task 1 Step 2)
- [x] Playhead volume/pan (Task 1 Step 2)
- [x] Waveform OSC (Task 1 Step 3)
- [x] Recording SynthDef and commands (Task 1 Steps 1-2)
- [x] Waveform display with playhead indicators (Task 2)
- [x] Grid row 1: mute, pattern, alt (Task 3 Step 1)
- [x] Grid rows 2-8: toggle-start, reposition (Task 3 Step 1)
- [x] Grid LED: mute status, pattern status, scanning playhead (Task 3 Step 2)
- [x] Pattern recorder (Task 3 Steps 1-2)
- [x] Single screen page: waveform + UGen name + recording indicator (Task 4 Step 4)
- [x] E1 cycles UGen (Task 4 Step 4)
- [x] E2 global speed (Task 4 Step 4)
- [x] K2 stop all, K3 toggle recording (Task 4 Step 4)
- [x] All params in norns params menu (Task 4 Step 3)
- [x] File selection via params menu file picker (Task 4 Step 3)
- [x] PSET support (standard norns params, automatic)
- [x] Cleanup function (Task 4 Step 4)
- [x] No fileselect.lua / no second screen page
- [x] Grid-mapped param removed from each UGen's param group

**Placeholder scan:** No TBD, TODO, or vague steps.

**Type consistency:**
- Playhead indexing: engine 0-6, Lua 1-7. Conversion at boundary via `i - 1`. Consistent.
- UGen indexing: engine 0-8, Lua option 1-9. Conversion via `x - 1`. Consistent.
- `head_active` tracked in three places: `graindr.lua`, `grid_ui.lua`, `waveform.lua`. The main script is the source of truth and pushes state to modules via `set_head_active`.
- All engine command names match between SC `addCommand` and Lua `engine.*` calls.
- `include()` used for norns script-local modules. Consistent.
