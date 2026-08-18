# graindr

A polyphonic granular synth for [norns](https://monome.org/norns).

Eight granular voices read one shared sample. Every playhead moves continuously
from the moment the script loads, each one driven by its own LFO that modulates
the direction and rate of its travel. Play it from the grid with no MIDI
attached, or send MIDI to transpose voices into chords.

The engine is based on [Engine_Glut](https://github.com/artfwo/glut) by artfwo,
adapted for a shared buffer, per-voice LFO modulation of playhead speed, and a
global ADSR.

## Requirements

- norns
- grid, optional but recommended
- MIDI controller, optional

No external UGens and no compilation step.

## Install

```
;install https://github.com/aidanreilly/graindr
```

## Playing it

Load a sample from PARAMS > GLOBAL > sample, or hold K3 to record from input.
Then press a grid pad.

### Grid

Row `n` is voice `n`, and all 16 columns are playhead positions. A press jumps
that voice's playhead to that point in the sample and fires one cycle of the
envelope. Brightness shows which voices are currently sounding.

How long a press lasts is the envelope's job, set by **sustain mode**:

- **timed** plays one complete A-D-S-R cycle and stops by itself after the
  sustain time. Short sustain gives percussive stabs, long sustain gives pads
  that fade on their own. Pressing again during the sustain restarts the
  attack.
- **infinite** holds at the sustain level and drones until you hit K2.

So the ADSR decides whether the instrument is a trigger machine or a drone box,
and the grid is one gesture either way.

### MIDI

A note takes a voice and transposes it relative to the root note param. MIDI
keeps normal synth behaviour regardless of sustain mode: the note holds at the
sustain level for as long as you hold the key, and note-off starts the release. Transposition multiplies the voice's own pitch param rather
than replacing it, so a voice you have detuned in the params menu keeps its
character when you play it.

Allocation prefers silent voices, so MIDI will not interrupt a drone you
started from the grid until it runs out of quiet ones.

### Norns

- **E1** grain density
- **E2** grain size
- **E3** position jitter
- **K2** panic: release every voice and drop all held notes
- **K3** toggle recording from input

## LFO

Each voice has an LFO in PARAMS > voice *n*. It adds a bipolar offset to that
voice's playhead speed:

```
effective speed = speed + (lfo * depth)
```

With depth at 0 the playhead scans at a constant rate. Raise depth past the
voice's speed and the sum swings through zero, so the playhead slows, reverses,
and surges. Shapes are sine, triangle, saw, square, and random sample-and-hold.
Rates are free-running, from 0.01 to 10 Hz, so voices drift out of phase with
each other.

Square at a low rate gives hard direction flips. Random gives a playhead that
lurches to a new speed on every step.

## Params

**GLOBAL** density, grain size, jitter, spread, attack, decay, sustain level,
sustain mode, sustain time, release, volume, reverb mix/room/damp, and the
sample file.

**voice 1-8** speed, pitch, pan, level, and the three LFO controls.

**MIDI** channel and root note.

**INPUT** input monitoring.

## Credits

The granular engine is derived from [glut](https://github.com/artfwo/glut) by
artfwo, which is where the `GrainBuf` voice structure, the free-running
`Phasor` playhead and the phase polling all come from.
