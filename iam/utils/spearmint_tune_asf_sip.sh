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

acoustic_scale_max=10;
acoustic_scale_min=0.1;
exper_name="$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)";
graph_scale_max=1.0
graph_scale_min=1.0
insertion_penalty_max=0.0;
insertion_penalty_min=0.0;
max_finished_jobs=50;
num_procs="$(nproc)";
postprocess_hyps_cmd="";
postprocess_refs_cmd="";
spearmint_main="$HOME/src/Spearmint/spearmint/main.py";
model="";
help_message="
Usage: ${0##*/} [options] refs symb_table wdir lat_rspec1 [lat_rspec2 ...]

Options:
  --acoustic_scale_max    : (type = float, default = $acoustic_scale_max)
  --acoustic_scale_min    : (type = float, default = $acoustic_scale_min)

  --exper_name            : (type = string, default = \"$exper_name\")

  --graph_scale_max       : (type = float, default = $graph_scale_max)
  --graph_scale_min       : (type = float, default = $graph_scale_min)

  --insertion_penalty_max : (type = float, default = $insertion_penalty_max)
  --insertion_penalty_min : (type = float, default = $insertion_penalty_min)

  --max_finished_jobs     : (type = integer, default = $max_finished_jobs)

  --model                 : (type = string, default = \"$model\")
                            If not empty, the given model will be used to obtain
                            the sequence of phones and compute the errors.

  --num_procs             : (type = integer, default = $num_procs)

  --postprocess_hyps_cmd  : (type = string, default = \"$postprocess_hyps_cmd\")
  --postprocess_refs_cmd  : (type = string, default = \"$postprocess_refs_cmd\")

  --spearmint_main         : (type = string, default = \"${spearmint_main}\")

";
. utils/parse_options.inc.sh || exit 1;
[ $# -lt 4 ] && echo "$help_message" >&2 && exit 1;

refs="$(readlink -f "$1")";
symb_table="$(readlink -f "$2")";
wdir="$3";
shift 3;

mkdir -p "$wdir";

for f in "$refs" "$symb_table"; do
  [ ! -s "$f" ] && echo "Error: File \"$f\" does not exist!" >&2 && exit 1;
done;

# Get absolute path of the model
if [ -n "$model" ]; then
  model="$(readlink -f "$model")";
  [ ! -s "$model" ] && echo "Error: File \"$f\" does not exist!" >&2 && exit 1;
fi;

[[ "$graph_scale_min" != "$graph_scale_max" ||
   "$insertion_penalty_min" != "$insertion_penalty_max" ]] &&
comma_after_asf=",";

[[ "$insertion_penalty_min" != "$insertion_penalty_max" ]] &&
comma_after_gsf=",";

cat <<EOF > "$wdir/config.json"
{
  "language" : "PYTHON",
  "main-file" : "exp.py",
  "experiment-name" : "$exper_name",
  "likelihood" : "NOISELESS",
EOF
[ "$max_finished_jobs" -gt 0 ] &&
cat <<EOF >> "$wdir/config.json"
  "max-finished-jobs" : $max_finished_jobs,
EOF
cat <<EOF >> "$wdir/config.json"
  "variables" : {
EOF
[ "$acoustic_scale_min" != "$acoustic_scale_max" ] &&
cat <<EOF >> "$wdir/config.json"
    "asf" : {
      "type" : "FLOAT",
      "size" : 1,
      "min"  : ${acoustic_scale_min},
      "max"  : ${acoustic_scale_max}
    }$comma_after_asf
EOF
[ "$graph_scale_min" != "$graph_scale_max" ] &&
cat <<EOF >> "$wdir/config.json"
    "gsf" : {
      "type" : "FLOAT",
      "size" : 1,
      "min"  : ${graph_scale_min},
      "max"  : ${graph_scale_max}
    }$comma_after_gsf
EOF
[ "$insertion_penalty_min" != "$insertion_penalty_max" ] &&
cat <<EOF >> "$wdir/config.json"
    "sip" : {
      "type" : "FLOAT",
      "size" : 1,
      "min"  : ${insertion_penalty_min},
      "max"  : ${insertion_penalty_max}
    }
EOF
cat <<EOF >> "$wdir/config.json"
  }
}
EOF

cat <<EOF > "$wdir/exp.py"
import subprocess
import tempfile
import multiprocessing
import re
import os

# Worker function
def worker_func(args):
    asf, gsf, sip, lat = args
    output_file = tempfile.NamedTemporaryFile(delete=False)
    print lat, output_file.name
    lattice_scale_args = [
      'lattice-scale',
      '--acoustic-scale=%f' % asf,
      lat,
      'ark:-'
    ]
    lattice_add_penalty_args = [
      'lattice-add-penalty',
      '--word-ins-penalty=%f' % sip,
      'ark:-',
      'ark:-',
    ]
    lattice_best_path_args = [
      'lattice-best-path',
      'ark:-',
EOF
if [ -n "$model" ]; then
  cat <<EOF >> "$wdir/exp.py"
      'ark:/dev/null',
      'ark:|ali-to-phones "$model" ark:- ark,t:-|$PWD/utils/int2sym.pl -f 2- $symb_table'
EOF
else
  cat <<EOF >> "$wdir/exp.py"
      'ark,t:|$PWD/utils/int2sym.pl -f 2- $symb_table',
      'ark:/dev/null'
EOF
fi;
cat <<EOF >> "$wdir/exp.py"
    ]
    p1 = subprocess.Popen(lattice_scale_args, stdout=subprocess.PIPE)
    p2 = subprocess.Popen(lattice_add_penalty_args,
                          stdin=p1.stdout, stdout=subprocess.PIPE)
    p3 = subprocess.Popen(lattice_best_path_args, stdin=p2.stdout,
                          stdout=output_file)
    p3.communicate()
    output_file.close()
    return output_file.name

def main(job_id, params):
  asf = float(params['asf']) if 'asf' in params else $acoustic_scale_min
  gsf = float(params['gsf']) if 'gsf' in params else $graph_scale_min
  sip = float(params['sip']) if 'sip' in params else $insertion_penalty_min
  input_lats = [ $(printf "'%s', " "$@") ]

  pool = multiprocessing.Pool(processes=${num_procs})
  output_txt = pool.imap(worker_func,
                         map(lambda x: (asf, gsf, sip, x), input_lats))

  # Return WER/CER
  compute_wer_stdout = subprocess.check_output([
    'compute-wer',
    '--mode=all',
    '--text',
    'ark:cat $refs |$postprocess_refs_cmd',
    'ark:cat %s |$postprocess_hyps_cmd' % ' '.join(output_txt)
  ])
  error = float(re.search(r'%WER ([0-9.]+)', compute_wer_stdout).group(1))
  # Remove temporal files
  for f in output_txt:
    os.remove(f)
  return error
EOF

python "$spearmint_main" "$wdir" || exit 1;
