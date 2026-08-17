# graindr — Design Specification

A monome norns granular instrument using all 9 Sediment UGens, with a grid 128 performance interface and latkes-style waveform display.

## Overview

graindr provides 7 scanning granular playheads controlled from a grid 128. All playheads run the same UGen type, selected globally via a norns encoder. Each playhead is an independent grain stream that auto-scans through the buffer (or live input) at a configurable speed and direction. The norns screen shows a single waveform page with playhead position indicators. All parameter control, file loading, and recording happen through the norns params menu.

## Architecture

### Components

```
graindr/
  graindr.lua              -- main script: init, screen, encoders, keys, playhead scanning
  lib/
    Engine_Graindr.sc       -- SuperCollider engine (all 9 Sediment SynthDefs)
    waveform.lua            -- waveform data storage and rendering (adapted from latkes)
    grid_ui.lua             -- grid key handling, LED feedback, pattern recorder
```

### Data Flow

```
Grid key press (rows 2-8)
  → graindr.lua: g.key(x, y, z)
  → grid_ui.lua: toggle playhead on/off or reposition
  → engine.head_start(head, position) or engine.head_stop(head)
  → Engine_Graindr.sc: creates/frees synth node for that playhead

Playhead scanning (Lua metro at ~30fps)
  → graindr.lua: updates each active playhead position by speed * direction
  → engine.head_position(head, new_position)
  → Engine_Graindr.sc: sets position-mapped param on synth node

Encoder (E1)
  → graindr.lua: cycles through 9 UGens
  → engine.ugen_select(index)
  → Engine_Graindr.sc: frees all playhead synths, updates mode

Norns params menu
  → params:set_action callback
  → engine.<param_name>(value)
  → Engine_Graindr.sc: updates param on all active playhead synths

Waveform feedback
  → Engine_Graindr.sc: sends OSC "/graindr/waveform" (128-point min/max)
  → graindr.lua: osc.event handler
  → waveform.lua: stores samples, triggers redraw
```

## SuperCollider Engine

### Engine_Graindr.sc

Extends `CroneEngine`. Manages:

- 1 shared `Buffer` for file playback and recording
- 1 recording `SynthDef` for capturing live input into the buffer
- 7 playhead slots (synth nodes, one per playhead)
- 9 `SynthDef`s, one per Sediment UGen
- A waveform analysis routine that sends buffer data to Lua via OSC

#### SynthDef Definitions

Each SynthDef wraps one Sediment UGen. All share a common output structure (stereo out with amplitude envelope and pan). The position-mapped parameter (controlled by grid columns and playhead scanning) is a standard synth arg on each SynthDef.

**Buffer-based SynthDefs:**

```
SynthDef(\graindr_silt, { arg out=0, bufnum, gate=1,
    density=20, dur=0.1, position=0.5, scatter=0.3,
    dist=0, distParam=0.5, pitch=0, shape=0.5,
    amp=1, pan=0;
  var sig = Silt.ar(bufnum, density, dur, position, scatter,
                    dist, distParam, pitch, shape);
  var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
  Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
})

SynthDef(\graindr_clast, { arg out=0, bufnum, gate=1,
    cycles=4, density=40, position=0.5, scan=0.0,
    pitch=0, spread=0.4, shape=0.5,
    amp=1, pan=0;
  var sig = Clast.ar(bufnum, cycles, density, position, scan,
                     pitch, spread, shape);
  var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
  Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
})
```

**Live-input SynthDefs:**

```
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
})

SynthDef(\graindr_talus, { arg out=0, gate=1,
    delay=0.25, density=20, dur=0.2, pitch=0,
    feedback=0.3, spread=0.5,
    amp=1, pan=0;
  var in = SoundIn.ar(0);
  var sig = Talus.ar(in, 2, delay, density, dur, pitch, feedback, spread);
  var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
  Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
})

SynthDef(\graindr_scree, { arg out=0, gate=1,
    sliceDur=0.1, jump=0.3, repeats=2, pitch=0, scatter=0.3,
    amp=1, pan=0;
  var in = SoundIn.ar(0);
  var sig = Scree.ar(in, 2, sliceDur, jump, repeats, pitch, scatter);
  var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
  Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
})

SynthDef(\graindr_loess, { arg out=0, gate=1,
    density=300, grainDur=0.006, timeSpread=0.5,
    pitch=0, pitchSpread=0.5,
    amp=1, pan=0;
  var in = SoundIn.ar(0);
  var sig = Loess.ar(in, density, grainDur, timeSpread, pitch, pitchSpread);
  var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
  Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
})

SynthDef(\graindr_creep, { arg out=0, gate=1,
    ambitus=1, step=0.2, grainDur=0.12, overlap=0.5,
    pitch=0, pause=0.0, spread=0.5,
    amp=1, pan=0;
  var in = SoundIn.ar(0);
  var sig = Creep.ar(in, 2, ambitus, step, grainDur, overlap,
                     pitch, pause, spread);
  var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
  Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
})

SynthDef(\graindr_moraine, { arg out=0, gate=1,
    mode=0, gateThresh=0.05, minHole=0.02, amount=0.5, pitch=0,
    amp=1, pan=0;
  var in = SoundIn.ar(0);
  var sig = Moraine.ar(in, 4, mode, gateThresh, minHole, amount, pitch);
  var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
  Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
})
```

