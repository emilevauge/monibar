#!/bin/sh
# Debug: renders the panel to a PNG.
# Usage: ./snapshot.sh panel.png [--light]
set -eu
panel="$1"; shift
fifo="$(mktemp -u)"; mkfifo "$fifo"
build/Monibar.app/Contents/MacOS/Monibar --snapshot "$@" > "$fifo" &
read -r wid < "$fifo"; rm "$fifo"
sleep 0.5
screencapture -x -o -l "$wid" "$panel"
wait
