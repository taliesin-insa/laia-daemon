#!/bin/bash
set -e;
export LC_NUMERIC=C;

# Directory where the prepare.sh script is placed.
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)";
[ "$(pwd)/utils" != "$SDIR" ] &&
echo "Please, run this script from the experiment top directory!" >&2 &&
exit 1;
[ ! -f "$(pwd)/utils/parse_options.inc.sh" ] &&
echo "Missing $(pwd)/utils/parse_options.inc.sh file!" >&2 && exit 1;

acoustic_scale=1;
graph_scale=1;
symbols_table="";
insertion_penalty=0;
num_procs="$(nproc)";
help_message="
Usage: ${0##*/} [options] lat_rspec1 [lat_rspec2 ...]

Options:
  --acoustic_scale    : (type = float, default = $acoustic_scale)

  --graph_scale       : (type = float, default = $graph_scale)

  --insertion_penalty : (type = float, default = $insertion_penalty)

  --num_procs         : (type = integer, default = $num_procs)

  --symbols_table     : (type = string, default = $symbols_table)

";
. utils/parse_options.inc.sh || exit 1;
[ $# -lt 1 ] && echo "$help_message" >&2 && exit 1;

lats=();
while [ $# -gt 0 ]; do
  if [[ "${1:0:4}" = "ark:" || "${1:0:4}" = "scp:" ]]; then
    lats+=("$1");
  else
    if [ "${1:(-3)}" = ".gz" ]; then
      lats+=("ark:zcat $1|");
    elif [ "${1:(-4)}" = ".bz2" ]; then
      lats+=("ark:bzcat $1|");
    else
      lats+=("ark:cat $1|");
    fi;
  fi
  shift 1;
done;

outfiles=(); logfiles=(); procs=();
for lat in "${lats[@]}"; do
  out="$(mktemp)"; log="$(mktemp)";
  outfiles+=("$out"); logfiles+=("$log");
  (
    (
      lattice-scale \
        --acoustic-scale="$acoustic_scale" \
        --lm_scale="$graph_scale" \
        "$lat" ark:- |
      lattice-add-penalty \
        --word-ins-penalty="$insertion_penalty" \
        ark:- ark:- |
      lattice-best-path \
        ark:- "ark,t:$out"
    ) 2> "$log" ||
    ( echo "ERROR: Failed \"$lat\", see log $log!" >&2 && exit 1; )
  ) &
  procs+=($!);
  if [[ $[${#procs[@]} % num_procs] -eq 0 ]]; then wait ${procs[@]}; procs=(); fi;
done;
if [[ ${#procs[@]} -gt 0 ]]; then wait ${procs[@]}; procs=(); fi;

# Map integers to symbols, if the symbols table is given
if [ -f "$symbols_table" ]; then
  sort -V -k1 "${outfiles[@]}" | ./utils/int2sym.pl -f 2- "$symbols_table";
else
  sort -V -k1 "${outfiles[@]}";
fi;

rm -rf "${outfiles[@]}" "${logfiles[@]}";

exit 0;
