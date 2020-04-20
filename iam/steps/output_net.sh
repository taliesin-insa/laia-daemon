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

batch_size=16;
height=128;
overwrite=false;
partition=aachen;
prior_scale=0.2;
help_message="
Usage: ${0##*/} [options] model

Options:
  --batch_size      : (type = integer, default = $batch_size)
                      Batch size for Laia.
  --height          : (type = integer, default = $height)
                      Use images rescaled to this height.
  --overwrite       : (type = boolean, default = $overwrite)
                      Overwrite previous files.
  --partition       : (type = string, default = \"$partition\")
                      Select the the lists to use: \"aachen\" or \"kws\".
  --prior_scale     : (type = float, default = $prior_scale)
                      Use this scale factor on the label priors to convert the
                      softmax output of the neural network into likelihoods.
";
source utils/parse_options.inc.sh || exit 1;
[ $# -ne 1 ] && echo "$help_message" >&2 && exit 1;
model="$1";
model_name="$(basename "$1" .t7)";

# Check required files
for f in "train/syms.txt" "$model" \
         "data/lists/lines/$partition/tr_h${height}.lst" \
         "data/lists/lines/$partition/va_h${height}.lst" \
         "data/lang/lines/char/$partition/tr.txt"; do
  [ ! -s "$f" ] && echo "ERROR: File \"$f\" was not found!" >&2 && exit 1;
done;

# Do forced alignment to obtain the label priors.
[ "$overwrite" = false -a -s "${model/.t7/.prior}" ] || {
  echo "Forced alignment can take a while..." >&2 &&
  ../../laia-force-align --batch_size "$batch_size" \
    "$model" "train/syms.txt" "data/lists/lines/$partition/tr_h$height.lst" \
    "data/lang/lines/char/$partition/tr.txt" /dev/null "${model/.t7/.prior}"
}

# Compute log-likelihoods from the network.
mkdir -p decode/lkh/$partition/{lines,forms};
for p in va te; do
  ark="decode/lkh/$partition/lines/${p}_${model_name}_ps${prior_scale}.ark";
  scp="decode/lkh/$partition/lines/${p}_${model_name}_ps${prior_scale}.scp";
  # LINES log-likelihoods
  [ "$overwrite" = false -a -s "$ark" -a -s "$scp" ] ||
  ../../laia-netout \
    --batch_size "$batch_size" \
    --prior "${model/.t7/.prior}" \
    --prior_alpha "$prior_scale" \
    "$model" "data/lists/lines/$partition/${p}_h${height}.lst" /dev/stdout |
  copy-matrix ark:- "ark,scp:$ark,$scp";
  # FORMS log-likelihoods
  [ "$overwrite" = false -a -s "${ark/lines/forms}" ] ||
  ./utils/join_lines_arks.sh --add_wspace_border true \
    "train/syms.txt" "$ark" "${ark/lines/forms}";
done;

exit 0;
