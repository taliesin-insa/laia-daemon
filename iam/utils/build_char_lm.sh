#!/bin/bash
set -e;
export LC_NUMERIC=C;

SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)";
[ "$(pwd)/utils" = "$SDIR" ] || {
    echo "Run the script from \"$(dirname $SDIR)\"!" >&2 && exit 1;
}
[ ! -f "$(pwd)/utils/parse_options.inc.sh" ] && \
    echo "Missing $(pwd)/utils/parse_options.inc.sh file!" >&2 && exit 1;

order=10;
overwrite=false;
srilm_options="-wbdiscount -interpolate";
help_message="
Usage: ${0##*/} [options] tr_txt va_txt te_txt [ext_txt ...] output_dir

Description:
  Build a character-level N-gram language model using SRILM. You can specify
  the order and using the --order option. Other SRILM options can be modified
  with --srilm_options.

Arguments:
  tr_txt          : Training character text data (assumes first column is ID).
  va_txt          : Validation character text data (assumes first column is ID).
  te_txt          : Test character text data (assumes first column is ID).
  ext_txt         : External character text data.
  output_dir      : Output directory where the language models and other
                    files will be written (e.g. \"decode/lm\").

Options:
  --order         : (type = integer, default = $order)
                    Order of the n-gram language model.
  --overwrite     : (type = boolean, default = $overwrite)
                    Overwrite previously created files.
  --srilm_options : (type = string, default = \"$srilm_options\")
                    Use SRILM's ngram-count with these options.
";
source utils/parse_options.inc.sh || exit 1;
[ $# -lt 4 -o "$(echo "$# % 2" | bc)" -eq 0 ] &&
echo "$help_message" >&2 && exit 1;

# Read corpora data fils from the arguments.
tr_txt="$1";
va_txt="$2";
te_txt="$3";
shift 3;
# Read external data files from the arguments.
external_txt=();
while [ $# -gt 1 ]; do
  external_txt+=("$1");
  shift 1;
done;
# Read output directory from the arguments.
odir="$1";

# Check input files
for f in "$tr_txt" "$va_txt" "$te_txt" "${external_txt[@]}"; do
  [ ! -s "$f" ] && echo "ERROR: File \"$f\" does not exist!" >&2 && exit 1;
done;

# Check required tools (SRILM)
for f in ngram-count ngram compute-best-mix; do
  which "$f" &> /dev/null ||
  { echo "ERROR: Program $f is not in your PATH!" >&2 && exit 1; }
done;

# Create output dir
mkdir -p "$odir";

# Check that $1 is not newer than $2...$#.
function check_not_newer () {
  for i in $(seq 2 $#); do [[ "${!i}" -ot "$1" ]] && return 1; done;
  return 0;
}

# Check that $1 is not older than $2...$#
function check_not_older () {
  for i in $(seq 2 $#); do [[ "${!i}" -nt "$1" ]] && return 1; done;
  return 0;
}

# Interpolate a list of .arpa.gz files.
function interpolate_arpa_files () {
  # Compute detailed perplexity on the validation data
  info_files=();
  for arpa in $@; do
    info="${arpa/.arpa.gz/.info}";
    [[ "$overwrite" = false && -s "$info" && ( ! "$info" -ot "$arpa" ) ]] ||
    gawk '{$1=""; print;}' "$va_txt" |
    ngram -order "$order" -debug 2 -ppl - -lm <(zcat "$arpa") &> "$info" ||
    { echo "ERROR: Creating file \"$info\"!" >&2 && exit 1; }
    info_files+=("$info");
  done;
  # Compute interpolation weights
  mixf="$odir/interpolation-${order}gram.mix";
  ( [[ "$overwrite" = false && -s "$mixf" ]] &&
    check_not_older "$mixf" "${info_files[@]}" ) ||
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
  outf="$odir/interpolation-${order}gram.arpa.gz";
  [[ "$overwrite" = false && -s "$outf" && ( ! "$outf" -ot "$mixf" ) ]] ||
  ngram -order "${order}" "${args[@]}" -write-lm - |
  gzip -9 -c  > "$outf" ||
  { echo "ERROR: Creating file \"$outf\"!" >&2 && exit 1; }
  rm -f "${tmpfs[@]}";
  return 0;
}

# Create vocabulary file.
vocf="$(mktemp)";
cut -d\  -f2- "$tr_txt" "$va_txt" "$te_txt" | tr \  \\n | gawk 'NF > 0' |
sort | uniq > "$vocf";

# Train N-gram on the training partition
outf="$odir/$(basename "$tr_txt" .txt)-${order}gram.arpa.gz";
[[ "$overwrite" = false && -s "$outf" && ( ! "$outf" -ot "$tr_txt" )  ]] ||
gawk '{$1=""; print;}' "$tr_txt" |
ngram-count -order "$order" -vocab "$vocf" $srilm_options -text - -lm - |
gzip -9 -c > "$outf" ||
{ echo "ERROR: Failed creating file \"$outf\"!" >&2 && exit 1; }
arpa_files=( "$outf" );

# Train N-gram on each external corpus
for txtf in "${external_txt[@]}"; do
  outf="$odir/$(basename "$txtf" .txt)-${order}gram.arpa.gz";
  info="$odir/$(basename "$txtf" .txt)-${order}gram.info";
  [[ "$overwrite" = false && -s "$outf" && ( ! "$outf" -ot "$txtf" ) ]] ||
  ngram-count -order "$order" -vocab "$vocf" $srilm_options -text "$txtf" \
    -lm - | gzip -9 -c > "$outf" ||
  { echo "ERROR: Failed creating file \"$outf\"!" >&2 && exit 1; }
  arpa_files+=( "$outf" );
done;

# Interpolate all language models
if [ ${#arpa_files[@]} -gt 1 ]; then
  interpolate_arpa_files "${arpa_files[@]}";
  outf="$odir/interpolation-${order}gram.arpa.gz";
else
  outf="${arpa_files[0]}";
fi;

# Compute detailed perplexity of the interpolated model
ppl=();
oov=();
oovp=();
for f in "$tr_txt" "$va_txt" "$te_txt"; do
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
Char-level ${order}-gram:
Train: ppl = ${ppl[0]}, oov = ${oov[0]}, %oov = ${oovp[0]}
Valid: ppl = ${ppl[1]}, oov = ${oov[1]}, %oov = ${oovp[1]}
Test:  ppl = ${ppl[2]}, oov = ${oov[2]}, %oov = ${oovp[2]}
EOF

exit 0;
