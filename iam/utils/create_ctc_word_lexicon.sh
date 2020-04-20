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


eps="<eps>";
ctc="<ctc>";
dummy="<dummy>";
no_space_words=;
overwrite=false;
wspace="<space>";
help_message="
Usage: create_ctc_word_lexicon.sh [options] char_syms_in word_syms_in
                                  lexicon_prob char_syms_out word_syms_out
                                  output_fst

This script creates a customized lexicon FST to handle the whitespaces and
the CTC blank symbol.

- Whitespaces are not added at the boundary of the sentences. That is, there
  are not whitespaces consumed at the start or at the end of the sentence,
  only in-between words.
- There is a special group of words (see --no_space_words) that do not consume
  any whitespace. This is useful, for instance, to deal with abbreviations
  like 're, 've, 's, 'd, etc. which in many cases are separated from the word
  lemma for language modeling purposes.
- At the end of the sentence, the dummy HMM for CTC is used to deal with
  CTC symbols at the end of the sentence.
- Disambiguation symbols are added to the lexicon, including the backoff
  symbols.

Arguments:
  char_syms_in       : File mapping from character/HMM symbols to integer IDs.
                       This should be the file used by Laia during CTC training.
  word_syms_in       : File mapping from word symbols to integer IDs.
                       This should be the file used to create the word-LM FST.
  lexicon_prob       : Lexicon file containing the mapping of each word into
                       characters, including the pronunciation probabilities.
  char_syms_out      : Same as char_syms_in but including auxiliary and
                       disambiguation symbols.
  word_syms_out      : Same as word_syms_in but including auxiliary and
                       disambiguation symbols.
  output_fst         : Output lexicon fst.

