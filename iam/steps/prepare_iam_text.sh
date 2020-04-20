#!/bin/bash
set -e;

# Directory where the prepare.sh script is placed.
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)";
[ "$(pwd)/steps" != "$SDIR" ] && \
    echo "Please, run this script from the experiment top directory!" >&2 && \
    exit 1;
[ ! -f "$(pwd)/utils/parse_options.inc.sh" ] && \
    echo "Missing $(pwd)/utils/parse_options.inc.sh file!" >&2 && exit 1;

overwrite=false;
partition=aachen;
wspace="<space>";
help_message="
Usage: ${0##*/} [options]

Options:
  --overwrite  : (type = boolean, default = $overwrite)
                 Overwrite previously created files.
  --partition  : (type = string, default = \"$partition\")
                 Select the the lists to use: \"aachen\" or \"kws\".
  --wspace     : (type = string, default = \"$wspace\")
                 Use this symbol to represent the whitespace character.
";
source "$(pwd)/utils/parse_options.inc.sh" || exit 1;

# We will use pypy, if available, since it is much faster.
tokenize_cmd="./steps/iam_tokenize.py";
if which pypy &> /dev/null; then tokenize_cmd="pypy $tokenize_cmd"; fi;

mkdir -p data/lang/{lines,forms}/{char,word};

# Prepare word-level transcripts.
[ "$overwrite" = false -a -s "data/lang/lines/word/all.txt" ] ||
gawk '$1 !~ /^#/' "data/original/lines.txt" | cut -d\  -f1,9- |
gawk '{ $1=$1"|"; print; }' |
# Some words include spaces (e.g. "B B C" -> "BBC"), remove them.
sed -r 's| +||g' |
# Replace character | with whitespaces.
tr \| \  |
# Some contractions where separated from the words to reduce the vocabulary
# size. These separations are unreal, we join them (e.g. "We 'll" -> "We'll").
sed 's/ '\''\(s\|d\|ll\|m\|ve\|t\|re\|S\|D\|LL\|M\|VE\|T\|RE\)\b/'\''\1/g' |
sort -k1 > "data/lang/lines/word/all.txt" ||
{ echo "ERROR: Creating file data/lang/lines/word/all.txt" >&2 && exit 1; }

# Prepare character-level transcripts.
[ "$overwrite" = false -a -s "data/lang/lines/char/all.txt" ] ||
gawk -v ws="$wspace" '{
  printf("%s", $1);
  for(i=2;i<=NF;++i) {
    for(j=1;j<=length($i);++j) {
      printf(" %s", substr($i, j, 1));
    }
    if (i < NF) printf(" %s", ws);
  }
  printf("\n");
}' "data/lang/lines/word/all.txt" |
sort -k1 > "data/lang/lines/char/all.txt" ||
{ echo "ERROR: Creating file data/lang/lines/char/all.txt" >&2 && exit 1; }

# Add whitespace boundaries to the character-level transcripts.
# Note: Actually not used, but could be used in the future.
[ "$overwrite" = false -a -s "data/lang/lines/char/all_wspace.txt" ] ||
gawk -v ws="$wspace" '{ $1=$1" "ws; printf("%s %s\n", $0, ws); }' \
  "data/lang/lines/char/all.txt" \
  > "data/lang/lines/char/all_wspace.txt" ||
{ echo "ERROR: Creating file data/lang/lines/char/all_wspace.txt" >&2 &&
  exit 1; }

# Extract characters list for training.
mkdir -p "train";
[ "$overwrite" = false -a -s "train/syms.txt" ] ||
cut -d\  -f2- "data/lang/lines/char/all.txt" | tr \  \\n | sort | uniq |
gawk -v ws="$wspace" 'BEGIN{
  printf("%-12s %d\n", "<eps>", 0);
  printf("%-12s %d\n", "<ctc>", 1);
  printf("%-12s %d\n", ws, 2);
  N = 3;
}$1 != ws{
  printf("%-12s %d\n", $1, N++);
}' > "train/syms.txt" ||
{ echo "ERROR: Creating file train/syms.txt" >&2 && exit 1; }

# Split files into different partitions (train, test, valid).
mkdir -p data/lang/lines/{char,word}/"$partition";
for p in "$partition"/{tr,te,va}; do
  join -1 1 "data/part/lines/$p.lst" "data/lang/lines/char/all.txt" \
    > "data/lang/lines/char/$p.txt" ||
  { echo "ERROR: Creating file data/lang/lines/char/$p.txt" >&2 && exit 1; }
  join -1 1 "data/part/lines/$p.lst" "data/lang/lines/word/all.txt" \
    > "data/lang/lines/word/$p.txt" ||
  { echo "ERROR: Creating file data/lang/lines/word/$p.txt" >&2 && exit 1; }
  join -1 1 "data/part/lines/$p.lst" "data/lang/lines/char/all_wspace.txt" \
    > "data/lang/lines/char/${p}_wspace.txt" ||
  { echo "ERROR: Creating file data/lang/lines/char/${p}_wspace.txt" >&2 &&
    exit 1; }
done;

# Tokenize using NLTK-based tokenizer (Treebank tokenizer) and write the
# information about the word boundaries. This information is useful in order to
# create the lexicon. There are tokens that should not be preceded, in some
# cases, by a whitespace in the lexicon. Output files of this step are:
# $odir/${c}_tokenized.txt and $odir/${c}_boundaries.txt.
for p in "$partition"/{tr,te,va}; do
  tok="data/lang/lines/word/${p}_tokenized.txt";
  bnd="data/lang/lines/word/${p}_boundaries.txt";
  [[ "$overwrite" = false && -s "$tok" && -s "$bnd" &&
    ( ! "data/lang/lines/word/$p.txt" -nt "$tok" ) &&
    ( ! "data/lang/lines/word/$p.txt" -nt "$bnd" ) ]] ||
  cut -d\  -f2- "data/lang/lines/word/$p.txt" |
  $tokenize_cmd --write-boundaries "$bnd" |
  paste -d\  <(cut -d\  -f1 "data/lang/lines/word/$p.txt") - > "$tok" ||
  { echo "ERROR: Creating file $tok" >&2 && exit 1; }
done;

mkdir -p data/lang/forms/{char,word}/"$partition";
for p in tr te va; do
  txtw="data/lang/forms/word/$partition/$p.txt";
  txtc="data/lang/forms/char/$partition/$p.txt";
  tok="data/lang/forms/word/$partition/${p}_tokenized.txt";
  bnd="data/lang/forms/word/$partition/${p}_boundaries.txt";
  # Get the word-level transcript of the whole form.
  [[ "$overwrite" = false && -s "$txtw" &&
      ( ! "$txtw" -ot "data/lang/lines/word/$partition/$p.txt" ) ]] ||
  gawk 'BEGIN{ sent_id=""; }{
    if (match($0, /^([^ ]+)-[0-9]+ (.+)$/, A)) {
      if (A[1] != sent_id) {
        if (sent_id != "") printf("\n");
        printf("%s %s", A[1], A[2]);
        sent_id = A[1];
      } else {
        printf(" %s", A[2]);
      }
    }
  }END{ if (sent_id != "") printf("\n"); }' \
    "data/lang/lines/word/$partition/$p.txt" > "$txtw" ||
  { echo "ERROR: Creating file \"$txtw\"!" >&2 && exit 1; }
  # Tokenize the joint sentences.
  [[ "$overwrite" = false && -s "$tok" && -s "$bnd" &&
      ( ! "$txtw" -nt "$tok" ) && ( ! "$txtw" -nt "$bnd" ) ]] ||
  cut -d\  -f2- "$txtw" |
  $tokenize_cmd --write-boundaries "$bnd" |
  paste -d\  <(cut -d\  -f1 "$txtw") - > "$tok" ||
  { echo "ERROR: Creating file $tok" >&2 && exit 1; }
  # Prepare character-level transcripts.
  [ "$overwrite" = false -a -s "$txtc" ] ||
  gawk -v ws="$wspace" '{
    printf("%s", $1);
    for(i=2;i<=NF;++i) {
      for(j=1;j<=length($i);++j) {
        printf(" %s", substr($i, j, 1));
      }
      if (i < NF) printf(" %s", ws);
    }
    printf("\n");
  }' "$txtw" > "$txtc" ||
  { echo "ERROR: Creating file $txtc" >&2 && exit 1; }
done;

exit 0;
