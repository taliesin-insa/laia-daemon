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
wspace="<space>";
help_message="
Usage: ${0##*/} [options] text1 [text2 ...]

Arguments:
  text1 ...    : External text files to process
                 (e.g. data/external/brown.txt data/external/wellington.txt).
Options:
  --overwrite  : (type = boolean, default = $overwrite)
                 Overwrite previously created files.
  --wspace     : (type = string, default \"$wspace\")
                 Use this symbol to represent the whitespace character.
";
source "$(pwd)/utils/parse_options.inc.sh" || exit 1;
[ $# -lt 1 ] && echo "$help_message" >&2 && exit 1;

# Parse arguments
corpora=();
while [ $# -gt 0 ]; do
  [[ ( ! -s "$1" ) ]] && echo "File \"$1\" does not exist!" && exit 1;
  corpora+=("$1");
  shift;
done;

# We will use pypy, if available, since it is much faster.
tokenize_cmd="./steps/iam_tokenize.py";
if which pypy &> /dev/null; then tokenize_cmd="pypy $tokenize_cmd"; fi;

mkdir -p data/lang/external/{char,word};

# 1. We convert some special sequences to UTF-8 characters, such as a*?1 -> ä,
# a*?2 -> á, a*?3 -> à, n*?4 -> ñ, etc.
# 2. Since IAM does not contain these characters, trasliterate all UTF-8 codes
# to reduce the number of tokens in the LM.
# 3. Put abbrev. like 's, 't, 'd, etc. together with their word, since NLTK will
# tokenize this later. (Save this as word/external/$c.txt).
# 4. Then, tokenize using NLTK default tokenizer (Treebank tokenizer) and
# write the information about the word boundaries. This information is useful
# in order to create the lexicon. There are tokens that should not be preceded,
# in some cases, by a whitespace in the lexicon
# (outputs: word/external/${c}_tokenized.txt and
# word/external/${c}_boundaries.txt).
# 5. Finally, convert the original word-level transcript (word/external/$c.txt)
# to a character-level transcript (char/external/$c.txt).
for f in "${corpora[@]}"; do
  c="$(basename "$f")"; c="${c%.*}";
  txt="data/lang/external/word/${c}.txt";
  tok="data/lang/external/word/${c}_tokenized.txt";
  bnd="data/lang/external/word/${c}_boundaries.txt";
  [[ "$overwrite" = false && -s "$tok" && -s "$bnd" && ( ! "$txt" -ot "$f" ) &&
      ( ! "$tok" -ot "$f" ) && ( ! "$bnd" -ot "$f" ) ]] ||
  ./steps/make_utf8_WLOB.sh < "$f" |
  iconv -f utf-8 -t ascii//TRANSLIT |
  sed 's/ '\''\(s\|d\|ll\|m\|ve\|t\|re\|S\|D\|LL\|M\|VE\|T\|RE\)\b/'\''\1/g' |
  tee "$txt" |
  $tokenize_cmd --write-boundaries "$bnd" > "$tok" ||
  { echo "ERROR: Creating file \"$tok\"!" >&2 && exit 1; }

  # Prepare character-level transcripts.
  [[ "$overwrite" = false && -s "data/lang/external/char/$c.txt" &&
      ( ! "data/lang/external/char/$c.txt" -ot "$txt" ) ]] ||
  gawk -v ws="$wspace" '{
    for(i=1;i<=NF;++i) {
      for(j=1;j<=length($i);++j) {
        printf(" %s", substr($i, j, 1));
      }
      if (i < NF) printf(" %s", ws);
    }
    printf("\n");
  }' "$txt" > "data/lang/external/char/$c.txt" ||
  { echo "ERROR: Creating file data/lang/external/char/$c.txt" >&2 && exit 1; }
done;

exit 0;