**Synthesis SynthDef:**

```
SynthDef(\graindr_tuff, { arg out=0, gate=1,
    fund=100, form=700, attack=0.003, decay=0.02,
    dur=0.05, band=60, oct=0, spread=0.0,
    amp=1, pan=0;
  var sig = Tuff.ar(fund, form, attack, decay, dur, band, oct, spread);
  var env = EnvGen.kr(Env.asr(0.01, 1, 0.01), gate, doneAction: 2);
  Out.ar(out, Balance2.ar(sig[0], sig[1], pan, amp * env));
})
```

#### Engine Commands

| Command | Format | Description |
|---------|--------|-------------|
| `ugen_select` | `i` | Set active UGen (0-8). Frees all running playheads, updates mode. |
| `head_start` | `if` | Start playhead `i` at position `f` (0.0-1.0). Creates new synth node. |
| `head_stop` | `i` | Free playhead `i` synth node (gate release). |
| `head_position` | `if` | Update playhead `i` position-mapped param to `f`. Called by Lua scanning metro. |
| `head_volume` | `if` | Set playhead `i` amplitude. |
| `head_pan` | `if` | Set playhead `i` pan (-1 to 1). |
| `buf_load` | `s` | Load audio file at path into shared buffer. Send waveform OSC after load. |
| `rec_start` | | Begin recording live input into shared buffer. |
| `rec_stop` | | Stop recording. Send waveform OSC. |
| `<param_name>` | `f` | One command per UGen parameter. Sets on all active playhead synths. |

#### UGen Mode Mapping

| Index | UGen | Category | Input | Grid-mapped param |
|-------|------|----------|-------|-------------------|
| 0 | Silt | buffer | shared buffer | position |
| 1 | Clast | buffer | shared buffer | position |
| 2 | Sediment | live | SoundIn | position |
| 3 | Talus | live | SoundIn | delay |
| 4 | Scree | live | SoundIn | sliceDur |
| 5 | Loess | live | SoundIn | timeSpread |
| 6 | Creep | live | SoundIn | step |
| 7 | Moraine | live | SoundIn | amount |
| 8 | Tuff | synthesis | none | fund (mapped 20-2000 Hz) |

The "grid-mapped param" is the synth arg that `head_position` sets. For each UGen, this is the parameter most analogous to spatial position. The `head_position` command maps the 0.0-1.0 grid value to the appropriate range for that param (e.g. 0-1 for position, 0.01-2.0 for delay, 20-2000 for fund).

#### Waveform Analysis

After `buf_load` or `rec_stop`, the engine reads the buffer contents and sends 128 min/max sample pairs via OSC at `"/graindr/waveform"`. Each pair is encoded as two integers (0-126 mapped from -1.0 to 1.0), sent as individual floats in the OSC message.

#### Recording

A dedicated `SynthDef(\graindr_rec)` writes `SoundIn` to the shared buffer via `RecordBuf`. The buffer is pre-allocated at a fixed maximum duration (60 seconds, 48000 * 60 frames stereo). `rec_start` spawns the recorder synth, `rec_stop` frees it. After stopping, the engine recalculates waveform data and sends it to Lua.

## Norns Lua Script

### graindr.lua — Main Script

```lua
engine.name = 'Graindr'
```

#### init()

1. Connect grid via `grid.connect()`
2. Initialize waveform module
3. Register OSC handler for `"/graindr/waveform"`
4. Build all params (see Params section)
5. Call `params:bang()` to push all defaults to engine
6. Start screen redraw metro at 15fps
7. Start grid redraw metro at 40fps
8. Start playhead scanning metro at 30fps
9. Load default sample if configured in PSET

