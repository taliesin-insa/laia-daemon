#!/bin/bash
set -e;
export LC_NUMERIC=C;
export LUA_PATH="$(pwd)/../../?/init.lua;$(pwd)/../../?.lua;$LUA_PATH";

# Directory where the prepare.sh script is placed.
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)";
[ "$(pwd)/steps" != "$SDIR" ] && \
    echo "Please, run this script from the experiment top directory!" >&2 && \
    exit 1;
[ ! -f "$(pwd)/utils/parse_options.inc.sh" ] && \
    echo "Missing $(pwd)/utils/parse_options.inc.sh file!" >&2 && exit 1;

batch_chunk_size=0;
batch_size=16;
continue_train=false;
gpu=1;
linear_dropout=0.5;
overwrite=false;
partition="lines/aachen";
use_distortions=false;
model_name="lstm2d";
help_message="
Usage: ${0##*/} [options]

Options:
  --batch_size  : (type = integer, default = $batch_size)
                  Batch size for training.
  --overwrite   : (type = boolean, default = $overwrite)
                  Overwrite previously created files.
  --partition   : (type = string, default = \"$partition\")
                  Select the \"lines\" or \"sentences\" partition and the lists
                  to use (\"aachen\", \"original\" or \"kws\").
";
source "$(pwd)/utils/parse_options.inc.sh" || exit 1;
[ $# -ne 0 ] && echo "$help_message" >&2 && exit 1;

export CUDA_VISIBLE_DEVICES=$((gpu-1))
gpu=1

# Get "lines" or "sentences" from the full partition string (e.g. lines/aachen)
ptype="${partition%%/*}";

for f in  "data/lists/$partition/tr_150dpi.lst" \
	  "data/lists/$partition/va_150dpi.lst" \
	  "data/lang/char/$partition/tr.txt" \
	  "data/lang/char/$partition/va.txt" \
	  "train/$ptype/syms.txt"; do
  [ ! -s "$f" ] && echo "ERROR: File \"$f\" does not exist!" >&2 && exit 1;
done;

# Get number of symbols
num_syms="$(tail -n1 train/$ptype/syms.txt | awk '{ print $2 }')";

# Create directory
mkdir -p "train/$partition";

# Create model
[ "$overwrite" = false -a "$continue_train" = true -a \
  -s "train/$partition/$model_name.t7" ] ||
./create-model-aachen.lua \
  --maxpool_size 2 2 0 0 0 \
  --log_also_to_stderr info \
  --log_file "train/$partition/$model_name.log" \
  --log_level info \
  1 "$num_syms" "train/$partition/$model_name.t7";

# Train model
../../laia-train-ctc \
  --batch_chunk_size "$batch_chunk_size" \
  --batch_size "$batch_size" \
  --normalize_loss false \
  --continue_train "$continue_train" \
  --use_distortions "$use_distortions" \
  --progress_table_output "train/$partition/$model_name.dat" \
  --early_stop_epochs 20 \
  --learning_rate 0.0003 \
  --log_also_to_stderr info \
  --log_level info \
  --log_file "train/$partition/$model_name.log" \
  --display_progress_bar true \
  --gpu "$gpu" \
  "train/$partition/$model_name.t7" "train/$ptype/syms.txt" \
  "data/lists/$partition/tr_150dpi.lst" \
  "data/lang/char/$partition/tr.txt" \
  "data/lists/$partition/va_150dpi.lst" \
  "data/lang/char/$partition/va.txt";

exit 0;
