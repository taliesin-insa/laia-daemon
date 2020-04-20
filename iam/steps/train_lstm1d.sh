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
cnn_batch_norm=true;
cnn_dropout="0 0 0.2 0.2 0.2";
cnn_maxpool_size="2,2 2,2 2,2 0 0";
cnn_num_features="16 32 48 64 80";
cnn_type=leakyrelu;
continue_train=false;
early_stop_epochs=80;
gpu=1;
height=128;
learning_rate=0.0003;
linear_dropout=0.5;
model_name="lstm1d_h${height}";
overwrite=false;
partition="aachen";
rnn_num_layers=5;
rnn_num_units=256;
rnn_dropout=0.5;
use_distortions=true;
help_message="
Usage: ${0##*/} [options]

Options:
  --batch_chunk_size  : (type = integer, default = $batch_chunk_size)
                        If >0, split the batch in chunks of this size (in MB).
                        Useful to perform constant batch size updates with
                        scarce memory.
  --batch_size        : (type = integer, default = $batch_size)
                        Batch size for training.
  --cnn_batch_norm    : (type = boolean list, default = \"$cnn_batch_norm\")
                        Batch normalization before the activation in each conv
                        layer.
  --cnn_dropout       : (type = double list, default = \"$cnn_dropout\")
                        Dropout probability at the input of each conv layer.
  --cnn_maxpool_size  : (type = integer list, default = \"$cnn_maxpool_size\")
                        MaxPooling size after each conv layer. Separate each
                        dimension with commas (order: width,height).
  --cnn_num_features  : (type = integer list, default = \"$cnn_num_features\")
                        Number of feature maps in each conv layer.
  --cnn_type          : (type = string list, default = \"$cnn_type\")
                        Type of the activation function in each conv layer,
                        valid types are \"relu\", \"tanh\", \"prelu\",
                        \"rrelu\", \"leakyrelu\", \"softplus\".
  --continue_train    : (type = boolean, default = $continue_train)
                        If true (and overwrite = true), the training will
                        continue from the latest saved checkpoint.
  --early_stop_epochs : (type = integer, default = $early_stop_epochs)
                        If n>0, stop training after this number of epochs
                        without a significant improvement in the validation CER.
                        If n=0, early stopping will not be used.
  --gpu               : (type = integer, default = $gpu)
                        Select which GPU to use, index starts from 1.
  --height            : (type = integer, default = $height)
                        Use images rescaled to this height.
  --learning_rate     : (type = float, default = $learning_rate)
                        Learning rate from RMSProp.
  --linear_dropout    : (type = float, default = $linear_dropout)
                        Dropout probability at the input of the final linear
                        layer.
  --model_name        : (type = string, default = \"$model_name\")
                        Use this name to save the trained model.
  --overwrite         : (type = boolean, default = $overwrite)
                        Overwrite previously created files.
  --partition         : (type = string, default = \"$partition\")
                        Select the the lists to use: \"aachen\" or \"kws\".
  --rnn_num_layers    : (type = integer, default = $rnn_num_layers)
                        Number of recurrent layers.
  --rnn_num_units     : (type = integer, default = $rnn_num_units)
                        Number of units in the recurrent layers.
  --rnn_dropout       : (type = float, default = $rnn_dropout)
                        Dropout probability at the input of each recurrent
                        layer.
  --use_distortions   : (type = boolean, default = $use_distortions)
                        If true, augment the training set using random
                        distortions.
";
source "$(pwd)/utils/parse_options.inc.sh" || exit 1;
[ $# -ne 0 ] && echo "$help_message" >&2 && exit 1;

export CUDA_VISIBLE_DEVICES=$((gpu-1))
gpu=1

for f in  "data/lists/lines/$partition/te_h$height.lst" \
	  "data/lists/lines/$partition/tr_h$height.lst" \
	  "data/lists/lines/$partition/va_h$height.lst" \
	  "data/lang/lines/char/$partition/tr.txt" \
	  "data/lang/lines/char/$partition/va.txt" \
	  "train/syms.txt"; do
  [ ! -s "$f" ] && echo "ERROR: File \"$f\" does not exist!" >&2 && exit 1;
done;

# Get number of symbols
num_syms="$(tail -n1 train/syms.txt | gawk '{ print $2 }')";

# Create directory
mkdir -p "train/$partition";

if [[ "$overwrite" = true || ( ! -s "train/$partition/$model_name.t7" ) ]]; then
  # Create model
  [ "$continue_train" = true -a -s "train/$partition/$model_name.t7" ] ||
  laia-docker create-model \
    --cnn_batch_norm $cnn_batch_norm \
    --cnn_dropout $cnn_dropout \
    --cnn_kernel_size 3 \
    --cnn_maxpool_size $cnn_maxpool_size \
    --cnn_num_features $cnn_num_features \
    --cnn_type $cnn_type \
    --rnn_dropout "$rnn_dropout" \
    --rnn_num_layers "$rnn_num_layers" \
    --rnn_num_units "$rnn_num_units" \
    --linear_dropout "$linear_dropout" \
    --log_also_to_stderr info \
    --log_file "train/$partition/$model_name.log" \
    --log_level info \
    1 "$height" "$num_syms" "train/$partition/$model_name.t7";

  # Train model
  laia-docker train-ctc \
    --batch_chunk_size "$batch_chunk_size" \
    --batch_size "$batch_size" \
    --normalize_loss false \
    --continue_train "$continue_train" \
    --use_distortions "$use_distortions" \
    --progress_table_output "train/$partition/$model_name.dat" \
    --early_stop_epochs "$early_stop_epochs" \
    --learning_rate "$learning_rate" \
    --log_also_to_stderr info \
    --log_level info \
    --log_file "train/$partition/$model_name.log" \
    --display_progress_bar true \
    --gpu "$gpu" \
    "train/$partition/$model_name.t7" "train/syms.txt" \
    "data/lists/lines/$partition/tr_h${height}.lst" \
    "data/lang/lines/char/$partition/tr.txt" \
    "data/lists/lines/$partition/va_h${height}.lst" \
    "data/lang/lines/char/$partition/va.txt";
fi;

exit 0;
