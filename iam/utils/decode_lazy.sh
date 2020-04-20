#!/bin/bash
set -e;
export LC_NUMERIC=C;

# Directory where the decode_lazy.sh script is placed.
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)";
[ "$(pwd)/utils" != "$SDIR" ] &&
echo "Please, run this script from the experiment top directory!" >&2 &&
exit 1;
[ ! -f "$(pwd)/utils/parse_options.inc.sh" ] &&
echo "Missing $(pwd)/utils/parse_options.inc.sh file!" >&2 && exit 1;

acoustic_scale=1;
allow_partial=true;
beam=16;
max_active=2147483647;
min_active=20;
num_procs="$(nproc)";
num_tasks="$(nproc)";
overwrite=false;
qsub_opts="";
symbol_table="";
tasks="";
help_message="
Usage: ${0##*/} [options] mdl HCL G data_scp output_dir

Description:
  Decode, reading log-likelihoods as matrices and doing the composition of HCL
  and G on-the-fly. You can use this decoder to perform decoding using large
  grammars (i.e. large n-gram LMs).

  This is a wrapper around decode-lazylm-faster-mapped that makes easier to
  launch the decoding on a large number of samples in parallel (either locally
  or using SGE).

Options:
  --acoustic_scale : (float, default = $acoustic_scale)
                     Scaling factor for acoustic likelihoods.
  --allow_partial  : (boolean, default = $allow_partial)
                     Produce output even when final state was not reached.
  --beam           : (float, default = $beam)
                     Decoding beam.
  --max_active     : (integer, default = $max_active)
                     Decoder maximum number of active states.
  --min_active     : (integer, default = $min_active)
                     Decoder min active states (don't prune if #active < min).
  --num_procs      : (integer, default = $num_procs)
                     Maximum number of tasks to run in parallel in the host
                     computer (this maximum does not apply when using qsub).
  --num_tasks      : (integer, default = $num_tasks)
                     Divide the input scp in this number of independent tasks.
                     If --qsub_opts is given, these tasks will be executed in
                     parallel using SGE. If not, --num_procs processes will be
                     used in the local computer to process the tasks.
  --overwrite      : (boolean, default = $overwrite)
                     Overwrite existing files from previous runs.
  --qsub_opts      : (string, default = \"$qsub_opts\")
                     Options for qsub.
  --symbol_table   : (string, default = \"$symbol_table\")
                     Symbol table for for debug output.
  --tasks          : (string, default = \"$tasks\")
                     Range of tasks to execute. If not given, the range is set
                     automatically.
";
source utils/parse_options.inc.sh || exit 1;
[ $# -ne 5 ] && echo "$help_message" >&2 && exit 1;

function wait_background_jobs () {
  local j=0;
  for j in $(seq 1 $#); do wait "${!j}" || return "$j"; done
  return 0;
}

model="$1";
HCL="$2";
G="$3";
data_scp="$4";
wdir="$5";

which decode-lazylm-faster-mapped &> /dev/null ||
{ echo "ERROR: decode-lazylm-faster-mapped not found!" >&2 && exit 1; }

for f in "$model" "$HCL" "$G" "$data_scp"; do
  [ ! -s "$f" ] && echo "ERROR: File \"$f\" was not found!" >&2 && exit 1;
done;

mkdir -p "$wdir";

# Split input scp
if [ "$num_tasks" -gt 1 ]; then
  num_samples="$(wc -l "$data_scp" | cut -d\  -f1)";
  [ "$num_samples" -lt "$num_tasks" ] && num_tasks="$num_samples";
  d="$[num_samples / num_tasks]";
  r="$[num_samples % num_tasks]";
  p=0;
  feas=();
  for i in $(seq 1 "$num_tasks"); do
    # n = number of samples to process by job i
    if [ "$i" -le "$r" ]; then n="$[d + 1]"; else n="$d"; fi;
    # p = number of samples processed by all jobs, including job i
    p=$[p+n];
    feas+=("scp:head -n $p \"$data_scp\"|tail -n $n|" );
  done;
else
  feas=("scp:$data_scp");
fi;

if [ -z "$tasks" ]; then
  # Check previous results, in order to avoid re-doing work.
  pending_tasks=();
  for i in $(seq 1 ${#feas[@]}); do
    task_desc="$(printf "%05d.of.%05d" $i ${#feas[@]})";
    owrd="$wdir/words.$task_desc.ark.gz";
    oali="$wdir/align.$task_desc.ark.gz";
    log="$wdir/decode-lazylm-faster-mapped.$task_desc.log";
    [[ "$overwrite" = false && -s "$owrd" && -s "$oali" ]] &&
    grep -s -q "Finished decode-lazylm-faster-mapped" "$log" && continue;
    pending_tasks+=("$i");
    # Remove previous temporal results.
    rm -f "$owrd" "$oali";
  done;
  if [ ${#pending_tasks[@]} -eq 0 ]; then
    # No pending features to process. Exit normally.
    echo "No decoding, found all transcripts and alignments in \"$wdir\"" >&2;
    exit 0;
  else
    # SGE only admits continuous ranges, so relaunch all tasks between the
    # first pending and the latest. Notice that later, some code is added to the
    # tasks' script so that completed tasks do not re-do the job again.
    tasks="${pending_tasks[0]}-${pending_tasks[@]:(-1)}";
  fi;
else
  range=( $(echo "$tasks" | sed -r 's|^([0-9]+)(-([0-9]+))?$|\1 \3|g') );
  if [ ${#range[@]} -eq 1 ]; then
    pending_tasks=( ${range[0]} );
  else
    pending_tasks=( $(seq ${range[0]} ${range[1]}) );
  fi;
  [ -z "$pending_tasks" ] &&
  echo "You did not specified a valid task range: \"$tasks\"!" >&2 &&
  exit 1;
fi;

task_script="$(mktemp)";
cat <<EOF > "$task_script";
#!/bin/bash
#$ -cwd
#$ -t $tasks
#$ ${qsub_opts}
set -e;
export LC_NUMERIC=C;

task_desc="\$(printf "%05d" \${SGE_TASK_ID}).of.\$(printf "%05d" ${#feas[@]})";
mapfile -O 1 -t feas <<< "$(printf "%s\n" "${feas[@]}")";
inp_fea="\${feas[SGE_TASK_ID]}";
owrd="$wdir/words.\$task_desc.ark.gz";
oali="$wdir/align.\$task_desc.ark.gz";
log="$wdir/decode-lazylm-faster-mapped.\$task_desc.log";

# Avoid re-doing completed tasks in the range.
[[ "$overwrite" = false && -s "\$owrd" && -s "\$oali" ]] &&
grep -s -q "Finished decode-lazylm-faster-mapped" "\$log" &&
exit 0;

# Launch decode-lazylm-faster-mapped
(
  date "+%F %T - Started decode-lazylm-faster-mapped" && \\
  ${SDIR}/memusg decode-lazylm-faster-mapped \\
    --acoustic-scale="$acoustic_scale" \\
    --allow-partial="$allow_partial" \\
    --beam="$beam" \\
    --max-active="$max_active" \\
    --min-active="$min_active" \\
    --word-symbol-table="$symbol_table" \\
   "$model" "$HCL" "$G" "\$inp_fea" \\
   "ark:|gzip -c -9 > \$owrd" "ark:|gzip -c -9 > \$oali" && \\
  date "+%F %T - Finished decode-lazylm-faster-mapped";
) &> "\$log" ||
{ echo "ERROR: Failed decode-lazylm-faster-mapped, see \$log" && exit 1; }
EOF

if [ -n "$qsub_opts" ]; then
  which qsub &> /dev/null ||
  { echo "ERROR: qsub was not found in your PATH!" >&2 && exit 1; }
  qsub -terse "$task_script" | tail -n1 | sed 's/\..*$//g' ||
  { echo "ERROR: qsub submission failed!" >&2 && exit 1; }
else
  bg_procs=();
  for i in ${pending_tasks[@]}; do
    SGE_TASK_ID="$i" bash "$task_script" &
    bg_procs+=("$!");
    [[ "$[${#bg_procs[@]} % num_procs]" -eq 0 ]] && {
      wait_background_jobs "${bg_procs[@]}" || exit 1;
      bg_procs=();
    }
  done;
  wait_background_jobs "${bg_procs[@]}" || exit 1;
fi;
