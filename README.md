# graindr

A norns instrument built on the [Sediment](https://github.com/bjarnig/Sediment) SuperCollider UGen suite. Nine granular texture-synthesis algorithms, routed through a grid-controlled multi-playhead interface.

## Scripts

### graindr

Seven simultaneous playheads scan through a loaded audio buffer or live input. Each playhead feeds one of nine selectable UGen algorithms: Silt, Clast, Sediment, Talus, Scree, Loess, Creep, Moraine, and Tuff. Grid rows 2-8 place and reposition playheads. Row 1 controls mutes (columns 1-7) and pattern recorders (columns 9-15).

**Controls**

- **E1** cycle UGen algorithm
- **E2** global playhead speed
- **K2** stop all playheads
- **K3** toggle recording from input

### sediment

MIDI-driven polyphonic instrument (8 voices) using the Sediment UGen. Incoming MIDI notes spawn voices with pitch offset from a configurable root note. Grid columns set per-voice buffer position.

**Controls**

- **E1** cycle mode (granular / stretch / delay)
- **E2** scatter
- **E3** bloom
- **K2** kill all voices
- **K3** toggle recording from input

## Requirements

- norns (tested on RPi 3B+)
- [Sediment UGens](https://github.com/bjarnig/Sediment) compiled and installed
- grid (optional, recommended)
- MIDI controller (for sediment script)

## Install

```
;install https://github.com/aidanreilly/graindr
```

Then compile the Sediment UGen plugin on your norns:

```
ssh we@norns.local
cd dust/code/graindr
./install-sediment.sh
```

The install script clones the Sediment source, builds the C++ UGens against your norns SuperCollider headers, and places the compiled `.so` files into the SC extensions directory. It requires `cmake`, `g++`, and `supercollider-dev` (all present on stock norns images).

After installation, restart SuperCollider from maiden or reboot norns.
