#!/bin/bash
set -e;
export LC_NUMERIC=C;

SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)";
[ "$(pwd)/utils" = "$SDIR" ] || {
    echo "Run the script from \"$(dirname $SDIR)\"!" >&2 && exit 1;
}
[ ! -f "$(pwd)/utils/parse_options.inc.sh" ] && \
    echo "Missing $(pwd)/utils/parse_options.inc.sh file!" >&2 && exit 1;

eps="<eps>";
help_message="
Usage: ${0##*/} [options] symbol syms input_rspecifier output_wspecifier

Description:
  Add a fake frame at the start and at the end of each utterance, with a
  large probability (~1.0) for a particular symbol, and a low probability
  (~0.0) for the rest of the symbols. E.g: add a fake whitespace frame at
  the start and at the end of lines.
  $ add_border_fake_frames.sh \"<wspace>\" symbs.txt ark:lkh.inp ark:lkh.out

Options:
  --eps               : (type = string, default = \"$eps\")
                        Token representing the epsilon symbol.
";
source utils/parse_options.inc.sh || exit 1;
[ $# -ne 4 ] && echo "$help_message" >&2 && exit 1;

symbol="$1";
syms="$2";
inp_rspecifier="$3";
out_wspecifier="$4";

# Get the number of symbols (including CTC, but excluding epsilon) and
# the ID of the whitespace symbol.
info=( $(gawk -v eps="$eps" -v ws="$symbol" '{
  if ($1 != eps) N++;
  if ($1 == ws) wss=$2;
}END{ print N, wss }' "$syms") );

# Add frames to all utterances in the input.
copy-matrix "$inp_rspecifier" ark,t:- |
gawk -v ND="${info[0]}" -v ws="${info[1]}" '
  function add_fake_frame(n) {
    infv=-3.4 * 10^38;
    for (i = 1; i < ws; ++i) { printf(" %g", infv); }
    printf(" %g", 0.0);
    for (i = ws + 1; i <= ND; ++i) { printf(" %g", infv); }
  }{
    S = 1; E = NF;
    if ($NF == "]") { E = NF - 1; }
    # Print a fake frame at the start of the utterance.
    if ($2 == "[") {
      printf("%s [\n", $1);
      add_fake_frame(); printf("\n");
      S=3;
    }
    # Print the original frame.
    if (S <= E) {
      for (i = S; i <= E; ++i) { printf(" %g", $i); } printf("\n");
    }
    # Print a fake frame at the end of the utterance.
    if ($NF == "]") { add_fake_frame(); printf(" ]\n"); }
  }
' | copy-matrix ark,t:- "$out_wspecifier" || exit 1;

exit 0;
