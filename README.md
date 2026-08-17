# graindr

A norns instrument built on the [Sediment](https://github.com/bjarnig/Sediment) SuperCollider UGen suite.

## Scripts

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
- MIDI controller

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
