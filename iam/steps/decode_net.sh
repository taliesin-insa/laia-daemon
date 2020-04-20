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
gpu=1;
height=128;
overwrite=false;
partition="aachen";
help_message="
Usage: ${0##*/} [options] model

Options:
  --batch_size  : (type = integer, default = $batch_size)
                  Batch size for decoding.
  --gpu         : (type = integer, default = $gpu)
                  Select the GPU to use, index starts from 1.
  --height      : (type = integer, default = $height)
                  Use images rescaled to this height.
  --overwrite   : (type = boolean, default = $overwrite)
                  Overwrite previously created files.
  --partition   : (type = string, default = \"$partition\")
                  Select \"aachen\" or \"kws\".
";
source "$(pwd)/utils/parse_options.inc.sh" || exit 1;
[ $# -ne 1 ] && echo "$help_message" >&2 && exit 1;

export CUDA_VISIBLE_DEVICES=$((gpu-1))
gpu=1

model="$1";
model_name="$(basename "$1" .t7)";

for f in "data/lists/lines/$partition/te_h$height.lst" \
	 "data/lists/lines/$partition/va_h$height.lst" \
	 "data/lang/lines/char/$partition/te.txt" \
	 "data/lang/lines/char/$partition/va.txt" \
	 "data/lang/lines/word/$partition/te.txt" \
	 "data/lang/lines/word/$partition/va.txt" \
         "train/syms.txt" \
         "$model"; do
  [ ! -s "$f" ] && echo "ERROR: File \"$f\" does not exist!" >&2 && exit 1;
done;

hasR=0;
if which Rscript &> /dev/null; then hasR=1; fi;
hasComputeWer=0;
if which compute-wer &> /dev/null; then hasComputeWer=1; fi;

[ $hasR -ne 0 -o $hasComputeWer -ne 0 ] ||
echo "WARNING: Neither Rscript or compute-wer were found, so CER/WER won't be computed!" >&2;

mkdir -p "decode/no_lm/"{forms,lines}/{char,word}"/$partition";

tmpf="$(mktemp)";
for p in va te; do
  lines_char="decode/no_lm/lines/char/$partition/${p}_${model_name}.txt";
  lines_word="decode/no_lm/lines/word/$partition/${p}_${model_name}.txt";
  forms_char="decode/no_lm/forms/char/$partition/${p}_${model_name}.txt";
  forms_word="decode/no_lm/forms/word/$partition/${p}_${model_name}.txt";
  # Decode lines
  [ "$overwrite" = false -a -s "$lines_char" ] ||
  ../../laia-decode \
    --batch_size "$batch_size" \
    --symbols_table "train/syms.txt" \
    "$model" "data/lists/lines/$partition/${p}_h$height.lst" > "$lines_char";
  # Get word-level transcript hypotheses for lines
  [ "$overwrite" = false -a -s "$lines_word" ] ||
  gawk '{
    printf("%s ", $1);
    for (i=2;i<=NF;++i) {
      if ($i == "<space>")
        printf(" ");
      else
        printf("%s", $i);
    }
    printf("\n");
  }' "$lines_char" > "$lines_word";
  # Get form char-level transcript hypothesis
  [ "$overwrite" = false -a -s "$forms_char" ] ||
  gawk '{
    if (match($1, /^([^ ]+)-[0-9]+$/, A)) {
      if (A[1] != form_id) {
        if (form_id != "") printf("\n");
        form_id = A[1];
        $1 = A[1];
        printf("%s", $1);
      } else {
        printf(" %s", "<space>");
      }
      for (i=2; i<= NF; ++i) { printf(" %s", $i); }
    }
  }' "$lines_char" > "$forms_char";
  # Get form word-level transcript hypothesis
  [ "$overwrite" = false -a -s "$forms_word" ] ||
  gawk '{
    if (match($1, /^([^ ]+)-[0-9]+$/, A)) {
      if (A[1] != form_id) {
        if (form_id != "") printf("\n");
        form_id = A[1];
        $1 = A[1];
        printf("%s", $1);
      }
      for (i=2; i<= NF; ++i) { printf(" %s", $i); }
    }
  }' "$lines_word" > "$forms_word";
  if [ $hasR -eq 1 ]; then
    # Compute CER and WER with Confidence Intervals using R
    ./utils/compute-errors.py \
      "data/lang/lines/char/$partition/${p}.txt" "$lines_char" > "$tmpf";
    ./utils/compute-confidence.R "$tmpf" |
    gawk -v p="$p" '$1 == "%ERR"{
      printf("%CER lines %s: %.2f %s %s %s\n", p, $2, $3, $4, $5); }';
    ./utils/compute-errors.py \
      "data/lang/lines/word/$partition/${p}.txt" "$lines_word" > "$tmpf";
    ./utils/compute-confidence.R "$tmpf" |
    gawk -v p="$p" '$1 == "%ERR"{
      printf("%WER lines %s: %.2f %s %s %s\n", p, $2, $3, $4, $5); }';
    ./utils/compute-errors.py \
      "data/lang/forms/char/$partition/${p}.txt" "$forms_char" > "$tmpf";
    ./utils/compute-confidence.R "$tmpf" |
    gawk -v p="$p" '$1 == "%ERR"{
      printf("%CER forms %s: %.2f %s %s %s\n", p, $2, $3, $4, $5); }';
    ./utils/compute-errors.py \
      "data/lang/forms/word/$partition/${p}.txt" "$forms_word" > "$tmpf";
    ./utils/compute-confidence.R "$tmpf" |
    gawk -v p="$p" '$1 == "%ERR"{
      printf("%WER forms %s: %.2f %s %s %s\n", p, $2, $3, $4, $5); }';
  elif [ $hasComputeWer -eq 1 ]; then
    # Compute CER and WER using Kaldi's compute-wer
    compute-wer --text --mode=strict \
      "ark:data/lang/lines/char/$partition/${p}.txt" "ark:$lines_char" \
      2>/dev/null |
    gawk -v p="$p" '$1 == "%WER"{ printf("%CER lines %s: %.2f\n", p, $2); }';
    compute-wer --text --mode=strict \
      "ark:data/lang/lines/word/$partition/${p}.txt" "ark:$lines_word" \
      2>/dev/null |
    gawk -v p="$p" '$1 == "%WER"{ printf("%WER lines %s: %.2f\n", p, $2); }';
    compute-wer --text --mode=strict \
      "ark:data/lang/forms/char/$partition/${p}.txt" "ark:$forms_char" \
      2>/dev/null |
    gawk -v p="$p" '$1 == "%WER"{ printf("%CER forms %s: %.2f\n", p, $2); }';
    compute-wer --text --mode=strict \
      "ark:data/lang/forms/word/$partition/${p}.txt" "ark:$forms_word" \
      2>/dev/null |
    gawk -v p="$p" '$1 == "%WER"{ printf("%WER forms %s: %.2f\n", p, $2); }';
  fi;
done;
