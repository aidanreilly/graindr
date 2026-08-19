# graindr

A polyphonic granular synth for [norns](https://monome.org/norns).

Eight granular voices read one shared sample. Play it from the grid with no MIDI attached, or send MIDI to transpose voices into chords.

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

A single press anywhere on a braced row frees the brace and plays the one-shot. Holding that pad and tapping a second sets a new brace in place of the old one.

Loading a sample, starting a recording or finishing one clears every brace, and lets go of any voice a loop was holding open.

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

**smooth** sweeps density, size and scatter together, from pointillist at 0% through the default at 50% to a wash past 75%. It writes to those three params, so you can carry on by hand from wherever it leaves them.

**density** is how often a voice fires a grain, **size** is how long each one lasts. Multiplied together they give how many grains overlap: below two you hear individual grains, four to eight is continuous, past twenty is a wash. The defaults are 40 Hz at 150 ms, which is six.

**scatter** is how far each grain's onset and length wander from the clock. At zero the grains fire on an exact grid, which at low densities is audible as a pulse.

## LFO

The LFO adds a bipolar offset to playhead speed.

## Delay and reverb

The engine feeds the delay, and both the dry engine and the delay feed the reverb.

**rate** re-pitches the repeats. **filter** is a lowpass on the delay line.

The script sets the sends only. The reverb's own settings are in SYSTEM > AUDIO, and graindr does not put them back as it found them.

## Params

Everything lives under one **GRAINDR** menu item, in sections:

**sample** the sample file.

**grains** smooth, density, grain size, scatter, jitter, spread.

**voices** attack, decay, sustain, release, then the shared voice params — speed, pitch, pan, level, the three LFO controls — and rand amt.

**output** volume.

**delay** level, time, feedback, rate, pan, filter cutoff and resonance.

**reverb** return level, dry send and delay send.

**midi** channel and root note.

## Credits

The granular engine is derived from [glut](https://github.com/artfwo/glut) by artfwo. The delay is after [halfsecond](https://github.com/monome/dust) by @tehn.
