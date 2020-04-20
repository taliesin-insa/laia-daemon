#!/bin/bash
set -e;
export LC_NUMERIC=C;

# Directory where the prepare.sh script is placed.
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)";
[ "$(pwd)/utils" != "$SDIR" ] && \
    echo "Please, run this script from the experiment top directory!" >&2 && \
    exit 1;
[ ! -f "$(pwd)/utils/parse_options.inc.sh" ] && \
    echo "Missing $(pwd)/utils/parse_options.inc.sh file!" >&2 && exit 1;

function getVocFromARPA () {
  if [ "${1:(-3)}" = ".gz" ]; then zcat "$1"; else cat "$1"; fi |
  gawk -v bos="$bos" -v eos="$eos" 'BEGIN{ og=0; }{
    if ($0 == "\\1-grams:") og=1;
    else if ($0 == "\\2-grams:") { og=0; exit; }
    else if (og == 1 && NF > 1 && $2 != bos && $2 != eos) print $2;
  }' | sort | uniq
}

eps="<eps>";
ctc="<ctc>";
bos="<s>";
eos="</s>";
dummy="<dummy>";
wspace="<space>";
transition_scale=1;
loop_scale=0.1;
overwrite=false;
help_message="
Usage: ${0##*/} [options] syms arpa_lm output_dir

Arguments:
  syms               : File containing the mapping from string to integer IDs
                       of the symbols used during CTC training.
  arpa_lm            : Character-level language model of full sentences in the
                       ARPA format.
  output_dir         : Output directory containing all the FSTs needed for
                       decoding and other files.

Options:
  --bos              : (type = string, default = \"$bos\")
  --ctc              : (type = string, default = \"$ctc\")
  --eos              : (type = string, default = \"$eos\")
  --eps              : (type = string, default = \"$eps\")
  --dummy            : (type = string, default = \"$dummy\")
  --overwrite        : (type = boolean, default = $overwrite)
  --transition_scale : (type = float, default = $transition_scale)
  --loop_scale       : (type = float, default = $loop_scale)
";
source "$(pwd)/utils/parse_options.inc.sh" || exit 1;
[ $# -ne 3 ] && echo "$help_message" >&2 && exit 1;

syms="$1";
arpalm="$2";
odir="$3";

# Check required files.
for f in "$syms" "$arpalm"; do
  [ ! -s "$f" ] && echo "Required file \"$f\" does not exist!" >&2 && exit 1;
done;

mkdir -p "$odir";

tmpd="$(mktemp -d)";
# List of characters present in the language model
getVocFromARPA "$arpalm" > "$tmpd/lm.chars";
# List of characters present in the symbols list,
# excluding CTC blank and epsilon symbols.
gawk '{print $1}' "$syms" | grep -v "$ctc" | grep -v "$eps" |
sort | uniq > "$tmpd/syms.chars";
# List of chars present in the symbols list, but not present in the ARPA LM.
comm -13 "$tmpd/lm.chars" "$tmpd/syms.chars" > "$tmpd/syms.oov";
num_oovc_syms="$(wc -l "$tmpd/syms.oov"  | cut -d\  -f1)";
# List of chars present in the ARPA LM, but not present in the symbols list.
comm -23 "$tmpd/lm.chars" "$tmpd/syms.chars" > "$tmpd/lm.oov";
num_oovc_lm="$(wc -l "$tmpd/lm.oov"  | cut -d\  -f1)";
# Show message, just for information.
[ "$num_oovc_syms" -gt 0 ] &&
echo "WARNING: #OOV chars in the input symbols: $num_oovc_syms" \
  "(see file $tmpd/syms.oov)" >&2;
[ "$num_oovc_lm" -gt 0 ] &&
echo "WARNING: #OOV chars in the input ARPA LM: $num_oovc_lm" \
  "(see file $tmpd/lm.oov)" >&2;

# Create lexicon with pronunciations for each character.
gawk -v IGNORE_FILE="$tmpd/syms.oov" -v bos="$bos" -v eos="$eos" \
  -v dm="$dummy" -v ws="$wspace" -v ctc="$ctc" -v eps="$eps" '
BEGIN{
  while((getline < IGNORE_FILE) > 0){ IGNORE[$1]=1; }
  IGNORE[eps] = 1; IGNORE[ctc] = 1;
  printf("%-12s    %f %s\n", bos, 1.0, ws);
  printf("%-12s    %f %s\n", eos, 1.0, ws);
}(!($1 in IGNORE)){
  if ($1 == bos || $1 == eos) next;
  printf("%-12s    %f %s\n", $1, 1.0, $1);
}' "$syms" > "$tmpd/lexiconp.txt" ||
( echo "Error creating file \"$odir/lexiconp.txt\"!" >&2 && exit 1 );
[[ "$overwrite" = false && -s "$odir/lexiconp.txt" ]] &&
cmp -s "$tmpd/lexiconp.txt" "$odir/lexiconp.txt" ||
mv "$tmpd/lexiconp.txt" "$odir/lexiconp.txt" ||
( echo "Error creating file \"$odir/lexiconp.txt\"!" >&2 && exit 1 );

# Add disambiguation symbols to the lexicon.
ndisambig=$(utils/add_lex_disambig.pl --pron-probs "$odir/lexiconp.txt" \
  "$tmpd/lexiconp_disambig.txt");
if [[ "$overwrite" = true || ! -s "$odir/lexiconp_disambig.txt" ]] ||
  ! cmp -s "$tmpd/lexiconp_disambig.txt" "$odir/lexiconp_disambig.txt"; then
  mv "$tmpd/lexiconp_disambig.txt" "$odir/lexiconp_disambig.txt";
fi;

# Check that all the HMMs in the lexicon are in the set of Laia symbols
# used for training! This is just for safety.
missing_hmm=( $(gawk -v LSF="$syms" -v dm="$dummy" '
BEGIN{
  while ((getline < LSF) > 0) C[$1]=1;
}{
  for (i=3; i <= NF; ++i) if (!($i in C) && $i != dm) print $i;
}' "$odir/lexiconp.txt" | sort) );
[ ${#missing_hmm[@]} -gt 0 ] &&
echo "FATAL: The following HMMs in the lexicon are missing!" >&2 &&
echo "${missing_hmm[@]}" >&2 && exit 1;


# Create character symbols list for the G fst.
[[ "$overwrite" = false && -s "$odir/words.txt" &&
    ( ! "$odir/words.txt" -ot "$syms" ) &&
    ( ! "$odir/words.txt" -ot "$odir/lexiconp.txt" ) ]] ||
gawk '{print $1}' "$odir/lexiconp.txt" | sort | uniq |
gawk -v eps="$eps" -v bos="$bos" -v eos="$eos" '
BEGIN{
  maxid = 0;
  printf("%-12s %d\n", eps, maxid++);
  printf("%-12s %d\n", bos, maxid++);
  printf("%-12s %d\n", eos, maxid++);
}($1 != eps && $1 != bos && $1 != eos){
  printf("%-12s %d\n", $1, maxid++);
}END{
  printf("%-12s %d\n", "#0", maxid++);  # Backoff in the word-lm
}' > "$odir/words.txt" ||
( echo "Failed $odir/words.txt creation!" && exit 1; );


# Create character symbols list for the HMMs fst.
[[ "$overwrite" = false && -s "$odir/chars.txt" &&
    ( ! "$odir/chars.txt" -ot "$syms" ) &&
    ( ! "$odir/chars.txt" -ot "$odir/lexiconp_disambig.txt" ) ]] ||
sort -n -k2 "$syms" |
gawk -v eps="$eps" -v ctc="$ctc" -v dm="$dummy" -v ND="$ndisambig" '
BEGIN{
  printf("%-12s %d\n", eps, 0);
  printf("%-12s %d\n", ctc, 1);
  maxid=1;
}{
  if ($1 != eps && $1 != ctc && $1 != dm) {
    printf("%-12s %d\n", $1, $2);
    maxid=(maxid < $2 ? $2 : maxid);
  }
}END{
  printf("%-12s %d\n", dm, ++maxid);
  for (n = 0; n <= ND; ++n)
    printf("%-12s %d\n", "#"n, ++maxid);
}' > "$odir/chars.txt" ||
( echo "Failed $odir/chars.txt creation!" && exit 1; );

# Create integer list of disambiguation symbols.
gawk '$1 ~ /^#.+/{ print $2 }' "$odir/chars.txt" > "$odir/chars_disambig.int";
# Create integer list of disambiguation symbols.
gawk '$1 ~ /^#.+/{ print $2 }' "$odir/words.txt" > "$odir/words_disambig.int";

# Create HMM model and tree
./utils/create_ctc_hmm_model.sh --eps "$eps" --ctc "$ctc" --dummy "$dummy" \
  --overwrite "$overwrite" "$odir/chars.txt" "$odir/model" "$odir/tree";

# Create the lexicon FST with disambiguation symbols from lexiconp.txt
[[ "$overwrite" = false && -s "$odir/L.fst" &&
    ( ! "$odir/L.fst" -ot "$odir/lexiconp_disambig.txt" ) &&
    ( ! "$odir/L.fst" -ot "$odir/chars.txt" ) &&
    ( ! "$odir/L.fst" -ot "$odir/words.txt" ) ]] ||
utils/make_lexicon_fst.pl \
  --pron-probs "$odir/lexiconp_disambig.txt" |
fstcompile --isymbols="$odir/chars.txt" --osymbols="$odir/words.txt" |
fstdeterminizestar --use-log=true |
fstminimizeencoded |
fstarcsort --sort_type=ilabel > "$odir/L.fst" ||
{ echo "Failed $odir/L.fst creation!" >&2 && exit 1; }


# Compose the context-dependent and the L transducers.
[[ "$overwrite" = false && -s "$odir/CL.fst" &&
    ( ! "$odir/CL.fst" -ot "$odir/L.fst" ) ]] ||
fstcomposecontext --context-size=1 --central-position=0 \
  --read-disambig-syms="$odir/chars_disambig.int" \
  --write-disambig-syms="$odir/ilabels_disambig.int" \
  "$odir/ilabels" "$odir/L.fst" |
fstarcsort --sort_type=ilabel > "$odir/CL.fst" ||
( echo "Failed $odir/CL.fst creation!" >&2 && exit 1; );


# Create Ha transducer
[[ "$overwrite" = false && -s "$odir/Ha.fst" &&
    ( ! "$odir/Ha.fst" -ot "$odir/model" ) &&
    ( ! "$odir/Ha.fst" -ot "$odir/tree" ) &&
    ( ! "$odir/Ha.fst" -ot "$odir/ilabels" ) ]] ||
make-h-transducer --disambig-syms-out="$odir/tid_disambig.int" \
  --transition-scale="$transition_scale" "$odir/ilabels" "$odir/tree" \
  "$odir/model" > "$odir/Ha.fst" ||
( echo "Failed $odir/Ha.fst creation!" >&2 && exit 1; );


# Create HaCL transducer.
[[ "$overwrite" = false && -s "$odir/HCL.fst" &&
    ( ! "$odir/HaCL.fst" -ot "$odir/Ha.fst" ) &&
    ( ! "$odir/HCL.fst" -ot "$odir/CL.fst" ) ]] ||
fsttablecompose "$odir/Ha.fst" "$odir/CL.fst" |
fstdeterminizestar --use-log=true |
fstrmsymbols "$odir/tid_disambig.int" |
fstrmepslocal |
fstminimizeencoded > "$odir/HaCL.fst" ||
( echo "Failed $odir/HaCL.fst creation!" >&2 && exit 1; );


# Create HCL transducer.
[[ "$overwrite" = false && -s "$odir/HCL.fst" &&
    ( ! "$odir/HCL.fst" -ot "$odir/HaCL.fst" ) ]] ||
add-self-loops --self-loop-scale="$loop_scale" --reorder=true \
  "$odir/model" "$odir/HaCL.fst" |
fstarcsort --sort_type=olabel > "$odir/HCL.fst" ||
( echo "Failed $odir/HCL.fst creation!" >&2 && exit 1; );


# Create the grammar FST from the ARPA language model.
[[ "$overwrite" = false && -s "$odir/G.fst" &&
    ( ! "$odir/G.fst" -ot "$arpalm" ) &&
    ( ! "$odir/G.fst" -ot "$odir/lexiconp.txt" ) ]] ||
if [[ "${arpalm##*.}" = gz ]]; then zcat "$arpalm" ; else cat "$arpalm"; fi |
grep -v "$bos $bos" | grep -v "$eos $bos" | grep -v "$eos $eos" |
arpa2fst - 2> /dev/null | fstprint --acceptor |
gawk -v eps="$eps" -v bos="$bos" -v eos="$eos" -v WF="$odir/lexiconp.txt" '
BEGIN{
  while ((getline < WF) > 0) { W[$1]=1; }
  lex_has_bos = (bos in W) ? 1 : 0;
  lex_has_eos = (eos in W) ? 1 : 0;
}{
  if (NF >= 3) {
    s=$1; t=$2; i=$3; o=$3; w=$4;

    # Replace <eps> with #0 from the input (backoff).
    if ($3 == eps)       { i = "#0"; }
    # Replace <s> with <eps>.
    else if ($3 == bos)  {
      if (!lex_has_bos) i = eps;
      o = eps;
    }
    # Replace </s> with <eps>.
    else if ($3 == eos)  {
      if (!lex_has_eos) i = eps;
      o = eps;
    }
    # Remove arcs with excluded characters.
    else if (!($3 in W)) { next; }

    print s, t, i, o, w;
  } else {
    print;
  }
}' |
fstcompile --isymbols="$odir/words.txt" --osymbols="$odir/words.txt" |
fstconnect |
fstdeterminizestar --use-log=true |
fstminimizeencoded |
fstpushspecial |
fstrmsymbols <(gawk '$1 == "#0"{ print $2 }' "$odir/chars.txt") |
fstarcsort --sort_type=ilabel > "$odir/G.fst" ||
{ echo "Failed $odir/G.fst creation!" >&2 && exit 1; }

exit 0;
