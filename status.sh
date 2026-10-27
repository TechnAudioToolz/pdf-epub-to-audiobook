#!/usr/bin/env bash
# Show render progress for every book in work/: current chapter, time used and estimate.
cd "$(dirname "$0")"
date "+%H:%M"
for log in work/*/render.log; do
  [ -f "$log" ] || continue
  book=$(basename "$(dirname "$log")")
  if grep -q '^Wrote' "$log"; then
    echo "DONE     $book"
  elif grep -q 'Traceback' "$log"; then
    echo "FAILED   $book   (see $log)"
  else
    chap=$(grep '^\[' "$log" | tail -1 | tr -d '\r' | cut -c1-70)
    eta=$(grep 'done; elapsed' "$log" | tail -1 | tr -d '\r' | sed 's/^ *done; //')
    echo "RUNNING  $book"
    echo "         ${chap:-loading...}   ${eta}"
  fi
done
