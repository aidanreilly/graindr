# sediment — Design Specification

A monome norns granular instrument built around the Sediment UGen, with MIDI polyphony, grid 128 spatial control, and waveform display.

## Overview

sediment is a focused granular instrument using a single Sediment UGen type. MIDI note-on/off triggers up to 8 polyphonic voices at chromatic pitches from a shared sample buffer. Grid 128 rows correspond to voice slots and control where each voice reads in the buffer. The norns screen shows a waveform with playhead position indicators.

Each voice is a BufRd → Sediment chain. BufRd continuously reads from the sample buffer at a controllable position and speed. Sediment captures that audio into its internal 2-second buffer and granularly processes it with three macro controls (scatter, bloom, drift) and three playback modes (granular, stretch, looping delay).

This is the first of a planned series of per-UGen instruments sharing the same project structure.

## Architecture

### Components

```
graindr/
  sediment.lua              -- main script: init, midi, screen, enc/key, position tracking
  lib/
    Engine_Sediment.sc       -- focused engine: buffer-fed Sediment SynthDef, 8 voices
    waveform.lua             -- waveform display (shared module, updated for configurable head count)
```

### Data Flow

```
MIDI note-on (channel, note, velocity)
  → sediment.lua: allocate voice slot (0-7), pitch = note - root
  → engine.note_on(slot, pitch, vel/127)
  → Engine_Sediment.sc: creates Synth(\sediment_voice) in that slot

Grid press (col, row)
  → sediment.lua: newPos = (col - 1) / 15
  → engine.voice_pos(row - 1, newPos)
  → Engine_Sediment.sc: synth.set(\bufPos, newPos, \t_jump, 1)

MIDI note-off (channel, note)
  → sediment.lua: find slot holding that note
  → engine.note_off(slot)
  → Engine_Sediment.sc: synth.set(\gate, 0), slot freed on envelope done

Position tracking (Lua metro at 30fps)
  → For each active voice: pos += (dt / bufDuration) * speed
  → waveform:set_head_pos(slot + 1, pos)
  → Grid LED refresh shows interpolated indicator per active voice

Encoder turn (E2 scatter, E3 bloom)
  → params:delta updates value
  → engine.scatter(val) or engine.bloom(val)
  → Engine_Sediment.sc: sets param on all active voice synths

Waveform feedback
  → Engine_Sediment.sc: sends OSC "/sediment/waveform" (128 min/max pairs, 256 ints)
  → sediment.lua: osc.event handler
  → waveform.lua: stores samples for display
```

## SuperCollider Engine

### Engine_Sediment.sc

Extends `CroneEngine`. Manages:

- 1 shared Buffer for file playback and recording (48000 * 60 frames, 1 channel)
- 1 recording SynthDef for capturing live input into the buffer
- 8 voice slots (synth nodes, nil when inactive)
- Global Sediment parameter state (applied to all active voices)
- Waveform analysis routine sending buffer data to Lua via OSC

#### SynthDef: \sediment_voice

```
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
})
```

- `bufPos` (0-1): position in the sample buffer where BufRd reads. Controlled by grid columns. Repositioning sends `t_jump=1` to trigger the Phasor reset.
- `speed` (0-2): BufRd read rate. 0 = frozen at position. 1 = normal playback. Values between 0 and 1 give slow scanning.
- `pitch` (-48 to 48): Sediment transposition in semitones. Set from MIDI note number relative to root.
- `position` (0-1): where in Sediment's internal 2-second buffer grains are sourced. Separate from bufPos. Controlled via params menu.
- `scatter` (0-1): grain rate, position jitter, window variation, stereo spread.
- `bloom` (0-1): grain size and FDN space amount together.
- `drift` (0-1): slow autonomous wander of position and pitch.
- `feedback` (0-1): recirculate wet output back into Sediment's internal recording.
- `dryWet` (0-1): dry/wet mix (equal power).
- `freeze` (0 or 1): stop Sediment's internal recording, loop captured content.
- `mode` (0-2): 0 granular, 1 stretch (WSOLA), 2 looping delay.
- `amp`, `pan`: per-voice amplitude and stereo position.
- `t_jump`: trigger argument for Phasor reset on reposition.

#### SynthDef: \sediment_rec

