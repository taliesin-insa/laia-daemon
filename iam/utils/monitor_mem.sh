#!/bin/bash
set -e;
[ $# -lt 1 -o $# -gt 2 ] && echo "Usage: ${0##*/} PID [MONITOR_DURATION]" >&2 && exit 1;

n=0;
while true; do
  mem="$(nvidia-smi | gawk -v pid="$1" '$3 == pid{print $(NF - 1)}')"
  [ -z "$mem" ] && exit 0;
  echo "$mem";
  n=$[n+1];
  if [ $# -gt 1 ]; then
    [ "$n" = "$2" ] && exit 0;
  fi;
  sleep 1;
done;