#### Playhead Scanning

A dedicated metro runs at ~30fps. For each active playhead, it increments the position by `speed * direction * dt` (where dt is the metro interval). The position wraps at 0.0 and 1.0. After updating, it calls `engine.head_position(head, new_position)` and updates the waveform and grid LED displays.

Each playhead has configurable params:
- `head_N_speed`: 0.0 - 0.5 (fraction of buffer per second), default 0.02
- `head_N_direction`: forward (+1) or reverse (-1), default forward

#### Screen (single page)

```
┌──────────────────────────────────┐
│ SILT                             │  ← active UGen name
│                                  │
│ ▁▂▃▅▇█▇▅▃▂▁▁▂▄▆█▇▅▃▁▁▂▃▅▇█▇▅▃ │  ← waveform (128 points across 128px)
│ ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔ │
│     1▮  3▮  ▮5  ▮7               │  ← playhead position indicators (numbered)
│                                  │
│ sample.wav                 0:03  │  ← filename, duration
└──────────────────────────────────┘
```

- E1: cycle through UGen types (updates screen header, switches all playheads)
- E2: global playhead speed (adjusts all active playheads)
- E3: unused (reserved)
- K2: stop all playheads
- K3: toggle recording on/off (with screen indicator)

#### Norns Controls

| Control | Action |
|---------|--------|
| E1 | Cycle UGen: Silt > Clast > Sediment > ... > Tuff > Silt |
| E2 | Global playhead speed (adjusts `head_N_speed` for all heads) |
| E3 | (reserved) |
| K2 | Stop all playheads |
| K3 | Toggle recording start/stop |

### Params Menu Structure

All configuration lives in the params menu. File selection uses the built-in norns file picker. Recording can also be triggered from K3.

```
── GRAINDR ──────────────────
ugen            [option]     Silt / Clast / Sediment / Talus / Scree / Loess / Creep / Moraine / Tuff

── FILE ─────────────────────
sample          [file]       (norns file picker, triggers buf_load)
rec_toggle      [option]     off / recording  (start/stop live recording)

── PLAYHEADS ────────────────
head_1_speed    [control]    0.0 - 0.5, default 0.02  (buffer fraction per second)
head_1_dir      [option]     forward / reverse
head_1_vol      [control]    0.0 - 1.0, default 0.8
head_1_pan      [control]    -1.0 - 1.0, default 0.0
  ... (repeated for playheads 1-7)

── SILT ─────────────────────
silt_density    [control]    1 - 200, default 20
silt_dur        [control]    0.001 - 1.0, default 0.1
silt_scatter    [control]    0.0 - 1.0, default 0.3
silt_dist       [option]     0: uniform, 1: normal, 2: exponential
silt_distParam  [control]    0.0 - 1.0, default 0.5
silt_pitch      [control]    -24 - 24, default 0 (semitones)
silt_shape      [control]    0.0 - 1.0, default 0.5

── CLAST ────────────────────
clast_cycles    [control]    1 - 64, default 4
clast_density   [control]    1 - 200, default 40
clast_scan      [control]    -1.0 - 1.0, default 0.0
clast_pitch     [control]    -24 - 24, default 0
clast_spread    [control]    0.0 - 1.0, default 0.4
clast_shape     [control]    0.0 - 1.0, default 0.5

── SEDIMENT ─────────────────
sed_pitch       [control]    -24 - 24, default 0
sed_scatter     [control]    0.0 - 1.0, default 0.5
sed_bloom       [control]    0.0 - 1.0, default 0.3
sed_drift       [control]    0.0 - 1.0, default 0.3
sed_feedback    [control]    0.0 - 1.0, default 0.0
sed_dryWet      [control]    0.0 - 1.0, default 0.5
sed_freeze      [option]     0: off, 1: on
sed_mode        [option]     0: granular, 1: stretch, 2: looping delay

── TALUS ────────────────────
talus_density   [control]    1 - 200, default 20
talus_dur       [control]    0.001 - 1.0, default 0.2
talus_pitch     [control]    -24 - 24, default 0
talus_feedback  [control]    0.0 - 0.95, default 0.3
talus_spread    [control]    0.0 - 1.0, default 0.5

── SCREE ────────────────────
scree_jump      [control]    0.0 - 1.0, default 0.3
scree_repeats   [control]    1 - 16, default 2
scree_pitch     [control]    -24 - 24, default 0
scree_scatter   [control]    0.0 - 1.0, default 0.3

── LOESS ────────────────────
loess_density   [control]    10 - 1000, default 300
loess_grainDur  [control]    0.001 - 0.05, default 0.006
loess_pitch     [control]    -24 - 24, default 0
loess_pitchSpread [control]  0.0 - 1.0, default 0.5

── CREEP ────────────────────
creep_ambitus   [control]    0.01 - 2.0, default 1.0
creep_grainDur  [control]    0.01 - 0.5, default 0.12
creep_overlap   [control]    0.0 - 1.0, default 0.5
creep_pitch     [control]    -24 - 24, default 0
creep_pause     [control]    0.0 - 1.0, default 0.0
creep_spread    [control]    0.0 - 1.0, default 0.5

── MORAINE ──────────────────
moraine_mode    [option]     0: omit, 1: duplicate, 2: reorder, 3: timewarp
moraine_gate    [control]    0.001 - 0.5, default 0.05
moraine_minHole [control]    0.001 - 0.2, default 0.02
moraine_pitch   [control]    -24 - 24, default 0

── TUFF ─────────────────────
tuff_form       [control]    100 - 5000, default 700 (Hz)
tuff_attack     [control]    0.0005 - 0.05, default 0.003
tuff_decay      [control]    0.005 - 0.2, default 0.02
tuff_dur        [control]    0.01 - 0.2, default 0.05
tuff_band       [control]    10 - 500, default 60
tuff_oct        [control]    -2 - 2, default 0
tuff_spread     [control]    0.0 - 1.0, default 0.0

── INPUT ────────────────────
input_level     [control]    0.0 - 1.0, default 1.0
monitor         [option]     off / on
```