```
SynthDef(\sediment_rec, { arg bufnum, gate=1;
    var in = SoundIn.ar(0);
    var env = EnvGen.kr(Env.asr(0, 1, 0.01), gate, doneAction: 2);
    RecordBuf.ar(in * env, bufnum, loop: 0);
})
```

Records mono input into the shared buffer. Maximum 60 seconds (buffer size).

#### Engine Commands

| Command | Signature | Description |
|---------|-----------|-------------|
| `note_on` | `iff` | Start voice: slot (0-7), pitch (semitones), amplitude (0-1) |
| `note_off` | `i` | Release voice: slot (0-7), sets gate=0 |
| `voice_pos` | `if` | Reposition voice: slot (0-7), bufPos (0-1), triggers t_jump |
| `scatter` | `f` | Set scatter on all active voices |
| `bloom` | `f` | Set bloom on all active voices |
| `drift` | `f` | Set drift on all active voices |
| `position` | `f` | Set Sediment internal position on all active voices |
| `feedback` | `f` | Set feedback on all active voices |
| `dry_wet` | `f` | Set dryWet on all active voices |
| `freeze` | `f` | Set freeze on all active voices |
| `mode` | `i` | Set mode (0-2) on all active voices |
| `speed` | `f` | Set buffer read speed on all active voices |
| `volume` | `f` | Set master volume on all active voices |
| `spread` | `f` | Recalculate pan for all active voices based on spread |
| `buf_load` | `s` | Load sample file into buffer, sends waveform OSC |
| `rec_start` | `` | Start recording into buffer |
| `rec_stop` | `` | Stop recording, sends waveform OSC |

#### Waveform OSC

After buffer load or recording stop, the engine sends `/sediment/waveform` with 256 integer values (128 min/max pairs, each 0-126). Same format as Engine_Graindr.

## MIDI

### Voice Allocation

8 voice slots (0-7). Lua tracks allocation in a table:

```
voices[slot] = { note=<midi_note>, time=<allocation_time>, bufPos=<current_pos> }
```

- **Note-on:** find first free slot. If all 8 occupied, steal the oldest (lowest `time`). Send `engine.note_on(slot, note - root, vel / 127)`.
- **Note-off:** find slot holding the matching note. Send `engine.note_off(slot)`. Mark slot free.
- **Pitch mapping:** `pitch = midi_note - root_note` in semitones. Root note defaults to 60 (middle C). Configurable in params.
- **Channel:** configurable, default "all" (responds to any channel).

### Voice Spread

Auto-pan formula distributes voices across the stereo field:

```
pan = (slot - 3.5) / 3.5 * spread
```

Slot 0 pans left, slot 7 pans right. `spread=0` centers all voices. `spread=1` distributes fully. The engine calculates and sets pan for each active voice when spread changes.

## Grid 128

### Layout

All 8 rows map to voice slots. Row 1 = slot 0, row 8 = slot 7. No control row.

| Row | Function |
|-----|----------|
| 1-8 | Voice slot position control. Columns 1-16 map to buffer position 0-1. |

### Interaction

- **Press (z=1) on active voice row:** reposition that voice to `(col - 1) / 15`. Sends `engine.voice_pos(slot, pos)`. Resets Lua-side position tracker for that slot.
- **Press on inactive voice row:** no action (MIDI controls voice activation).
- **LED refresh (30fps):** active voices show interpolated two-LED position indicator at their current buffer read position. Same interpolation math as graindr: `float_x = pos * 15 + 1`, split brightness between floor and ceil columns. Inactive rows dark.

### Position Tracking

Lua calculates each active voice's current buffer position at 30fps:

```
pos = pos + (dt / buf_duration) * speed
if pos > 1 then pos = pos - 1 end
if pos < 0 then pos = pos + 1 end
```

Grid reposition resets the tracked position. Approximate but sufficient for display and LED feedback.

## Screen

Single page. 128x64 pixels.

### Layout

```
y=0-7:   Header line
y=10-48: Waveform with playhead indicators
y=56-63: Footer line
```

### Header (y=0-7)

- Left-aligned, level 15: "SEDIMENT"
- Center: mode name ("granular" / "stretch" / "delay")
- Right-aligned: recording indicator "REC M:SS" when active, level 15

### Waveform (y=10-48)

Rendered by `waveform.lua` with `Waveform.new(0, 10, 128, 38, 8)`. Shows:

