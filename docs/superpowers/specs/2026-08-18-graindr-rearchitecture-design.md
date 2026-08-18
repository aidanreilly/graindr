# graindr rearchitecture design

Date: 2026-08-18

## Summary

graindr becomes a self-contained norns granular instrument with no external
UGen dependency. The Sediment UGen suite and its build script are removed. A
new SuperCollider engine derived from
[Engine_Glut](https://github.com/artfwo/glut/blob/master/Engine_Glut.sc)
replaces it, using `GrainBuf` and a free-running `Phasor` per voice.

Eight voices read one shared sample buffer. Every playhead moves continuously
from the moment the engine boots. Each voice carries its own LFO that modulates
playhead speed bipolarly, so the playhead slows, reverses and accelerates under
modulation. Voices are sounded by grid mutes, by momentary grid presses, and by
MIDI. MIDI additionally transposes the voice it takes, which makes chromatic
chords playable across the eight granular streams.

The screen UI and the general feel of the instrument are unchanged: a simple
front page with a waveform and numbered playheads, with the detailed controls
living in the params menu.

## Goals

- Remove the Sediment UGen dependency and the `install-sediment.sh` build step.
- Rename `sediment.lua` to `graindr.lua`.
- Replace `lib/Engine_Sediment.sc` with `lib/Engine_Graindr.sc`, based on Glut.
- Give every voice a params-accessible LFO controlling playhead direction and
  rate.
- Keep all eight playheads moving from script start.
- Make the instrument playable with no MIDI attached, using grid mutes.
- Let MIDI trigger and transpose voices, overriding mutes.
- Keep the screen UI as it is.

## Non-goals

- Per-voice sample files. Glut loads a separate file per voice; graindr keeps
  one shared buffer so the single-waveform screen stays meaningful.
- Clock-synced LFO rates. Rates are free-running Hz.
- Automated tests. norns scripts cannot run off-device; see Verification.

## File changes

| Action | Path |
| --- | --- |
| rename and rewrite | `sediment.lua` to `graindr.lua` |
| new | `lib/Engine_Graindr.sc` |
| delete | `lib/Engine_Sediment.sc` |
| delete | `install-sediment.sh` |
| edit | `lib/waveform.lua` |
| rewrite | `README.md` |

`engine.name` becomes `"Graindr"`.

## Engine architecture

### Structure

Follows Glut. Eight voice synths are allocated once in `alloc` into a
`ParGroup` and are never freed during the script's life. They output to a
stereo `mixBus`, which feeds a `FreeVerb` effect synth, which feeds
`context.out_b`.

`classvar nvoices = 8;`

Because the voice synths are persistent, `Phasor.kr` runs from engine start.
Playheads therefore move continuously with no work from Lua. The `gate`
argument only opens and closes the amplitude envelope.

### Buffers

Two mono buffers, `bufL` and `bufR`, shared by all eight voices, allocated at
`context.server.sampleRate * 60` frames.

`bufL` and `bufR` are always distinct `Buffer` objects, never aliases of each
other. Glut can point both at one buffer for a mono file because it reallocates
per voice on every read; graindr shares its buffers across all eight voices and
also records into them, so aliasing would cause a double `free` on the next
load and would make both channels of a recording write to the same memory.

`buf_load` reads channel 0 of the source file into a fresh buffer. If the file
has more than one channel it reads channel 1 into a second fresh buffer;
otherwise it reads channel 0 a second time. Both reads complete before the old
`bufL` and `bufR` are freed and the voices are `set` to the new bufnums, so a
failed read cannot leave a voice pointing at freed memory. The waveform summary
and buffer info are sent to Lua from the second read's completion callback.

Recording captures `SoundIn.ar(0)` into `bufL` and `SoundIn.ar(1)` into `bufR`
via two `RecordBuf` instances in one synth. `rec_start` first reallocates both
buffers to the full 60 seconds, since a previously loaded short sample would
otherwise cap the recording length.

### Voice SynthDef

`\graindr_voice` arguments:

```
out, phase_out, buf_l, buf_r,
gate=0, pos=0, t_reset_pos=0,
speed=1, pitch=1, pan=0, gain=1,
size=0.1, density=20, jitter=0, spread=0, envscale=1,
lfo_shape=0, lfo_rate=0.2, lfo_depth=0
```

The grain path is Glut's, unmodified in structure:

```supercollider
grain_trig = Impulse.kr(density);
buf_dur = BufDur.kr(buf_l);

pan_sig = TRand.kr(trig: grain_trig, lo: spread.neg, hi: spread);
jitter_sig = TRand.kr(trig: grain_trig,
    lo: buf_dur.reciprocal.neg * jitter,
    hi: buf_dur.reciprocal * jitter);
```

The LFO is new. It runs at control rate inside the SynthDef so that playhead
position stays engine-authoritative and modulation stays smooth:

```supercollider
lfo_sig = Select.kr(lfo_shape, [
    SinOsc.kr(lfo_rate),
    LFTri.kr(lfo_rate),
    LFSaw.kr(lfo_rate),
    LFPulse.kr(lfo_rate, 0, 0.5) * 2 - 1,
    LFNoise0.kr(lfo_rate)
]);
eff_speed = speed + (lfo_sig * lfo_depth);
```

`lfo_shape` indices are 0 sine, 1 triangle, 2 saw, 3 square, 4 random
sample-and-hold. `LFPulse` is rescaled to bipolar so all five shapes share a
range of -1 to 1.

Playhead and output:

```supercollider
buf_pos = Phasor.kr(trig: t_reset_pos,
    rate: buf_dur.reciprocal / ControlRate.ir * eff_speed,
    resetPos: pos);
pos_sig = Wrap.kr(buf_pos);

sig_l = GrainBuf.ar(1, grain_trig, size, buf_l, pitch, pos_sig + jitter_sig, 2);
sig_r = GrainBuf.ar(1, grain_trig, size, buf_r, pitch, pos_sig + jitter_sig, 2);
sig_mix = Balance2.ar(sig_l, sig_r, pan + pan_sig);

env = EnvGen.kr(Env.asr(1, 1, 1), gate: gate, timeScale: envscale);

Out.ar(out, sig_mix * env * gain);
Out.kr(phase_out, pos_sig);
```

Glut's `freeze` argument is dropped. A `speed` of 0 with `lfo_depth` of 0
already halts the playhead, so `freeze` adds a `Select.kr` for no new
behaviour. Glut's `level_out` bus and `level_N` polls are dropped too, because
Lua already knows each voice's gate state and does not need it echoed back.

### Effect SynthDef

Carried over from Glut unchanged:

```supercollider
SynthDef(\effect, { arg in, out, mix=0.5, room=0.5, damp=0.5, amp=1;
    var sig = In.ar(in, 2);
    sig = FreeVerb.ar(sig, mix, room, damp);
    Out.ar(out, sig * amp);
}).add;
```

The `amp` argument is graindr's addition. Glut routes its `volume` command to
each voice's `\gain`, but graindr already spends `\gain` on the per-voice level
param. Putting master volume on the effect synth keeps the two independent and
means a master change is one `set` rather than eight.

### Commands

Voice-indexed commands take a 1-based voice number, matching Glut's
convention, and subtract 1 internally.

| Command | Format | Effect |
| --- | --- | --- |
| `gate` | `ii` | set `\gate` on voice |
| `seek` | `if` | set `\pos` and pulse `\t_reset_pos` on voice |
| `speed` | `if` | set `\speed` on voice |
| `pitch` | `if` | set `\pitch` on voice, as a frequency ratio |
| `pan` | `if` | set `\pan` on voice |
| `level` | `if` | set `\gain` on voice |
| `lfo_shape` | `ii` | set `\lfo_shape` on voice, 0 to 4 |
| `lfo_rate` | `if` | set `\lfo_rate` on voice, Hz |
| `lfo_depth` | `if` | set `\lfo_depth` on voice |

Global commands apply to all eight voices, or to the effect or buffers.

| Command | Format | Effect |
| --- | --- | --- |
| `size` | `f` | grain size, seconds |
| `density` | `f` | grains per second |
| `jitter` | `f` | position jitter, seconds |
| `spread` | `f` | per-grain pan spread, 0 to 1 |
| `envscale` | `f` | envelope attack and release scale |
| `volume` | `f` | master amplitude, sets `\amp` on the effect synth |
| `reverb_mix` | `f` | FreeVerb mix |
| `reverb_room` | `f` | FreeVerb room |
| `reverb_damp` | `f` | FreeVerb damp |
| `buf_load` | `s` | load a sample into the shared buffers |
| `rec_start` | `` | begin recording from input |
| `rec_stop` | `` | stop recording, resend waveform |

Global values are held in a `Dictionary` so that a voice re-set after
`buf_load` keeps the current settings.

All commands take engine-native units. Lua owns the conversion from
display units: milliseconds are divided by 1000 before `size` and `jitter`,
percent is divided by 100 before `spread`, and decibels become a linear
amplitude via `math.pow(10, db / 20)` before `volume` and `level`. Semitones
become a ratio via `math.pow(2, semitones / 12)` before `pitch`. Keeping the
conversions on one side avoids the class of bug where a param and a command
disagree about units.

### Data back to Lua

Two transports, chosen for what each one can carry.

Eight `addPoll` polls named `phase_1` through `phase_8` return each voice's
`pos_sig` from its control bus. In `init`, Lua calls `poll.set("phase_" .. i,
callback)` for each, sets `.time = 1/15`, and calls `:start()`. Each callback
stores the value on `voices[i].phase` and forwards it to
`waveform:set_head_pos(i, value)`. These polls drive the on-screen and on-grid
playheads, replacing the dead-reckoning `update_positions()` loop in the
current script.

Poll rate, screen redraw rate and grid refresh rate are all `1/15`. Refreshing
faster than the polls arrive would redraw identical playhead positions, which
costs CPU on an RPi 3B+ for no visible gain.

The 128-point waveform summary and the buffer frame count and sample rate go
over custom OSC, because polls carry a single float. Paths become
`/graindr/waveform` and `/graindr/buf_info`. The destination stays
`NetAddr("127.0.0.1", 10111)`, matron's remote port. The existing explanatory
comment about why `Crone.remoteAddr` on 8888 does not work is carried across
verbatim, since that finding is easy to lose and expensive to rediscover.

The `sendWaveform` method is carried over from `Engine_Sediment.sc` with its
debug `postln` calls removed and its OSC path renamed. It reads `bufL` only.

### Cleanup

`free` frees the voice synths, the phase buses, `bufL`, `bufR` when it differs
from `bufL`, the effect synth, and `mixBus`.

## Lua architecture

### Voice state

An array of eight tables, 1-indexed:

```lua
{
  muted     = true,  -- mirrors the voice's mute param
  held_x    = nil,   -- grid column currently held in this row, or nil
  midi_note = nil,   -- MIDI note currently assigned, or nil
  midi_time = 0,     -- util.time() when the note was assigned, for stealing
  base_ratio = 1.0,  -- from the voice's pitch param, in semitones
  phase     = 0      -- most recent value from the phase poll
}
```

### Gate rule

One predicate governs audibility:

```lua
local function audible(i)
  local v = voices[i]
  return (not v.muted) or (v.held_x ~= nil) or (v.midi_note ~= nil)
end
```

`update_gate(i)` computes it, compares against a cached `gate_state[i]`, and
sends `engine.gate(i, ...)` only on a change. Every input path calls
`update_gate` after mutating state, so mute, grid and MIDI cannot disagree
about whether a voice is on.

### Pitch

Each voice's pitch param is in semitones and produces `base_ratio` as
`2^(semitones/12)`. When MIDI takes a voice:

```lua
engine.pitch(i, v.base_ratio * math.pow(2, (note - root_note) / 12))
```

Note-off restores `engine.pitch(i, v.base_ratio)`. A voice detuned in the
params menu therefore keeps its character when played from MIDI.

### MIDI allocation

`allocate_voice()` searches in order:

1. A voice that is muted and has no MIDI note. This protects drones you have
   deliberately unmuted.
2. Any voice with no MIDI note.
3. The voice whose `midi_time` is oldest, stolen.

Note-off looks up a voice by `midi_note`. A stolen voice's original note will
find nothing on release, which is a no-op.

MIDI channel filtering uses the existing `midi_channel` param, where 0 means
all channels.

### Grid

Row `y` maps to voice `y`, for `y` in 1 to 8. Rows beyond 8 are ignored.

Column 1 is mute. On key-down it toggles the voice's mute param, which in turn
sets `voices[y].muted` and calls `update_gate`.

Columns 2 to 16 are seek positions, `pos = (x - 2) / 14`, giving 15 positions
across the buffer. On key-down: `engine.seek(y, pos)`, set `held_x = x`, then
`update_gate`. On key-up: clear `held_x` only if it still equals `x`, then
`update_gate`. Guarding on the column value means that releasing an earlier
finger in a row does not cut a later press.

Grid LEDs, refreshed at 1/15:

- Column 1: level 15 when the voice is unmuted, level 3 when muted.
- Columns 2 to 16: the playhead, drawn with the existing two-cell brightness
  interpolation remapped from 16 columns to 15. `float_x = phase * 14 + 2`.

### Screen

The layout does not change. Top left reads `GRAINDR` at level 15. The centre of
the top line, where the Sediment mode name used to be, shows the count of
currently sounding voices. Recording status stays top right. The waveform
occupies the middle. Sample name and duration run along the bottom.

A single metro at 1/15 calls `redraw()` and `grid_refresh()`. The scan metro
that previously ran `update_positions()` is deleted, because playhead values
now arrive from the phase polls.

### `lib/waveform.lua` changes

All eight heads are drawn at all times, because all eight playheads always
move. `set_head_active` no longer controls whether a head draws, only how
brightly:

- Sounding voice: head line at level 15, number label at level 10.
- Silent voice: head line at level 4, number label at level 3.

The `set_head_pos`, `set_head_active`, `set_samples` and `clear` interfaces are
unchanged, so nothing else in the module moves.

### Encoders and keys

- E1 density
- E2 size
- E3 jitter
- K2 panic: mute every voice, clear every `held_x` and `midi_note`, gate all
  voices off
- K3 toggle recording from input

### Params

Roughly 50 params, in this order.

`GLOBAL` group:

| Param | Range | Default |
| --- | --- | --- |
| density | 1 to 512, exp, grains/s | 20 |
| size | 1 to 500, exp, ms | 100 |
| jitter | 0 to 500, lin, ms | 0 |
| spread | 0 to 100, lin, % | 0 |
| envscale | 0 to 10, lin, s | 1 |
| volume | -60 to 20, db | 0 |
| reverb mix | 0 to 1, lin | 0.3 |
| reverb room | 0 to 1, lin | 0.5 |
| reverb damp | 0 to 1, lin | 0.5 |
| sample | file, `/home/we/dust/audio/` | none |

Eight `voice N` groups, each:

| Param | Range | Default |
| --- | --- | --- |
| mute | off / on | on |
| speed | -2 to 2, lin | 1.0 |
| pitch | -24 to 24, semitones | 0 |
| pan | -1 to 1, lin | 0 |
| level | -60 to 20, db | 0 |
| lfo shape | sine / triangle / saw / square / random | sine |
| lfo rate | 0.01 to 10, exp, Hz | 0.2 |
| lfo depth | 0 to 4, lin | 0 |

`MIDI` group: channel (all, 1 to 16), root note (0 to 127, default 60).

`INPUT` group: monitor (off / on).

Mute lives in params rather than in Lua state alone so that grid mutes are
saved and restored with a PSET. The grid handler sets the param and the param
action updates voice state, which keeps a single source of truth.

Defaults of `speed` 1.0 and `lfo_depth` 0 mean that on a fresh load every
playhead scans forward at natural rate with no modulation, which is the
clearest starting point for someone dialling in an LFO.

## Behaviour summary

At script start every voice is muted, so nothing sounds, while all eight
playheads scan the buffer visibly on screen and on the grid. Unmuting a row
with column 1 opens that voice into a drone. Holding a button in columns 2 to
16 seeks that voice's playhead and sounds it for as long as the button is
held, so muted rows become momentary stabs and unmuted rows become scrubbable.
Raising a voice's LFO depth makes its playhead wander, reverse and surge.
Incoming MIDI takes a voice, overrides its mute, and transposes it, so several
notes at once produce a chord across independently drifting granular streams.

## Verification

There is no test harness in this repo and norns scripts cannot run off-device.
Verification is therefore layered:

1. `luac -p graindr.lua lib/waveform.lua` for Lua syntax, if `luac` is present.
2. `sclang -D lib/Engine_Graindr.sc` or a class-library parse check, if
   `sclang` is present. Failing that, careful review against Glut, which is
   known-good on norns.
3. Manual checks on hardware, in this order: script loads with no engine
   error; eight playheads move on screen with no sample loaded; a sample loads
   and the waveform draws; column 1 mutes toggle audibly; columns 2 to 16 seek
   and sound; a MIDI chord plays chromatically; LFO depth visibly changes
   playhead motion; K2 silences everything; K3 records.

Work is sequenced so that each step leaves the script loadable, rather than
landing as one large rewrite.

## README

Rewritten to describe graindr as a polyphonic granular synth whose engine is
based on Glut by artfwo, with a link to the Glut repository and an
acknowledgement. The Sediment sections and the `install-sediment.sh`
instructions are removed, and the install section becomes the one-line
`;install` with no build step. Controls documentation covers the grid layout,
the encoder and key map, and the LFO.