Note: the grid-mapped param for each UGen (position, delay, sliceDur, etc.) is removed from the params menu for that UGen since it is controlled by the grid/playhead scanning. It remains as a synth arg set by `head_position`.

#### Param Actions

Every param's `set_action` calls the corresponding engine command:

```lua
params:set_action("silt_density", function(x) engine.silt_density(x) end)
```

The `ugen` option param's action calls `engine.ugen_select(index)` and updates the screen.

## Grid 128 Interface

### Layout

```
     1   2   3   4   5   6   7   8   9  10  11  12  13  14  15  16
   ┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
 1 │ M1│ M2│ M3│ M4│ M5│ M6│ M7│   │ P1│ P2│ P3│ P4│ P5│ P6│ P7│ALT│  ← control row
   ├───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┤
 2 │                  playhead 1 position                           │
   ├───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┤
 3 │                  playhead 2 position                           │
   ├───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┤
 4 │                  playhead 3 position                           │
   ├───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┤
 5 │                  playhead 4 position                           │
   ├───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┤
 6 │                  playhead 5 position                           │
   ├───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┤
 7 │                  playhead 6 position                           │
   ├───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┼───┤
 8 │                  playhead 7 position                           │
   └───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘
```

### Row 1 — Control

- **Cols 1-7 (M1-M7):** Mute/stop toggle per playhead. Press to mute (stops playhead synth, LED dims). Press again to unmute (playhead can be restarted from its row).
- **Col 8:** Reserved (unlit).
- **Cols 9-15 (P1-P7):** Pattern bank per playhead. Press to arm recording of grid gestures for that playhead. Press again to stop recording and begin playback loop. Alt+press clears pattern.
- **Col 16 (ALT):** Hold modifier. Modifies pattern keys (clear).

### Rows 2-8 — Playhead Control

Each row corresponds to one playhead (row 2 = playhead 1, row 8 = playhead 7).

**Toggle-and-reposition behavior:**
- First press on a row (`z=1`): starts the playhead at position `(x - 1) / 15` (0.0 to 1.0). Creates a new synth node for that playhead. The playhead begins scanning from this position.
- Subsequent presses on the same row: repositions the playhead to the new column position. Does not restart the synth; just sets the position param.
- Stopping: via row 1 mute toggle, K2 (stop all), or UGen switch.

