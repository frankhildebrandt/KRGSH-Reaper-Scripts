# REAPER MIDI Pitch Bend Remover

`MIDI Pitch Bend Remover` is a small REAPER JSFX MIDI utility. It removes
incoming Pitch Bend messages on every MIDI channel and passes the remaining
MIDI stream through unchanged.

## Manual installation

1. In REAPER, open `Options` > `Show REAPER resource path in explorer/finder`.
2. Copy `Effects/MIDI/MIDI Pitch Bend Remover.jsfx` from this repository into
   the resource path's `Effects` directory. Keeping it in an `MIDI`
   subdirectory is fine.
3. Rescan or reopen REAPER's FX browser if the effect is not listed yet.

The repository layout and JSFX metadata are ready for a ReaPack indexer as
well.

## Input FX use

Add the effect to the track input FX chain when Pitch Bend should be removed
before MIDI is recorded:

1. Arm the MIDI track for recording.
2. Open its track input FX chain.
3. Add `JS: MIDI Pitch Bend Remover`.
4. Record as usual.

Notes, CC messages, sustain pedal events, program changes, and other MIDI
messages are passed through. Only channel Pitch Bend messages are filtered.