Options:
  --ctc              : (type = string, default = \"$ctc\")
                       CTC symbol string.
  --eps              : (type = string, default = \"$eps\")
                       Epsilon symbol string.
  --dummy            : (type = string, default = \"$dummy\")
                       Dummy HMM symbol string.
  --no_space_words   : (type = string, default = \"$no_space_words\")
                       File containing a list (one per line) of words that
                       should not be preceded by a white space in the lexicon.
                       Typically used for abbreviations that were separated
                       from the lemma during language modeling (e.g. 've, 'd,
                       n't, 's, etc).
  --overwrite        : (type = boolean, default = $overwrite)
                       Overwrite existing files even if it is not needed.
  --wspace           : (type = string, default = \"$wspace\")
                       Whitespace symbol string.
";
source "$(pwd)/utils/parse_options.inc.sh" || exit 1;
[ $# -ne 6 ] && echo "$help_message" >&2 && exit 1;

char_syms_in="$1";
word_syms_in="$2";
lexicon_prob="$3";
char_syms_out="$4";
word_syms_out="$5";
ofst="$6";

[ ! -f "$char_syms_in" ] &&
echo "ERROR: File \"$char_syms_in\" does not exist!" >&2 && exit 1;
[ ! -f "$word_syms_in" ] &&
echo "ERROR: File \"$word_syms_in\" does not exist!" >&2 && exit 1;
[ ! -f "$lexicon_prob" ] &&
echo "ERROR: File \"$lexicon_prob\" does not exist!" >&2 && exit 1;

mkdir -p "$(dirname "$char_syms_out")";
mkdir -p "$(dirname "$word_syms_out")";
mkdir -p "$(dirname "$ofst")";


# Add disambiguation symbols to the input lexicon with probabilities
lexicon_prob_disambig="$(mktemp)";
max_char_disambig=$(./utils/add_lex_disambig.pl --pron-probs \
  "$lexicon_prob" "$lexicon_prob_disambig");


# Add missing symbols to the char/hmm symbols map.
tmpf="$(mktemp)";
gawk -v eps="$eps" -v ctc="$ctc" -v dm="$dummy" -v md="$max_char_disambig" '
BEGIN{
  maxid=0;
  printf("%-15s %d\n", eps, 0);
  # Flag for additional symbols to add.
  flg[dm] = 0;
  for (i=0;i<=md;++i) flg["#"i] = 0;
}{
  p=$1; n=$2;
  maxid=(maxid < $2 ? $2 : maxid);
  # Check <eps> ID
  if ((p != eps && n == 0) ||
      (p == eps && n != 0)) {
    print "Epsilon \""eps"\" must have ID 0!" > "/dev/stderr"; exit 1;
  } else if (p == eps && n == 0) next;
  # Add symbols in the input symbols list
  if (p in flg) flg[p] = 1;
  printf("%-15s %d\n", p, n);
}END{
  for (p in flg) {
    if (flg[p] == 0) {
      printf("%-15s %d\n", p, ++maxid);
    }
  }
}' "$char_syms_in" > "$tmpf" ||
( echo "ERROR: Creating \"$char_syms_out\"!" >&2 && exit 1 );
( [[ "$overwrite" = false && -s "$char_syms_out" ]] &&
  cmp -s "$tmpf" "$char_syms_out" ) ||
mv "$tmpf" "$char_syms_out" ||
( echo "ERROR: Creating \"$char_syms_out\"!" >&2 && exit 1 );


# Add missing symbols tot the word symbols map.
tmpf="$(mktemp)";
gawk -v eps="$eps" -v dm="$dummy" '
BEGIN {
  maxid=0;
  printf("%-25s %d\n", eps, 0);
  flg["#0"] = 0;
}{
  p=$1; n=$2;
  maxid=(maxid < $2 ? $2 : maxid);
  # Check <eps> ID
  if ((p != eps && n == 0) ||
      (p == eps && n != 0)) {
    print "Epsilon \""eps"\" must have ID 0!" > "/dev/stderr"; exit 1;
  } else if (p == eps && n == 0) next;
  # Add symbols in the input symbols list
  if (p in flg) flg[p] = 1;
  printf("%-25s %d\n", p, n);
}END{
  printf("%-25s %d\n", dm, ++maxid);
  for (p in flg) {
    if (flg[p] == 0) {
      printf("%-25s %d\n", p, ++maxid);
    }
  }
}' "$word_syms_in" > "$tmpf" ||
( echo "ERROR: Creating \"$word_syms_out\"!" >&2 && exit 1 );
( [[ "$overwrite" = false && -s "$word_syms_out" ]] &&
  cmp -s "$tmpf" "$word_syms_out" ) ||
mv "$tmpf" "$word_syms_out" ||
( echo "ERROR: Creating \"$word_syms_out\"!" >&2 && exit 1 );


# Create lexicon FST
[[ "$overwite" = false && -s "$ofst" &&
    ( ! "$ofst" -ot "$no_space_words" ) &&
    ( ! "$ofst" -ot "$lexicon_prob" ) ]] ||
gawk -v eps="$eps" -v dm="$dummy" -v ws="$wspace" \
  -v no_space_words="$no_space_words" '
BEGIN{
  if (no_space_words != "") {
    while ((getline < no_space_words) > 0) {
      NSW[$1] = 1;
    }
  }
  max_state=3;

  # Add disambiguation symbols to make backoff determinizable
  printf("%10d %10d %s %s %f\n", 0, 0, "#0", "#0", 0.0);
  printf("%10d %10d %s %s %f\n", 1, 1, "#0", "#0", 0.0);
  printf("%10d %10d %s %s %f\n", 2, 2, "#0", "#0", 0.0);

  # This arc is to consume a white space between words
  printf("%10d %10d %s %s %f\n", 1, 2, ws, eps, 0.0);

  # These arcs are used to consume the dummy HMM at the end of the CTC decoding
  printf("%10d %10d %s %s %f\n", 0, 3, dm, dm, 0.0);
  printf("%10d %10d %s %s %f\n", 1, 3, dm, dm, 0.0);

  # The word-loop state and the dummy state is the only final states
  print 1;
  print 3;
}{
  # Add word as the start of the sentence
  s=0;
  for (i=3;i<NF;++i) {
    printf("%10d %10d %s %s %f\n", s, ++max_state, $i, (i == 3 ? $1 : eps), -log($2));
    s=max_state;
  }
  printf("%10d %10d %s %s %f\n", s, 1, $i, (i == 3 ? $1 : eps), -log($2));

  # Words leaving from state 1 ARE NOT preceded by a whitespace space!
  # Words leaving from state 2 MUST BE preceded by a whitespace space!
  s = ($1 in NSW) ? 1 : 2;
  for (i=3;i<NF;++i) {
    printf("%10d %10d %s %s %f\n", s, ++max_state, $i, (i == 3 ? $1 : eps), -log($2));
    s=max_state;
  }
  printf("%10d %10d %s %s %f\n", s, 1, $i, (i == 3 ? $1 : eps), -log($2));
}' "$lexicon_prob_disambig" |
fstcompile --isymbols="$char_syms_out" --osymbols="$word_syms_out" |
fstarcsort --sort_type=ilabel > "$ofst" ||
( echo "ERROR: Creating output FST \"$ofst\"!" >&2 && exit 1 );


exit 0;
