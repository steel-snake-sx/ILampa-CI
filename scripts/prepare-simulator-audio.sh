#!/bin/bash
# Headless macOS CI prerequisite, never part of the app. A simulator still uses
# host CoreAudio; an unavailable HAL route can hang media preparation/currentTime.
set -euo pipefail
OUT="$PWD/build/concurrency-tests"
mkdir -p "$OUT"
system_profiler SPAudioDataType > "$OUT/host-audio-before.log"
brew install switchaudio-osx
brew install --cask blackhole-2ch
# Load the newly installed HAL driver before any simulator is booted.
sudo killall coreaudiod
SwitchAudioSource -a > "$OUT/host-audio-devices.log"
SwitchAudioSource -t input -s 'BlackHole 2ch'
SwitchAudioSource -t output -s 'BlackHole 2ch'
SwitchAudioSource -t system -s 'BlackHole 2ch'
test "$(SwitchAudioSource -c -t input)" = 'BlackHole 2ch'
test "$(SwitchAudioSource -c -t output)" = 'BlackHole 2ch'
system_profiler SPAudioDataType > "$OUT/host-audio-after.log"
printf 'Verified host input/output route: BlackHole 2ch\n' | tee "$OUT/host-audio-verification.log"
