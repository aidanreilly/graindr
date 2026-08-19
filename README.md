# graindr

A polyphonic granular synth for [norns](https://monome.org/norns).

Eight granular voices read one shared sample. Play it from the grid with no MIDI attached, or send MIDI to transpose voices into chords.

The engine is based on [Engine_Glut](https://github.com/artfwo/glut) by artfwo, adapted for a shared buffer, per-voice LFO modulation of playhead speed, loop points, and a global ADSR.

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

Load a sample from PARAMS > GRAINDR > sample, or hold K3 to record from input. Then press a grid pad.

graindr holds 60 seconds of audio, which is also as long as it will record in one pass. A longer file loads its **first 60 seconds only**.

### Grid

Row `n` is voice `n`. Column 1 is the control column, so the remaining 15 columns are playhead positions.

Pressing a row's control button cycles it: dim is unselected, lit means braces on that row play one-shot, blinking means they sustain and loop. A third press returns it to dim, and only one row is selected at a time. The mode applies to the next gesture, not to anything already sounding.

A press jumps that voice's playhead to that point in the sample and fires one complete cycle of the envelope. 

**Looping.** Hold one pad and tap another on the same row. The playhead is trapped between the two, and runs in the direction you pressed: left-to-right loops forward, right-to-left loops backward.

A single press anywhere on a braced row frees the brace and plays the one-shot, so getting out of a loop is the same gesture as playing a note. Holding that pad and tapping a second still sets a new brace, which simply replaces the one the press dropped.

Braces are cleared whenever the buffer underneath them is replaced — loading a sample, starting a recording, or finishing one — since there is nothing left for them to point at. Any voice held open by a loop is let go at the same time.

A brace bounds the playhead in either mode. The control column decides the envelope over it: one-shot plays a single cycle, loop sustains at full level for as long as the brace is set, and only clearing it lets go, fading out over the release time.

### MIDI

A note takes a voice and transposes it relative to the root note param. A single note sounds the selected row, and a chord takes the rows below it in turn, wrapping at the bottom.

### Norns

- **E1** grain density
- **E2** grain size
- **E3** position jitter
- **K2** panic: cut every voice and drop all held notes
- **K3** toggle recording from input

## Voices and rand amt

There is one set of voice params, shared by all eight voices, plus **rand amt**. That is what makes the voices differ from each other.

At 0, all eight are identical. Turn it up and each voice gets its own random offset on speed, pitch, pan, level and both LFO controls, scaled from that one knob: at 16 the spread is a full ±16 semitones of pitch, ±1.0 of speed, hard left to hard right, ±12 dB, and the LFO wandering across most of its range. New offsets are rolled every time a voice is triggered, so repeated hits on the same pad never sound quite alike.

Turning a shared param while a voice is sounding pushes the base value to every voice immediately, which collapses the randomisation until the next trigger rolls it again.

## Grains

**smooth** is the one dial if you just want it more fluid. It sweeps density, size and scatter together along a grainy-to-liquid axis: at 0% it is pointillist, a scatter of separate events; at 50% it is the default, six grains deep and continuous; past 75% it is a wash. It writes to the three params underneath rather than hiding them, so you can see where it put them and carry on by hand from there — until you move it again, which takes them back.

**density** is how often a voice fires a grain, and **size** is how long each one lasts. Multiplied together they give how many grains overlap at any moment, and that number is what fluid rather than grainy actually means. Below about two you hear individual grains; four to eight is continuous; past twenty it is a wash. 20 Hz at 100 ms is two. The defaults are 40 Hz at 150 ms, which is six.

**scatter** is how far each grain's onset and length wander from the clock. At zero the grains fire on an exact grid, and at low densities you hear that grid as a pulse rather than as texture — the machine-gun artifact. A little scatter and the same grains become a cloud. It varies grain length as well as timing, which stops identical overlapping grains comb-filtering against each other.

**grains** is a different axis. It runs up to four parallel grain clouds over the same playhead, each with its own clock, its own jitter and its own pan, rather than making one cloud fire faster. Every stream runs a few percent off its neighbours, so they never settle into the shared onset grid that a single faster clock gives you — turning it up thickens and diffuses rather than just adding density. The mix is compensated by the square root of the count, since the streams are uncorrelated, so it should stay at roughly the same level as you go.

All four streams exist in the synth graph whether you use them or not, but an unused one has its trigger held at zero, and a `GrainBuf` with no triggers has no grains to iterate — so an idle stream costs its empty per-block overhead and nothing more.

The same gate carries the envelope, so a voice at rest computes no grains at all. That matters more than it sounds: eight voices are allocated from the moment the engine loads, and without it they would all grind through a full grain load whether or not anything was letting the sound out.

Grains are read with cubic interpolation. Every grain of a MIDI note off the root note is a resampled read, so this is audible exactly where it matters — playing it as a synth rather than scrubbing it at unity.

## LFO

The LFO adds a bipolar offset to playhead speed.

## Params

Everything lives under one **GRAINDR** menu item, in sections:

**sample** the sample file.

**grains** smooth, grains, density, grain size, scatter, jitter, spread.

**voices** attack, decay, sustain, sustain time, release, then the shared voice params — speed, pitch, pan, level, the three LFO controls — and rand amt.

**output** volume and reverb mix, room and damp.

**midi** channel and root note.

**input** input monitoring.

## Credits

The granular engine is derived from [glut](https://github.com/artfwo/glut) by artfwo, which is where the `GrainBuf` voice structure, the `Phasor` playhead and the phase polling all come from.