- Vertical line segments for each of 128 buffer sample columns (level 6)
- Center line when no sample loaded (level 2)
- Up to 8 numbered playhead indicators: vertical line (level 15) with slot number below (level 10)

### Footer (y=56-63)

- Left-aligned, level 4: sample filename (truncated to 20 chars with "..." suffix)
- Right-aligned, level 4: sample duration "M:SS"

## Encoders and Keys

| Control | Function |
|---------|----------|
| E1 | Sediment mode cycle: granular (0) → stretch (1) → looping delay (2) |
| E2 | Scatter: delta adjustment, updates param and engine |
| E3 | Bloom: delta adjustment, updates param and engine |
| K2 | Panic: release all active voices, clear all slots |
| K3 | Toggle recording: start/stop recording into buffer |

## Params Menu

### SEDIMENT

| Param ID | Label | Spec | Default | Action |
|----------|-------|------|---------|--------|
| `mode` | mode | option: granular, stretch, looping delay | granular | `engine.mode(x - 1)` |
| `scatter` | scatter | 0-1 lin | 0.5 | `engine.scatter(x)` |
| `bloom` | bloom | 0-1 lin | 0.3 | `engine.bloom(x)` |
| `drift` | drift | 0-1 lin | 0.3 | `engine.drift(x)` |
| `position` | position | 0-1 lin | 0.5 | `engine.position(x)` |
| `feedback` | feedback | 0-1 lin | 0.0 | `engine.feedback(x)` |
| `dry_wet` | dry/wet | 0-1 lin | 0.5 | `engine.dry_wet(x)` |
| `freeze` | freeze | option: off, on | off | `engine.freeze(x - 1)` |
| `speed` | speed | 0-2 lin, step 0.01 | 1.0 | `engine.speed(x)` |

### VOICES

| Param ID | Label | Spec | Default | Action |
|----------|-------|------|---------|--------|
| `volume` | volume | 0-1 lin | 0.8 | `engine.volume(x)` |
| `spread` | spread | 0-1 lin | 0.5 | `engine.spread(x)` |

### FILE

| Param ID | Label | Spec | Default | Action |
|----------|-------|------|---------|--------|
| `sample` | sample | file: /home/we/dust/audio/ | "" | `load_sample(path)` |

### MIDI

| Param ID | Label | Spec | Default | Action |
|----------|-------|------|---------|--------|
| `midi_channel` | channel | option: all, 1-16 | all | update filter |
| `root_note` | root note | number: 0-127 | 60 | update pitch offset |

### INPUT

| Param ID | Label | Spec | Default | Action |
|----------|-------|------|---------|--------|
| `monitor` | monitor | option: off, on | off | `audio.level_monitor(x - 1)` |

## Module Changes

### waveform.lua

Add optional `num_heads` parameter to constructor for configurable playhead count:

```
function Waveform.new(x, y, w, h, num_heads)
  num_heads = num_heads or 7
  ...
  for i = 1, num_heads do
```

All internal loops use `self.num_heads` instead of hardcoded 7. Backward compatible with graindr (defaults to 7 when not specified).

## Buffer

- Mono, 48000 * 60 frames (60 seconds at 44.1kHz)
- Mono because BufRd reads channel 0 regardless. Loaded stereo files have their left channel read.
- Recording captures SoundIn channel 0 (mono).
- Buffer.read replaces the buffer on file load (frees old, uses new).

## Recording

- K3 toggles recording on/off.
- Recording timer displayed on screen header.
- Auto-stop at 60 seconds (buffer length).
- On stop: engine sends waveform OSC, waveform display updates.
- Recording into a live buffer while voices play is allowed (voices hear the new audio as it records).

## Cleanup

`cleanup()` releases all active voices (sends gate=0), stops recording if active, frees metros.

## Constraints

- Maximum 8 simultaneous voices (RPi resource limit).
- Sediment UGen must be pre-installed on norns (from the Sediment plugin package).
- Voice slot indices: engine 0-7, grid rows 1-8. Convert at boundary.
- MIDI note range: 0-127. Pitch range after root offset: -60 to +67 semitones (Sediment supports -48 to 48, values outside are clamped by the UGen).
- All Sediment params are global (affect all active voices equally). Per-voice differentiation comes from pitch (MIDI), position in buffer (grid), and pan (auto-spread).
