#!/bin/bash
set -e;
export LC_NUMERIC=C;

# Directory where this script is located.
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)";
[ "$(pwd)/steps" != "$SDIR" ] && \
    echo "Please, run this script from the experiment top directory!" >&2 && \
    exit 1;
[ ! -f "$(pwd)/utils/parse_options.inc.sh" ] && \
    echo "Missing $(pwd)/utils/parse_options.inc.sh file!" >&2 && exit 1;

# Utility function to compute the errors
function compute_errors () {
  [ $# -ne 2 ] && echo "Usage: compute_errors forms_char forms_word" >&2 && return 1;
  ref_char="data/lang/forms/char/$partition/$p.txt";
  ref_word="data/lang/forms/word/$partition/$p.txt";
  # Some checks
  nc=( $(wc -l "$ref_char" "$1" | head -n2 | gawk '{print $1}') );
  nw=( $(wc -l "$ref_word" "$2" | head -n2 | gawk '{print $1}') );
  [[ "${nc[0]}" -eq "${nc[1]}" ]] ||
  echo "WARNING: The number of reference forms does not match your char-level" \
    "hypothesis (${nc[0]} vs. ${nc[1]})" >&2
  [[ "${nw[0]}" -eq "${nw[1]}" ]] ||
  echo "WARNING: The number of reference forms does not match your word-level" \
    "hypothesis (${nw[0]} vs. ${nw[1]})" >&2;
  # Compute error rates.
  if [ $hasR -eq 1 ]; then
    # Compute CER and WER with Confidence Intervals using R
    tmpf="$(mktemp)";
    ./utils/compute-errors.py "$ref_char" "$1" > "$tmpf";
    ./utils/compute-confidence.R "$tmpf" |
    gawk -v p="$p" '$1 == "%ERR"{
      printf("%CER forms %s: %.2f %s %s %s\n", p, $2, $3, $4, $5); }';
    ./utils/compute-errors.py "$ref_word" "$2" > "$tmpf";
    ./utils/compute-confidence.R "$tmpf" |
    gawk -v p="$p" '$1 == "%ERR"{
      printf("%WER forms %s: %.2f %s %s %s\n", p, $2, $3, $4, $5); }';
    rm -f "$tmpf";
  elif [ $hasComputeWer -eq 1 ]; then
    # Compute CER and WER using Kaldi's compute-wer
    compute-wer --text --mode=strict "$ref_char" "ark:$1" 2>/dev/null |
    gawk -v p="$p" '$1 == "%WER"{ printf("%CER forms %s: %.2f\n", p, $2); }';
    compute-wer --text --mode=strict "$ref_word" "ark:$2" 2>/dev/null |
    gawk -v p="$p" '$1 == "%WER"{ printf("%WER forms %s: %.2f\n", p, $2); }';
  fi;
  return 0;
}

