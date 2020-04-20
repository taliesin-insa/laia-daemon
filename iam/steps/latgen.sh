#!/bin/bash
set -e;
export LC_NUMERIC=C;

# Directory where the prepare.sh script is placed.
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)";
[ "$(pwd)/steps" != "$SDIR" ] &&
echo "Please, run this script from the experiment top directory!" >&2 &&
exit 1;
[ ! -f "$(pwd)/utils/parse_options.inc.sh" ] &&
echo "Missing $(pwd)/utils/parse_options.inc.sh file!" >&2 && exit 1;

acoustic_scale=1;
beam=100;
lattice_beam=30;
max_active=200000;
max_mem=1000000000;
minimize=true;
overwrite=false;
prune_interval=100;
num_jobs=1;
qsub_opts="-l h_rt=24:00:00,h_vmem=4G";
symbol_table="";
help_message="
Usage: ${0##*/} [options] mdl HCL G data_scp output_dir

Options:
  --acoustic_scale      : (float, default = $acoustic_scale)
                          Scaling factor for acoustic likelihoods.
  --beam                : (float, default = $beam)
                          Decoding beam.
  --lattice_beam        : (float, default = $lattice_beam)
                          Lattice generation beam.
  --max_active          : (integer, default = $max_active)
                          Decoder maximum number of active states.
  --max_mem             : (integer, default = $max_mem)
                          Maximum approximate memory usage in determinization
                          (real usage might be many times this).
  --minimize            : (boolean, default = $minimize)
                          If true, push and minimize after determinization.
  --num_jobs            : (integer, default = $num_jobs)
                          Launch this number of qsub jobs.
  --overwrite           : (boolean, default = $overwrite)
                          Overwrite existing files from previous runs.
  --qsub_opts           : (string, default = \"$qsub_opts\")
                          Options for qsub.
  --prune_interval      : (integer, default = $prune_interval)
                          Interval (in frames) at which to prune tokens.
  --symbol_table        : (string, default = \"$symbol_table\")
                          Symbol table for for debug output.
";
. utils/parse_options.inc.sh || exit 1;
. utils/functions.inc.sh || exit 1;
[ $# -ne 5 ] && echo "$help_message" >&2 && exit 1;

model="$1";
HCL="$2";
G="$3";
data_scp="$4";
wdir="$5";

[ "$num_jobs" -le 0 ] && error "--num_jobs must be a positive integer!";
[ ! -f "$data_scp" ] && error "File \"$data_scp\" not found!";

check_execs parallel-kaldi-latgen-lazylm;

if [ "$num_jobs" -gt 1 ]; then
  num_samples="$(wc -l "$data_scp" | cut -d\  -f1)";
  [ "$num_samples" -lt "$num_jobs" ] && num_jobs="$num_samples";
  d="$[num_samples / num_jobs]";
  r="$[num_samples % num_jobs]";
  p=0;
  feas=();
  for i in $(seq 1 "$num_jobs"); do
    # n = number of samples to process by job i
    if [ "$i" -le "$r" ]; then n="$[d + 1]"; else n="$d"; fi;
    # p = number of samples processed by all jobs, including job i
    p=$[p+n];
    feas+=("scp:head -n $p \"$data_scp\"|tail -n $n|" );
  done;
else
  feas=("scp:$data_scp");
fi;

parallel-kaldi-latgen-lazylm2 \
  --acoustic_scale "$acoustic_scale" \
  --beam "$beam" \
  --lattice_beam "$lattice_beam" \
  --max_active "$max_active" \
  --max_mem "$max_mem" \
  --prune_interval "$prune_interval" \
  --overwrite "$overwrite" \
  --word_symbol_table "$symbol_table" \
  --qsub true \
  --qsub_opts "-o \"/SCRATCH/$USER\" -j y $qsub_opts" \
  --max_mem "$max_mem" \
  "$model" "$HCL" "$G" "${feas[@]}" "$wdir";
