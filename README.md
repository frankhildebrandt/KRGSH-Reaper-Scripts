# KRGSH REAPER FX

This repository contains small REAPER JSFX MIDI utilities and workflow scripts
by KRGSH:

- `MIDI Pitch Bend Remover`: removes incoming Pitch Bend messages.
- `MIDI Scale Helper`: maps MIDI notes to a selected scale.
- `MIDI Sustain Helper`: adds a simple sustain-pedal helper for piano playing.
- `MIDI FX Chain Knob Mapper`: maps 8 relative MIDI knobs to parameters in the
  selected track's FX chain.
- `Loop Composer`: provides ReaScript actions for fixed-length loop-block
  recording, overdubbing, progression, and navigation.

With Scale Helper enabled, white keys are treated like C major scale degrees
and are remapped to the selected key and scale. For example, when the target is
F major, playing the white keys C-D-E-F-G-A-B outputs F-G-A-Bb-C-D-E. Black
keys are quantized to the nearest note in the selected scale.

## ReaPack installation

Import this repository in ReaPack:

```text
https://github.com/frankhildebrandt/KRGSH-Reaper-Scripts/raw/main/index.xml
```

The ReaPack index is maintained automatically by GitHub Actions whenever changes
are pushed to `main`. Pull requests validate the package metadata before merge.

## Manual installation

1. In REAPER, open `Options` > `Show REAPER resource path in explorer/finder`.
2. Copy the wanted `.jsfx` files from `MIDI` into the resource path's
   `Effects/MIDI` directory.
3. Copy the wanted `.lua` files from `Scripts` into the resource path's
   `Scripts` directory.
4. Rescan or reopen REAPER's FX browser if the effect is not listed yet.
5. Add Lua scripts through `Actions` > `Show action list` > `New action` >
   `Load ReaScript`.

For Loop Composer, keep the files in `Scripts/Loop Composer` together because
the action scripts load shared internal modules from the same directory.

The repository layout and JSFX metadata are ready for the ReaPack indexer as
well.

## Input FX use

Add the effect to the track input FX chain when Pitch Bend should be removed
before MIDI is recorded:

1. Arm the MIDI track for recording.
2. Open its track input FX chain.
3. Add `JS: MIDI Pitch Bend Remover`.
4. Record as usual.

## Separate scripts

### Loop Composer

Loop Composer is a ReaScript action set for writing in fixed loop blocks.

Available actions:

- `Loop Composer - Set length to 4 bars`
- `Loop Composer - Set length to 8 bars`
- `Loop Composer - Set length to 16 bars`
- `Loop Composer - Set length to 32 bars`
- `Loop Composer - Set length to 64 bars`
- `Loop Composer - Start loop recording`
- `Loop Composer - Start loopstation mode`
- `Loop Composer - Queue loopstation recording`
- `Loop Composer - Stop loopstation recording`
- `Loop Composer - Replace and queue loopstation recording`
- `Loop Composer - Open view`
- `Loop Composer - Set current loop block from edit cursor`
- `Loop Composer - Go to previous loop block`
- `Loop Composer - Go to next loop block`
- `Loop Composer - Create next loop block from current`
- `Loop Composer - Install standard toolbar`

The selected loop length and current block start are stored per project. The
active block is represented by REAPER's loop points and time selection.

`Start loop recording` records into the current block from the block start,
stops automatically at the selected maximum length, and normalizes early
recordings to the largest fitting musical length (`1` or `2` beats, then `1`,
`2`, `4`, `8`, `16`, `32`, or `64` bars). New MIDI and audio items are glued to
that length and source-looped to fill the block. MIDI record-dub starts directly
at the block start; if the target block does not contain a MIDI clip yet, Loop
Composer creates an empty one before recording starts. Notes held before the
loop starts are inserted as note-on events at the block start. If a recorded
MIDI item or its first played note begins after the block start, normalization
inserts leading silence into the loop source so playback stays aligned without
moving notes to PPQ 0. Existing items are left alone, so overdubs remain
editable as separate items or lanes.

`Start loopstation mode` keeps the current block looping in playback. While it
runs, `Queue loopstation recording` arms the next pass: recording starts only
when playback reaches the loop start, records one block, then returns to normal
playback so the loop keeps running. `Stop loopstation recording` ends only the
current loopstation recording pass, applies the same cut-and-repeat
normalization as early stopping, and leaves loopstation playback running.
`Replace and queue loopstation recording` removes the most recent loopstation
take from the current block and immediately queues a new pass at the next loop
start.

`Create next loop block from current` copies all items that intersect the
current block into the next block, moves the edit cursor there, and updates the
loop points. `Go to previous loop block` and `Go to next loop block` navigate
without copying content, including to empty blocks.

`Open view` opens a dockable Loop Composer control surface. It remembers its
dock or floating state per project and provides full loop transport controls:
play, pause, stop, record, repeat, block start/end jumps, previous/next block,
block recording, loop application, loopstation controls, block creation, and
SWS zoom. Playback and recording states are animated in the view.

Right-clicking a map-ready control opens a context menu with `MIDI learn` and
`Reset MIDI mapping`. Learned MIDI CC or note mappings are stored per project
and trigger the same action as clicking the control. The context menu is also
used for track slots, so individual target track loopstation buttons can be
triggered from MIDI.

The view can store target tracks from the current REAPER track selection without
changing track arm state. When target tracks are used for recording, Loop
Composer arms and selects the active recording targets, then restores the
previous track selection and arm states after the pass. `Dub` enables MIDI
record-dub mode for those target tracks by setting their REAPER record mode to
`Record: MIDI overdub`; audio recording remains in normal item recording and is
not moved into takes or fixed lanes.

Target tracks are shown as two-column loopstation buttons. Clicking or
MIDI-triggering a target track selects and arms only that track, then queues a
loopstation recording pass for it. Triggering a target button again while a pass
is queued or recording requests the recording stop and leaves loopstation
playback running.

`Install standard toolbar` creates `Loop Composer Toolbar.ReaperMenu` in the
REAPER resource path, installs the included toolbar icons, and tells you where
to import it from `Options` > `Customize menus/toolbars` > `Import`.

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

### MIDI FX Chain Knob Mapper

`MIDI FX Chain Knob Mapper` is a hybrid JSFX and ReaScript controller for the
Akai MPK mini plus knobs in relative mode:

- The JSFX receives CC16 through CC23, shows an 8-knob UI in the FX chain, and
  passes all MIDI through unchanged.
- The companion `MIDI FX Chain Knob Mapper` ReaScript opens the assignment UI,
  inserts the mapper JSFX on the selected track if needed, and maps each knob to
  one parameter in that track's FX chain.
- Click an FX field to choose the target FX, then click the parameter field to
  choose the target parameter.
- Click `Learn`, move one FX parameter in the selected track's FX chain, and the
  slot assigns itself to that changed parameter. Use `-` and `+` to adjust
  per-knob sensitivity.

Set the MPK mini plus knobs to relative `1/127` mode. Values 1 through 63 nudge
the mapped parameter upward, and values 65 through 127 nudge it downward.
