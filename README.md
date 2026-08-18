# graindr

A polyphonic granular synth for [norns](https://monome.org/norns).

Eight granular voices read one shared sample. Every voice starts at rest: silent, with its playhead parked. A note wakes one up, its playhead scans the sample for as long as the envelope holds it open, and both fade away together. Play it from the grid with no MIDI attached, or send MIDI to transpose voices into chords.

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

graindr holds 60 seconds of audio, which is also as long as it will record in one pass. A longer file loads its first 60 seconds rather than being refused, and the duration in the bottom right is marked with a `*` so you can see it was cut. A file it cannot read as audio at all is skipped with a warning in maiden, leaving the current sample alone.

### Grid

Row `n` is voice `n`, and all 16 columns are playhead positions.

A press jumps that voice's playhead to that point in the sample and fires one complete cycle of the envelope. How long the sound lasts is the ADSR's job, not your finger's: attack, decay, sustain time and release decide whether a press is a percussive stab or a pad that blooms and fades. Press again at any point, including during the sustain, to restart it from the attack. Turn **sustain time** all the way up and it reads `inf`, which holds at the sustain level until you press again or hit K2 — the ADSR becomes a drone box rather than a trigger machine.

The waveform is normalised to the loaded sample's own peak, so a quiet or very short one fills the display rather than drawing as a thin line through the middle. A nearly silent buffer is left alone rather than being amplified into a screenful of noise.

The playhead only exists while the voice is sounding. It appears on the attack, travels while the envelope is open, and fades out along the release curve before freezing where it stopped. A row with nothing playing is dark, and so is its line on the screen.

**Looping.** Hold one pad and tap another on the same row. The playhead is trapped between the two, and runs in the direction you pressed: left-to-right loops forward, right-to-left loops backward.

A single press anywhere on a braced row frees the brace and plays the one-shot, so getting out of a loop is the same gesture as playing a note. Holding that pad and tapping a second still sets a new brace, which simply replaces the one the press dropped.

Braces are cleared whenever the buffer underneath them is replaced — loading a sample, starting a recording, or finishing one — since there is nothing left for them to point at. Any voice held open by a loop is let go at the same time.

A loop takes the ADSR out of the picture. Decay, sustain level and sustain time stop applying and nothing runs out underneath it: the voice sustains at full level for as long as the loop is set, and only clearing the loop lets it go, fading out over the release time. Attack and release are kept as the ramps in and out so engaging and dropping a loop does not click. K2 cuts it and leaves the brace lit, but any press on that row frees the brace rather than restarting it, so a cut loop is remade rather than resumed. A brace stays lit dimly while the voice is silent, so you can see what a row is armed to do before you play it.

### MIDI

A note takes a voice and transposes it relative to the root note param. Unlike a grid press, a MIDI note holds at the sustain level for as long as you hold the key, and note-off starts the release. Transposition multiplies the voice's own pitch param rather than replacing it, so the pitch you dialled in still colours the note.

A MIDI note restarts its voice from the last position seeked on the grid, so playing a chord stacks voices at wherever you last pressed. A voice you have never touched on the grid starts from its own even spread across the sample.

Allocation prefers silent voices, so MIDI will not cut off something still ringing until it runs out of quiet ones.

### Norns

- **E1** grain density
- **E2** grain size
- **E3** position jitter
- **K2** panic: cut every voice and drop all held notes
- **K3** toggle recording from input

Turning an encoder puts its name and value over the middle of the waveform, at the same rounding and units the params menu would show. It fades out about a second after you stop.

## Voices and rand amt

There is one set of voice params, shared by all eight voices, plus **rand amt**. That is what makes the voices differ from each other.

At 0, all eight are identical. Turn it up and each voice gets its own random offset on speed, pitch, pan, level and both LFO controls, scaled from that one knob: at 16 the spread is a full ±16 semitones of pitch, ±1.0 of speed, hard left to hard right, ±12 dB, and the LFO wandering across most of its range. New offsets are rolled every time a voice is triggered, so repeated hits on the same pad never sound quite alike.

Turning a shared param while a voice is sounding pushes the base value to every voice immediately, which collapses the randomisation until the next trigger rolls it again.

## Grains

**density** is how often a voice fires a grain, and **size** is how long each one lasts. Multiplied together they give how many grains overlap at any moment: 20 Hz at 100 ms is two, 512 Hz at 500 ms is 256, which is most of what a single `GrainBuf` will hold.

**grains** is a different axis. It runs up to four parallel grain clouds over the same playhead, each with its own clock, its own jitter and its own pan, rather than making one cloud fire faster. Every stream runs a few percent off its neighbours, so they never settle into the shared onset grid that a single faster clock gives you — turning it up thickens and diffuses rather than just adding density. The mix is compensated by the square root of the count, since the streams are uncorrelated, so it should stay at roughly the same level as you go.

All four streams exist in the synth graph whether you use them or not, but an unused one has its trigger held at zero, and a `GrainBuf` with no triggers has no grains to iterate — so an idle stream costs its empty per-block overhead and nothing more.

The same gate carries the envelope, so a voice at rest computes no grains at all. That matters more than it sounds: eight voices are allocated from the moment the engine loads, and without it they would all grind through a full grain load whether or not anything was letting the sound out.

## CPU

norns runs this on one core, and `density`, `size`, `grains` and the number of voices actually sounding all multiply into the same budget:

```
concurrent grains = voices sounding x grains x 2 x density x size
```

Two grain streams at 20 Hz and 100 ms is 4 grains a voice. The top of every range at once — eight voices, four streams, 512 Hz, 500 ms — is over sixteen thousand, which no norns will do. There is a lot of usable ground in between, and where the wall sits depends on your hardware.

So the percentage in the top of the screen is scsynth's average load. It stays dim until it reaches 80% and then lights up. Push `grains` and `density` while watching it rather than guessing where the limit is.

## LFO

The LFO adds a bipolar offset to playhead speed:

```
effective speed = speed + (lfo * depth)
```

With depth at 0 the playhead scans at a constant rate. Raise depth past the speed and the sum swings through zero, so the playhead slows, reverses, and surges. Shapes are sine, triangle, saw, square, and random sample-and-hold. Rates are free-running, from 0.01 to 10 Hz, and rand amt detunes each voice's rate so they drift out of phase with each other.

Square at a low rate gives hard direction flips. Random gives a playhead that lurches to a new speed on every step. Inside a loop, the LFO pushes the playhead back and forth within the region rather than across the whole sample.

## Params

Everything lives under one **GRAINDR** menu item, in sections:

**sample** the sample file.

**grains** grains, density, grain size, jitter, spread.

**voices** attack, decay, sustain, sustain time, release, then the shared voice params — speed, pitch, pan, level, the three LFO controls — and rand amt.

**output** volume and reverb mix, room and damp.

**midi** channel and root note.

**input** input monitoring.

## Credits

The granular engine is derived from [glut](https://github.com/artfwo/glut) by artfwo, which is where the `GrainBuf` voice structure, the `Phasor` playhead and the phase polling all come from.
