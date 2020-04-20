#!/bin/bash
set -e;
export LC_NUMERIC=C;

SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)";
[ "$(pwd)/utils" = "$SDIR" ] || {
    echo "Run the script from \"$(dirname $SDIR)\"!" >&2 && exit 1;
}
[ ! -f "$(pwd)/utils/parse_options.inc.sh" ] && \
    echo "Missing $(pwd)/utils/parse_options.inc.sh file!" >&2 && exit 1;

order=3;
overwrite=false;
srilm_options="-kndiscount -interpolate";
voc_size=50000;
unknown=true;
help_message="
Usage: ${0##*/} [options] syms tr_token_txt tr_bound_txt va_token_txt va_bound_txt
       te_token_txt te_bound_txt [ext_token_txt ext_bound_txt ...] output_dir

Description:
  Build a word-level N-gram language model using SRILM. You can specify the
  order and the vocabulary size of the N-gram using --order and --voc_size
  options. You can also choose between creating an open-vocabulary (--unknown
  true) or closed-vocabulary (--unknown false) LM. Other SRILM options can be
  modified with --srilm_options.

Arguments:
  tr_token_txt    : Tokenized training text data (assumes first column is ID).
  tr_bound_txt    : Token boundaries info from the training data.
  va_token_txt    : Tokenized validation text data (assumes first column is ID).
  va_bound_txt    : Token boundaries info from the validation data.
  te_token_txt    : Tokenized test text data (assumes first column is ID).
  te_bound_txt    : Token boundaries info from the test data.
  ext_token_txt   : Tokenized external text data.
  ext_bound_txt   : Token boundaries info from the external text data.
  output_dir      : Output directory where the language models and other
                    files will be written (e.g. \"decode/lm\").

Options:
  --order         : (type = integer, default = $order)
                    Order of the n-gram language model.
  --overwrite     : (type = boolean, default = $overwrite)
                    Overwrite previously created files.
  --srilm_options : (type = string, default = \"$srilm_options\")
                    Use SRILM's ngram-count with these options.
  --unknown       : (type = boolean, default = $unknown)
                    If true, create a open vocabulary (with the <unk> token
                    to represent the unknown words).
  --voc_size      : (type = integer, default = $voc_size)
                    Keep only this number of words.
";
source utils/parse_options.inc.sh || exit 1;
[ $# -lt 8 -o "$(echo "$# % 2" | bc)" -eq 1 ] &&
echo "$help_message" >&2 && exit 1;

# Read corpora data fils from the arguments.
syms="$1";
tr_tok="$2";
tr_bnd="$3";
va_tok="$4";
va_bnd="$5";
te_tok="$6";
te_bnd="$7";
shift 7;
# Read external data files from the arguments.
external_tok=();
external_bnd=();
while [ $# -gt 1 ]; do
  external_tok+=("$1"); external_bnd+=("$2");
  shift 2;
done;
# Read output directory from the arguments.
odir="$1";

# Set -unk flag for SRILM, if --unknown true is passed.
unk=""; [ "$unknown" = true ] && unk="-unk";

# Check input files
for f in "$tr_tok" "$tr_bnd" "$va_tok" "$va_bnd" "$te_tok" "$te_bnd" \
  "${external_tok[@]}" "${external_bnd[@]}"; do
  [ ! -s "$f" ] && echo "ERROR: File \"$f\" does not exist!" >&2 && exit 1;
done;

# Check required tools (SRILM)
for f in ngram-count ngram compute-best-mix; do
  which "$f" &> /dev/null ||
  { echo "ERROR: Program $f is not in your PATH!" >&2 && exit 1; }
done;

# Create output dir
mkdir -p "$odir";

# Get the total count for the tokens from the BOUNDARY files.
function get_vocab_count () {
  syms="$1"; shift;
  gawk '{ C[$1] += $2; }END{ for (w in C) print C[w], w; }' $@ |
  gawk -v SF="$syms" '
  BEGIN{ while((getline < SF) > 0) { SYM[$1]=1; }
  }NF > 0{
    for (i=1;i<=length($2);++i) {
      if (!(substr($2, i, 1) in SYM)) { N++; next; }
    }
    print;
  }END{
    if (N > 0) {
      print N" tokens ignored due to missing symbols!" > "/dev/stderr";
    }
  }' | sort -nr
}

# Interpolate a list of .arpa.gz files.
function interpolate_arpa_files () {
  # Compute detailed perplexity on the validation data
  info_files=();
  for arpa in $@; do
    info="${arpa/.arpa.gz/.info}";
    [[ "$overwrite" = false && -s "$info" ]] ||
    gawk '{$1=""; print;}' "$va_tok" |
    ngram -order "$order" $unk -debug 2 -ppl - -lm <(zcat "$arpa") &> "$info" ||
    { echo "ERROR: Creating file \"$info\"!" >&2 && exit 1; }
    info_files+=("$info");
  done;
  # Compute interpolation weights
  mixf="$odir/interpolation-${order}gram-${voc_size}.mix";
  [[ "$overwrite" = false && -s "$mixf" ]] ||
  compute-best-mix "${info_files[@]}" &> "$mixf" ||
  { echo "ERROR: Creating file \"$mixf\"!" >&2 && exit 1; }
  lambdas=( $(grep "best lambda" "$mixf" | gawk -F\( '{print $2}' | tr -d \)) );
  # Interpolate language models.
  tmpfs=();
  args=();
  for i in $(seq 1 $#); do
    tmpfs+=( "$(mktemp)"  );
    zcat "${!i}" > "${tmpfs[${#tmpfs[@]} - 1]}";
    if [ $i -eq 1 ]; then
      args+=( -lm "${tmpfs[${#tmpfs[@]} - 1]}" -lambda "${lambdas[i - 1]}" );
    elif [ $i -eq 2 ]; then
      args+=( -mix-lm "${tmpfs[${#tmpfs[@]} - 1]}" );
    else
      args+=( "-mix-lm$[i - 1]" "${tmpfs[${#tmpfs[@]} - 1]}" \
              "-mix-lambda$[i - 1]" "${lambdas[i - 1]}" );
    fi;
  done;
  outf="$odir/interpolation-${order}gram-${voc_size}.arpa.gz";
  [[ "$overwrite" = false && -s "$outf" ]] ||
  ngram -order "${order}" $unk "${args[@]}" -write-lm - |
  gzip -9 -c  > "$outf" ||
  { echo "ERROR: Creating file \"$outf\"!" >&2 && exit 1; }
  rm -f "${tmpfs[@]}";
  return 0;
}

# Create vocabulary file.
vocf="$odir/voc-${voc_size}";
[[ "$overwrite" = false && -s "$vocf" ]] ||
get_vocab_count "$syms" "$tr_bnd" "${external_bnd[@]}" |
head -n "$voc_size" | gawk '{print $2}' | sort > "$vocf" ||
{ echo "ERROR: Creating file \"$vocf\"!" >&2 && exit 1; }

# Train N-gram on the training partition
outf="$odir/$(basename "$tr_tok" .txt)-${order}gram-${voc_size}.arpa.gz";
[[ "$overwrite" = false && -s "$outf" ]] ||
gawk '{$1=""; print;}' "$tr_tok" |
ngram-count -order "$order" -vocab "$vocf" $unk $srilm_options -text - -lm - |
gzip -9 -c > "$outf" ||
{ echo "ERROR: Failed creating file \"$outf\"!" >&2 && exit 1; }
arpa_files=( "$outf" );

# Train N-gram on each external corpus
for tokf in "${external_tok[@]}"; do
  outf="$odir/$(basename "$tokf" .txt)-${order}gram-${voc_size}.arpa.gz";
  info="$odir/$(basename "$tokf" .txt)-${order}gram-${voc_size}.info";
  [[ "$overwrite" = false && -s "$outf" ]] ||
  ngram-count -order "$order" -vocab "$vocf" $unk $srilm_options -text "$tokf" \
    -lm - | gzip -9 -c > "$outf" ||
  { echo "ERROR: Failed creating file \"$outf\"!" >&2 && exit 1; }
  arpa_files+=( "$outf" );
done;

# Interpolate all language models
if [ ${#arpa_files[@]} -gt 1 ]; then
  interpolate_arpa_files "${arpa_files[@]}";
  outf="$odir/interpolation-${order}gram-${voc_size}.arpa.gz";
else
  outf="${arpa_files[0]}";
fi;

# Compute detailed perplexity of the interpolated model
ppl=();
oov=();
oovp=();
for f in "$tr_tok" "$va_tok" "$te_tok"; do
  ppl+=( $(gawk '{$1=""; print;}' "$f" |
      ngram -order "$order" -ppl - -lm <(zcat "$outf") 2>&1 |
      tail -n1 | sed -r 's|^.+\bppl= ([0-9.]+)\b.+$|\1|g' |
      gawk '{printf("%.2f", $1);}') );
  aux=( $(gawk -v VF="$vocf" '
BEGIN{ N=0; OOV=0; while((getline < VF) > 0) V[$1]=1; }
{ for (i=2;i<=NF;++i) { ++N; if (!($i in V)) { ++OOV; } } }
END{ print OOV, N; }' "$f") );
  oov+=(${aux[0]});
  oovp+=( $(echo "${aux[0]} ${aux[1]}" |
      gawk '{ printf("%.2f", 100 * $1 / $2); }') );
done;

# Print statistics
cat <<EOF >&2
Word-level ${order}-gram with ${voc_size} tokens:
Train: ppl = ${ppl[0]}, oov = ${oov[0]}, %oov = ${oovp[0]}
Valid: ppl = ${ppl[1]}, oov = ${oov[1]}, %oov = ${oovp[1]}
Test:  ppl = ${ppl[2]}, oov = ${oov[2]}, %oov = ${oovp[2]}
EOF

exit 0;