**Position mapping per UGen:**
- Buffer UGens (Silt, Clast): column maps to buffer position (0.0-1.0)
- Sediment: column maps to position (0.0-1.0)
- Talus: column maps to delay time (0.01-2.0s)
- Scree: column maps to slice duration (0.01-1.0s)
- Loess: column maps to time spread (0.0-1.0)
- Creep: column maps to step size (0.0-1.0)
- Moraine: column maps to amount (0.0-1.0)
- Tuff: column maps to fundamental frequency (20-2000 Hz, exponential)

**Pattern recording:** While a playhead's pattern bank is armed, position-set presses on that playhead's row are recorded with timing. On playback, positions replay with original timing in a loop, repositioning the scanning playhead.

### LED Feedback

**Row 1:**
- Mute keys (1-7): bright (15) = active/unmuted, dim (4) = muted/stopped
- Pattern keys (9-15): off (0) = empty, dim (4) = has pattern data, bright (15) = playing, blink = armed for recording

**Rows 2-8:**
- Playhead position shown as interpolated two-LED indicator (fractional brightness across two adjacent columns)
- LED updates at 40fps, driven by the playhead scanning position
- When playhead is inactive: row is dark
- When playhead is muted: row is dark

### Grid Refresh

LED state managed via double-buffered approach:
- Control layer: row 1 state
- Playhead layer: rows 2-8 scanning positions
- Layers composited with `max()` before sending to grid
- Refresh rate: 40fps via `metro`

## Recording

### Flow

1. User presses K3 or sets `rec_toggle` param to "recording"
2. Screen shows `REC` indicator with elapsed time
3. Audio input is written to the shared buffer via `RecordBuf`
4. User presses K3 again or sets `rec_toggle` to "off"
5. Engine sends updated waveform data
6. Waveform display updates to show recorded content
7. The recorded buffer can be used immediately with buffer-based UGens

### Constraints

- Maximum recording duration: 60 seconds (buffer pre-allocated at init)
- Recording overwrites the entire buffer from the start
- Stereo recording (channels 1+2)
- Sample rate: norns native (48000)

## Playhead Lifecycle

### Start

When a grid key activates a playhead:

1. If playhead already has an active synth, just reposition (set position param)
2. Otherwise, create new synth node using the current UGen's SynthDef
3. Pass current param values from the params menu
4. Pass the grid column as the initial position
5. For buffer UGens: pass buffer number
6. Synth runs until freed (gate-based envelope)
7. Playhead begins scanning from the initial position

### Scanning

The Lua scanning metro (30fps) iterates active playheads:

1. Read per-playhead speed and direction from params
2. Increment position: `pos = pos + speed * direction * dt`
3. Wrap position: if > 1.0, wrap to 0.0; if < 0.0, wrap to 1.0
4. Call `engine.head_position(head, pos)` to update the synth
5. Update waveform indicator and grid LED

### Stop

When a playhead is stopped (mute toggle, K2, or UGen switch):

1. Set gate to 0 on the playhead's synth node
2. Envelope release frees the node via `doneAction: 2`
3. Clear playhead slot and position
4. Row goes dark on grid

### UGen Switch

When `ugen_select` is called (via E1 or params):

1. Free all 7 playhead synth nodes (with short release)
2. Update internal UGen mode index
3. Update screen to show new UGen name
4. All playheads are now inactive; user re-activates from grid

## Dependencies

### Required

- **Sediment UGens**: Must be installed at `~/.local/share/SuperCollider/Extensions/Sediment/` on the norns device. The engine checks for availability on init and posts a warning to the REPL if missing.

### norns Built-ins Used

- `engine` (CroneEngine bridge)
- `grid` (monome grid)
- `screen` (128x64 OLED)
- `params` / `paramset`
- `controlspec`
- `metro` (timers)
- `util` (linlin, clamp)
- `osc` (for engine feedback)

## PSET Support

All params are standard norns params and automatically support PSET save/load. This includes:

- Active UGen selection
- All UGen parameters for all 9 UGens
- Per-playhead speed, direction, volume, pan
- Input level and monitor setting
- Last loaded sample file path

On PSET load, the sample file param triggers `buf_load` to reload the saved sample.

## Constraints and Limits

- 7 playheads maximum (grid rows 2-8)
- 1 shared buffer, max 60 seconds
- 9 UGens, global selection (all playheads share one UGen type)
- Grid 128 required (16x8)
- Sediment UGens must be pre-installed
- Screen: 128x64 pixels, 16 brightness levels
- Audio: 48kHz stereo, norns hardware I/O
- RPi resource constraints: one UGen type at a time, shared params across playheads