acoustic_scale=1.79;
beam=65;
height=128;
max_active=5000000;
num_procs="$(nproc)";
order=3;
overwrite=false;
overwrite_ext=false;
overwrite_decode=false;
overwrite_fst=false;
overwrite_lexicon=false;
overwrite_lm=false;
partition="aachen";
qsub_opts="";
tasks="";
voc_size=50000;
help_message="
Usage: ${0##*/} [options] va_lkh_scp te_lkh_scp

Options:
  --acoustic_scales   : (type = string, default \"$acoustic_scales\")
                        List of acoustic scale factors, separated by spaces.
                        The first is used with a word LM and the second with
                        a character LM.
  --beam              : (type = float, default = $beam)
                        Decoding beam.
  --height            : (type = integer, default = $height)
                        Use images rescaled to this height.
  --max_active        : (type = integer, default = $max_active)
                        Max. number of tokens during Viterbi decoding
                        (a.k.a. histogram prunning).
  --num_procs         : (integer, default = $num_procs)
                        Maximum number of tasks to run in parallel in the host
                        computer (this maximum does not apply when using qsub).
  --order             : (type = integer, default = $order)
                        Order of the n-gram word LM. Use -1 to disable this.
  --overwrite         : (type = boolean, default = $overwrite)
                        Overwrite ALL steps.
  --overwrite_decode  : (type = boolean, default = $overwrite_decode)
                        Overwrite decoding (and all dependent steps).
  --overwrite_ext     : (type = boolean, default = $overwrite_ext)
                        Overwrite processing of external data (and all
                        dependent steps).
  --overwrite_fst     : (type = boolean, default = $overwrite_fst)
                        Overwrite transducers (and all dependent steps).
  --overwrite_lexicon : (type = boolean, default = $overwrite_lexicon)
                        Overwrite lexicon (and all dependent steps).
  --overwrite_lm      : (type = boolean, default = $overwrite_lm)
                        Overwrite ARPA language model (and all dependent steps).
  --partition         : (type = string, default = \"$partition\")
                        Select the the lists to use: \"aachen\" or \"kws\".
  --qsub_opts         : (type = string, default = \"$qsub_opts\")
                        If any option is given, will parallelize the decoding
                        using qsub. THIS IS HIGHLY RECOMMENDED.
  --tasks             : (string, default = \"$tasks\")
                        Range of tasks to execute. If not given, the range is
                        set automatically.
  --voc_size          : (type = integer, default = $voc_size)
                        Vocabulary size for the word n-gram LM.
";
source utils/parse_options.inc.sh || exit 1;
[ $# -ne 2 ] && echo "$help_message" >&2 && exit 1;
va_lkh_scp="$1";
te_lkh_scp="$2";

# Check required files
for f in train/syms.txt "$va_lkh_scp" "$te_lkh_scp" \
         "data/lists/lines/$partition/te_h${height}.lst" \
         "data/lists/lines/$partition/va_h${height}.lst" \
         "data/lang/forms/char/$partition/te.txt" \
         "data/lang/forms/char/$partition/va.txt" \
         "data/lang/forms/word/$partition/te.txt" \
         "data/lang/forms/word/$partition/va.txt"; do
  [ ! -s "$f" ] && echo "ERROR: File \"$f\" was not found!" >&2 && exit 1;
done;

hasR=0;
if which Rscript &> /dev/null; then hasR=1; fi;
hasComputeWer=0;
if which compute-wer &> /dev/null; then hasComputeWer=1; fi;

[ $hasR -ne 0 -o $hasComputeWer -ne 0 ] ||
echo "WARNING: Neither Rscript or compute-wer were found, so CER/WER" \
  "won't be computed!" >&2;

mkdir -p "decode/lm/$partition";

if [ "$overwrite" = true ]; then
  overwrite_ext=true;
  overwrite_align=true;
  overwrite_lexicon=true;
  overwrite_lm=true;
  overwrite_fst=true;
  overwrite_decode=true;
fi;

has_external=false;
if [[ -s data/external/brown.txt &&
      -s data/external/lob_excludealltestsets.txt &&
      -s data/external/wellington.txt ]]; then
  has_external=true;
  [[ "$overwrite_ext" = false && \
     -s "data/lang/external/word/brown.txt" && \
     -s "data/lang/external/word/brown_boundaries.txt" && \
     -s "data/lang/external/word/brown_tokenized.txt" && \
     -s "data/lang/external/word/lob_excludealltestsets.txt" && \
     -s "data/lang/external/word/lob_excludealltestsets_boundaries.txt" && \
     -s "data/lang/external/word/lob_excludealltestsets_tokenized.txt" && \
     -s "data/lang/external/word/wellington.txt" && \
     -s "data/lang/external/word/wellington_boundaries.txt" && \
     -s "data/lang/external/word/wellington_tokenized.txt" ]] || {
    overwrite_lexicon=true;
    overwrite_lm=true;
    ./steps/prepare_external_text.sh \
      --overwrite "$overwrite_ext" data/external/*.txt;
  }
else
  cat <<EOF >&2
WARNING: You are not using the Brown, LOB and Wellington datasets to Build
the n-gram language model and lexicon. This makes the results not compatible
with the published results in the paper.
EOF
fi;

# Build lexicon from the boundaries files.
lexiconp=data/lang/forms/word/lexiconp.txt;
[ "$overwrite_lexicon" = false -a -s "$lexiconp" ] || {
  overwrite_fst=true;
  if [ "$has_external" = true ]; then
    ./utils/build_word_lexicon.sh \
      data/lang/forms/word/$partition/tr_boundaries.txt \
      data/lang/external/word/*_boundaries.txt > "$lexiconp";
  else
    ./utils/build_word_lexicon.sh \
      data/lang/forms/word/$partition/tr_boundaries.txt > "$lexiconp";
  fi;
} ||
{ echo "ERROR: Creating file \"$lexiconp\"!" >&2 && exit 1; }

# Build word-level language model WITHOUT the unknown token
external_args_for_build_word_lm=();
if [ "$has_external" = true ]; then
  external_args_for_build_word_lm=(
    data/lang/external/word/lob_excludealltestsets_{tokenized,boundaries}.txt \
    data/lang/external/word/brown_{tokenized,boundaries}.txt \
    data/lang/external/word/wellington_{tokenized,boundaries}.txt);
fi;

[ "$overwrite_lm" = true ] && overwrite_fst=true;
./utils/build_word_lm.sh \
  --order "$order" --voc_size "$voc_size" \
  --unknown false --srilm_options "-kndiscount -interpolate" \
  --overwrite "$overwrite_lm" \
  train/syms.txt \
  data/lang/forms/word/$partition/tr_{tokenized,boundaries}.txt \
  data/lang/forms/word/$partition/va_{tokenized,boundaries}.txt \
  data/lang/forms/word/$partition/te_{tokenized,boundaries}.txt \
  "${external_args_for_build_word_lm[@]}" \
  "decode/lm/$partition/word_lm";

# Build transducers for the word LM.
[ "$overwrite_fst" = true ] && overwrite_decode=true;
./utils/build_word_fsts.sh --overwrite "$overwrite_fst" \
  train/syms.txt data/lang/forms/word/lexiconp.txt \
  "decode/lm/$partition/word_lm/interpolation-${order}gram-${voc_size}.arpa.gz" \
  "decode/lm/$partition/word_fst-${order}gram-${voc_size}";

# Perform decoding using the word LM
qsub_jobs=();
lkh_dir="decode/lkh/$partition/forms";
fst_dir="decode/lm/$partition/word_fst-${order}gram-${voc_size}";
for lkh_scp in "$va_lkh_scp" "$te_lkh_scp"; do
  bn="$(basename "$lkh_scp" .scp)";
  char_txt="decode/lm/$partition/char/$bn.txt";
  word_txt="decode/lm/$partition/word/$bn.txt";
  # Launch decoding.
  [ "$overwrite_decode" = false -a -s "$char_txt" ] || {
    # First, remove old transcripts, if any.
    rm -f "$char_txt" "$word_txt";
    qsub_jobs+=( $(./utils/decode_lazy.sh \
      --acoustic_scale "$acoustic_scale" \
      --beam "$beam" \
      --max_active "$max_active" \
      --num_procs "$num_procs" \
      --num_tasks 350 \
      --overwrite "$overwrite_decode" \
      --qsub_opts "$qsub_opts" \
      --tasks "$tasks" \
      "${fst_dir}/"{model,HCL.fst,G.fst} \
      "$lkh_scp" \
      "$fst_dir/$bn") );
  } ||
  {
    echo "ERROR: Decoding failed, check logs in $fst_dir/$bn" >&2 &&
    exit 1;
  }
done;

# If jobs are running on qsub, we must wait for them. Come back later.
[ "${#qsub_jobs[@]}" -gt 0 ] &&
echo "WARNING: qsub is running, execute this again when all jobs are done." &&
exit 0;

# Compute error rates (CER and WER).
for lkh_scp in "$va_lkh_scp" "$te_lkh_scp"; do
  bn="$(basename "$lkh_scp" .scp)";
  char_txt="decode/lm/$partition/char/$bn.txt";
  word_txt="decode/lm/$partition/word/$bn.txt";
  mkdir -p "$(dirname "$char_txt")";
  mkdir -p "$(dirname "$word_txt")";
  # Obtain char-level transcript for the forms, needed to compute CER.
  # The character sequence is produced by going through the HMM sequences
  # and then removing the dummy HMM boundaries (inc. whitespaces).
  [ "$overwrite_decode" = false -a -s "$char_txt" ] ||
  for f in "$fst_dir/$bn"/align.*.of.*.ark.gz; do
    ali-to-phones "${fst_dir}/model" "ark:zcat $f|" ark,t:- 2> /dev/null
  done |
  ./utils/int2sym.pl -f 2- "${fst_dir}/chars.txt" |
  ./utils/remove_transcript_dummy_boundaries.sh > "$char_txt";
  # Obtain the word-level transcript for the forms, needed to compute WER.
  # We just put together all characters that are not <space> to form words.
  [ "$overwrite_decode" = false -a -s "$word_txt" ] ||
  ./utils/remove_transcript_dummy_boundaries.sh --to-words "$char_txt" \
    > "$word_txt";
  # Compute errors (both CER and WER). $p is used in the compute_errors()
  # function.
  p="${bn:0:2}"; compute_errors "$char_txt" "$word_txt";
done;

exit 0;
