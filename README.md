# REAPER MIDI Pitch Bend Remover / Scale Helper

This repository contains small REAPER JSFX MIDI utilities. The features are
available as separate scripts:

- `MIDI Pitch Bend Remover`: removes incoming Pitch Bend messages.
- `MIDI Scale Helper`: maps MIDI notes to a selected scale.
- `MIDI Sustain Helper`: adds a simple sustain-pedal helper for piano playing.

The original combined `MIDI Pitch Bend Remover / Scale Helper` script is still
included for compatibility.

With Scale Helper enabled, white keys are treated like C major scale degrees
and are remapped to the selected key and scale. For example, when the target is
F major, playing the white keys C-D-E-F-G-A-B outputs F-G-A-Bb-C-D-E. Black
keys are quantized to the nearest note in the selected scale.

## Manual installation

1. In REAPER, open `Options` > `Show REAPER resource path in explorer/finder`.
2. Copy the wanted `.jsfx` files from `Effects/MIDI` into the resource path's
   `Effects` directory. Keeping them in an `MIDI` subdirectory is fine.
3. Rescan or reopen REAPER's FX browser if the effect is not listed yet.

The repository layout and JSFX metadata are ready for a ReaPack indexer as
well.

## Input FX use

Add the effect to the track input FX chain when Pitch Bend should be removed
before MIDI is recorded:

1. Arm the MIDI track for recording.
2. Open its track input FX chain.
3. Add `JS: MIDI Pitch Bend Remover` or the combined
   `JS: MIDI Pitch Bend Remover / Scale Helper`.
4. Record as usual.

## Separate scripts

### MIDI Pitch Bend Remover

- `Remove Pitch Bend`: enables or disables Pitch Bend filtering.

All non-Pitch-Bend MIDI messages pass through unchanged.

### MIDI Scale Helper

- `Scale Helper`: enables or disables MIDI note mapping.
- `Root`: selects the target root note from C through B.
- `Scale`: selects Major, Natural Minor, Harmonic Minor, or Melodic Minor.

When `Scale Helper` is off, notes pass through unchanged. CC messages, Pitch
Bend, program changes, and other MIDI messages pass through unchanged.

### MIDI Sustain Helper

- `Sustain Helper`: adds automatic CC64 sustain-pedal support:
  - `Off`: leaves sustain pedal events unchanged.
  - `Chord Change`: holds sustain while playing and briefly resets the pedal
    when the harmony changes.
  - `Algo`: uses chord-change behavior with extra cleanup for phrase gaps and
    stronger harmonic changes.
  - `Natural`: uses the algorithmic behavior with a tiny re-press delay so
    chord changes feel closer to realistic piano pedaling.

In helper modes, incoming physical CC64 pedal messages still update the helper
state. Other MIDI messages pass through unchanged.

## Combined script controls

The combined `MIDI Pitch Bend Remover / Scale Helper` script exposes all
controls in one FX:

- `Scale Helper`
- `Root`
- `Scale`
- `Remove Pitch Bend`
- `Sustain Helper`
