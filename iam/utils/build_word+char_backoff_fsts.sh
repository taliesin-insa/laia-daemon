#!/bin/bash
set -e;
export LC_NUMERIC=C;

# Directory where the prepare.sh script is placed.
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)";
[ "$(pwd)/utils" != "$SDIR" ] &&
echo "Please, run this script from the experiment top directory!" >&2 && exit 1;
[ ! -f "$(pwd)/utils/parse_options.inc.sh" ] &&
echo "Missing $(pwd)/utils/parse_options.inc.sh file!" >&2 && exit 1;

function getVocFromARPA () {
  if [ "${1:(-3)}" = ".gz" ]; then zcat "$1"; else cat "$1"; fi |
  gawk -v unk="$unk" -v bos="$bos" -v eos="$eos" 'BEGIN{ og=0; }{
    if ($0 == "\\1-grams:") og=1;
    else if ($0 == "\\2-grams:") { og=0; exit; }
    else if (og == 1 && NF > 1 && $2 != bos && $2 != eos && $2 != unk) print $2;
  }' | sort
}

eps="<eps>";
ctc="<ctc>";
bos="<s>";
eos="</s>";
unk="<unk>";
dummy="<dummy>";
wspace="<space>";
charpfx="_";
transition_scale=1;
loop_scale=0.1;
overwrite=false;
help_message="
Usage: ${0##*/} [options] syms lexicon char_lm word_lm output_dir

Arguments:
  syms               : File containing the mapping from string to integer IDs
                       of the symbols used during CTC training.
  lexicon            : File containing the word lexicon (with probabilities)
                       used to map from words to sequences of HMMs.
  char_lm            : Input character-level language model in ARPA format.
                       This should represent unknown/OOV words only, not full
                       sentences.
  word_lm            : Input word-level language model in ARPA format. This
                       should include arcs labeled with the unknown/OOV symbol
                       (see --unk).
  output_dir         : Output directory containing all the FSTs needed for
                       decoding and other files.

Options:
  --bos              : (type = string, default = \"$bos\")
                       String representing the begin-of-sentence.
  --ctc              : (type = string, default = \"$ctc\")
                       String representing the CTC blank symbol.
  --charpfx          : (type = string, default = \"$charpfx\")
                       Add this prefix to the symbols in the character backoff
                       language model.
  --eos              : (type = string, default = \"$eos\")
                       String representing the end-of-sentence.
  --eps              : (type = string, default = \"$eps\")
                       String representing the epsilon symbol.
  --dummy            : (type = string, default = \"$dummy\")
                       String representing the symbol for the dummy HMM.
  --loop_scale       : (type = float, default = $loop_scale)
                       Scale for self-loops transitions in the HMMs.
  --overwrite        : (type = boolean, default = $overwrite)
                       If true, overwrite output files even if it is not needed.
  --transition_scale : (type = float, default = $transition_scale)
                       Scale for transitions (excluding self-loops) in the HMMs.
  --unk              : (type = string, default = \"$unk\")
                       String representing the unknown words.
  --wspace           : (type = string, default = \"$wspace\")
                       String representing the whitespace character.
";
source "$(pwd)/utils/parse_options.inc.sh" || exit 1;
[ $# -ne 5 ] && echo "$help_message" >&2 && exit 1;

laia_syms="$1";
word_lexicon="$2";
char_arpa="$3";
word_arpa="$4";
odir="$5";

# Check required files.
for f in "$laia_syms" "$word_lexicon" "$char_arpa" "$word_arpa"; do
  [ ! -s "$f" ] && echo "Required file \"$f\" does not exist!" >&2 && exit 1;
done;

mkdir -p "$odir";

# List of words and characters present in the language model files.
lm_words="$(mktemp)";
getVocFromARPA "$word_arpa" > "$lm_words";
lm_chars="$(mktemp)";
getVocFromARPA "$char_arpa" > "$lm_chars";

# List of words and characters present in the lexicon files.
lex_words="$(mktemp)";
gawk '{print $1}' "$word_lexicon" | sort > "$lex_words";
lex_chars="$(mktemp)";
gawk '{print $1}' "$laia_syms" | sort > "$lex_chars";


# List of words present in the input lexicon, but not present in the ARPA LM.
oovw_lex="$(mktemp)";
comm -13 "$lm_words" "$lex_words" > "$oovw_lex";
num_oovw_lex="$(wc -l "$oovw_lex" | cut -d\  -f1)";
# List of words present in the ARPA LM, but not present in the input lexicon.
oovw_lm="$(mktemp)";
comm -23 "$lm_words" "$lex_words" > "$oovw_lm";
num_oovw_lm="$(wc -l "$oovw_lm"  | cut -d\  -f1)";
# Show message, just for information.
[ "$num_oovw_lex" -gt 0 ] &&
echo "WARNING: #OOV words in the input lexicon: $num_oovw_lex" >&2;
[ "$num_oovw_lm" -gt 0 ] &&
echo "WARNING: #OOV words in the input ARPA LM: $num_oovw_lm" >&2;


# List of characters present in the input lexicon, but not present in the ARPA.
oovc_lex="$(mktemp)";
comm -13 "$lm_chars" "$lex_chars" > "$oovc_lex";
num_oovc_lex="$(wc -l "$oovc_lex"  | cut -d\  -f1)";
# List of words present in the ARPA LM, but not present in the input lexicon.
oovc_lm="$(mktemp)";
comm -23 "$lm_chars" "$lex_chars" > "$oovc_lm";
num_oovc_lm="$(wc -l "$oovc_lm"  | cut -d\  -f1)";
# Show message, just for information.
[ "$num_oovc_lex" -gt 0 ] &&
echo "WARNING: #OOV chars in the input lexicon: $num_oovc_lex" >&2;
[ "$num_oovc_lm" -gt 0 ] &&
echo "WARNING: #OOV chars in the input ARPA LM: $num_oovc_lm" >&2;

# Create lexicon with pronunciations for each word AND characters.
tmpf="$(mktemp)";
(
  # Transduce whitespace to <s>, used in the character-level backoff
  # to force a whitespace before emitting any word from the LM.
  # Notice: This only affects when the char-backoff is applied!
  printf "%-25s    %f %s\n" "$bos" "1.0" "$wspace";
  # Dummy at the end of the sentence.
  printf "%-25s    %f %s\n" "$eos" "1.0" "$dummy";
  # Characters.
  gawk -v PFX="$charpfx" -v IGNORE_FILE="$oovc_lex" -v bos="$bos" -v eos="$eos" \
    -v unk="$unk" '
BEGIN{
  while((getline < IGNORE_FILE) > 0){ IGNORE[$1]=1; }
  IGNORE[bos] = 1;
  IGNORE[eos] = 1;
  IGNORE[unk] = 1;
}(!($1 in IGNORE)){
  w=sprintf("%s%s", PFX, $1);
  printf("%-25s    %f %s\n", w, 1.0, $1);
}' "$laia_syms";
  # Words.
  gawk -v IGNORE_FILE="$oovw_lex" -v bos="$bos" -v eos="$eos" -v unk="$unk" '
BEGIN{
  while((getline < IGNORE_FILE) > 0){ IGNORE[$1]=1; }
  IGNORE[bos] = 1;
  IGNORE[eos] = 1;
  IGNORE[unk] = 1;
}(!($1 in IGNORE))' "$word_lexicon";
) > "$tmpf";
[[ "$overwrite" = false && -s "$odir/lexiconp.txt" ]] &&
cmp -s "$tmpf" "$odir/lexiconp.txt" ||
mv "$tmpf" "$odir/lexiconp.txt" ||
{ echo "ERROR: Creating file \"$odir/lexiconp.txt\"!" >&2 && exit 1; }


# Add disambiguation symbols to the lexicon.
# Nottice that the disambiguation symbols start from 2 because #0 is reserved
# for the word-lm backoff and #1 is reserved for the char-lm backoff.
tmpf="$(mktemp)";
ndisambig=$(utils/add_lex_disambig.pl \
  --first-allowed-disambig 2 \
  --pron-probs "$odir/lexiconp.txt" "$tmpf");
if [[ "$overwrite" = true || ! -s "$odir/lexiconp_disambig.txt" ]] ||
  ! cmp -s "$tmpf" "$odir/lexiconp_disambig.txt"; then
  mv "$tmpf" "$odir/lexiconp_disambig.txt";
fi;

# Check that all the HMMs in the lexicon are in the set of Laia symbols
# used for training!
# This is just for safety.
missing_hmm=( $(gawk -v LSF="$laia_syms" -v dm="$dummy" '
BEGIN{
  while ((getline < LSF) > 0) C[$1]=1;
}{
  for (i=3; i <= NF; ++i) if (!($i in C) && $i != dm) print $i;
}' "$odir/lexiconp.txt" | sort) );
[ ${#missing_hmm[@]} -gt 0 ] &&
echo "FATAL: The following HMMs in the lexicon are missing!" >&2 &&
echo "${missing_hmm[@]}" >&2 && exit 1;


# Create word symbols list.
# Note: This list includes the characters from the character-backoff LM!
[[ "$overwrite" = false && -s "$odir/words.txt" &&
    ( ! "$odir/words.txt" -ot "$odir/lexiconp.txt" ) ]] ||
gawk -v eps="$eps" -v bos="$bos" -v eos="$eos" -v unk="$unk" '
BEGIN{
  maxid = 0;
  printf("%-25s %d\n", eps, maxid++);
  printf("%-25s %d\n", bos, maxid++);
  printf("%-25s %d\n", eos, maxid++);
  printf("%-25s %d\n", unk, maxid++);
}($1 != eps && $1 != bos && $1 != eos && $1 != unk){
  printf("%-25s %d\n", $1, maxid++);
}END{
  printf("%-25s %d\n", "#0", maxid++);  # Backoff in the word-lm
  printf("%-25s %d\n", "#1", maxid++);  # Backoff in the char-lm
  printf("%-25s %d\n", "#2", maxid++);  # Disambiguate consecutive backoff
}' "$odir/lexiconp.txt" > "$odir/words.txt" ||
{ echo "ERROR: Creating file \"$odir/words.txt\"!" >&2 && exit 1; }


# Create character symbols list.
[[ "$overwrite" = false && -s "$odir/chars.txt" &&
    ( ! "$odir/chars.txt" -ot "$laia_syms" ) &&
    ( ! "$odir/chars.txt" -ot "$odir/lexiconp_disambig.txt" ) ]] ||
sort -n -k2 "$laia_syms" |
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
{ echo "ERROR: Creating file \"$odir/chars.txt\"!" && exit 1; }


# Create integer list of disambiguation symbols.
gawk '$1 ~ /^#.+/{ print $2 }' "$odir/chars.txt" > "$odir/chars_disambig.int";
# Create integer list of disambiguation symbols.
gawk '$1 ~ /^#.+/{ print $2 }' "$odir/words.txt" > "$odir/words_disambig.int";


# Create HMM model and tree
./utils/create_ctc_hmm_model.sh --eps "$eps" --ctc "$ctc" --dummy "$dummy" \
  --overwrite "$overwrite" "$odir/chars.txt" "$odir/model" "$odir/tree";


# Create the lexicon FST with disambiguation symbols from lexiconp.txt
# BUT NO SELF-LOOPS TO PROPAGATE, BACKOFF.
[[ "$overwrite" = false && -s "$odir/L.fst" &&
    ( ! "$odir/L.fst" -ot "$odir/lexiconp_disambig.txt" ) &&
    ( ! "$odir/L.fst" -ot "$odir/chars.txt" ) &&
    ( ! "$odir/L.fst" -ot "$odir/words.txt" ) ]] ||
utils/make_lexicon_fst.pl --pron-probs "$odir/lexiconp_disambig.txt" |
fstcompile --isymbols="$odir/chars.txt" --osymbols="$odir/words.txt" |
fstdeterminizestar --use-log=true |
fstminimizeencoded |
fstarcsort --sort_type=ilabel > "$odir/L.fst" ||
{ echo "ERROR: Creating file \"$odir/L.fst\"!" >&2 && exit 1; }


# Compose the context-dependent and the L transducers.
[[ "$overwrite" = false && -s "$odir/CL.fst" &&
    ( ! "$odir/CL.fst" -ot "$odir/L.fst" ) ]] ||
fstcomposecontext --context-size=1 --central-position=0 \
  --read-disambig-syms="$odir/chars_disambig.int" \
  --write-disambig-syms="$odir/ilabels_disambig.int" \
  "$odir/ilabels" "$odir/L.fst" |
fstarcsort --sort_type=ilabel > "$odir/CL.fst" ||
{ echo "ERROR: Creating file \"$odir/CL.fst\"!" >&2 && exit 1; }


# Create Ha transducer
[[ "$overwrite" = false && -s "$odir/Ha.fst" &&
    ( ! "$odir/Ha.fst" -ot "$odir/model" ) &&
    ( ! "$odir/Ha.fst" -ot "$odir/tree" ) &&
    ( ! "$odir/Ha.fst" -ot "$odir/ilabels" ) ]] ||
make-h-transducer --disambig-syms-out="$odir/tid_disambig.int" \
  --transition-scale="$transition_scale" "$odir/ilabels" "$odir/tree" \
  "$odir/model" > "$odir/Ha.fst" ||
{ echo "ERROR: Creating file \"$odir/Ha.fst\"!" >&2 && exit 1; }


# Create HaCL transducer.
[[ "$overwrite" = false && -s "$odir/HCL.fst" &&
    ( ! "$odir/HaCL.fst" -ot "$odir/Ha.fst" ) &&
    ( ! "$odir/HCL.fst" -ot "$odir/CL.fst" ) ]] ||
fsttablecompose "$odir/Ha.fst" "$odir/CL.fst" |
fstdeterminizestar --use-log=true |
fstrmsymbols "$odir/tid_disambig.int" |
fstrmepslocal |
fstminimizeencoded > "$odir/HaCL.fst" ||
{ echo "ERROR: Creating file \"$odir/HaCL.fst\"!" >&2 && exit 1; }


# Create HCL transducer.
[[ "$overwrite" = false && -s "$odir/HCL.fst" &&
    ( ! "$odir/HCL.fst" -ot "$odir/HaCL.fst" ) ]] ||
add-self-loops --self-loop-scale="$loop_scale" --reorder=true \
  "$odir/model" "$odir/HaCL.fst" |
fstarcsort --sort_type=olabel > "$odir/HCL.fst" ||
{ echo "ERROR: Creating file \"$odir/HCL.fst\"!" >&2 && exit 1; }


# Create the word-level FST from the ARPA language model.
[[ "$overwrite" = false && -s "$odir/G.word.fst" &&
    ( ! "$odir/G.word.fst" -ot "$word_arpa" ) &&
    ( ! "$odir/G.word.fst" -ot "$odir/words.txt" ) &&
    ( ! "$odir/G.word.fst" -ot "$odir/lexiconp.txt" ) ]] ||
if [ "${word_arpa:(-3)}" = ".gz" ]; then
  zcat "$word_arpa";
else
  cat "$word_arpa";
fi | grep -v "$bos $bos" | grep -v "$eos $bos" | grep -v "$eos $eos" |
arpa2fst - 2> /dev/null | fstprint |
gawk -v eps="$eps" -v bos="$bos" -v eos="$eos" -v unk="$unk" \
  -v VF="$odir/lexiconp.txt" '
BEGIN{
  while ((getline < VF) > 0) V[$1]=1;
  V[eps] = 1;
  V[bos] = 1;
  V[eos] = 1;
  V[unk] = 1;
}{
  if (NF >= 4) {
    # Replace backoff epsilon with #0 ONLY on the input side
    if ($3==eps) $3="#0";
    # Remove <s> from the input and output
    if ($3==bos) $3=eps; if ($4==bos) $4=eps;
    # Remove </s> from the output ONLY.
    if ($4==eos) $4=eps;
    # Ignore words in the ARPA that were not in the given lexicon.
    if (!($3 in V) || !($4 in V)) next;
  }
  print;
}' |
fstcompile --isymbols="$odir/words.txt" --osymbols="$odir/words.txt" |
fstconnect |
fstdeterminizestar --use-log=true |
fstminimizeencoded |
fstpushspecial |
fstrmsymbols <(gawk '$1 == "#0"{ print $2 }' "$odir/words.txt") |
fstarcsort --sort_type=ilabel > "$odir/G.word.fst" ||
{ echo "ERROR: Creating file \"$odir/G.word.fst\"!" >&2 && exit 1; }


# Create the char-level FST from the ARPA language model.
[[ "$overwrite" = false && -s "$odir/G.char.fst" &&
    ( ! "$odir/G.char.fst" -ot "$char_arpa" ) &&
    ( ! "$odir/G.char.fst" -ot "$odir/words.txt" ) &&
    ( ! "$odir/G.word.fst" -ot "$odir/lexiconp.txt" ) ]] ||
if [ "${char_arpa:(-3)}" = ".gz" ]; then
  zcat "$char_arpa";
else
  cat "$char_arpa";
fi | grep -v "$bos $bos" | grep -v "$eos $bos" | grep -v "$eos $eos" |
arpa2fst - - | fstprint |
gawk -v eps="$eps" -v bos="$bos" -v eos="$eos" -v pfx="$charpfx" \
  -v VF="$odir/lexiconp.txt" '
BEGIN{
  while ((getline < VF) > 0) V[$1]=1;
  V[eps] = 1;
  V[bos] = 1;
  V[eos] = 1;
}{
  if (NF >= 4) {
    # Replace backoff epsilon with #0 ONLY on the input side
    if ($3==eps) $3="#0";
    # Remove <s> from the output ONLY.
    if ($4==bos) $4=eps;
    # Remove </s> from the input, replace output with #2.
    if ($3==eos) $3=eps; if ($4==eos) $4="#2";
    # Ignore words in the ARPA that were not in the given lexicon.
    if ($3 != eps && $3 != bos && $3 != eos &&
        $4 != eps && $4 != bos && $4 != eos) {
      $3 = sprintf("%s%s", pfx, $3);
      $4 = sprintf("%s%s", pfx, $4);
      if (!($3 in V) || !($4 in V)) next;
    }
  }
  print;
}' |
fstcompile --isymbols="$odir/words.txt" --osymbols="$odir/words.txt" |
fstconnect |
fstdeterminizestar --use-log=true |
fstminimizeencoded |
fstpushspecial |
fstrmsymbols <(gawk '$1 == "#0"{ print $2 }' "$odir/words.txt") |
fstarcsort --sort_type=ilabel > "$odir/G.char.fst" ||
{ echo "ERROR: Creating file \"$odir/G.char.fst\"!" >&2 && exit 1; }

exit 0;
