#!/bin/bash
set -e;

SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)";
[ "$(pwd)/utils" = "$SDIR" ] || {
    echo "Run the script from \"$(dirname $SDIR)\"!" >&2 && exit 1;
}
[ ! -f "$(pwd)/utils/parse_options.inc.sh" ] && \
    echo "Missing $(pwd)/utils/parse_options.inc.sh file!" >&2 && exit 1;

ctc="<ctc>";
help_message="
Usage: ${0##*/} [options] syms input_rspecifier
";
source utils/parse_options.inc.sh || exit 1;
[ $# -ne 2 ] && echo "$help_message" >&2 && exit 1;

[ ! -s "$1" ] && echo "ERROR: File \"$2\" was not found!" >&2 && exit 1;

copy-matrix "$2" ark,t:- | gawk '{
 if ($2 == "[") printf("%s", $1);
 else {
   maxi = ($NF == "]" ? NF - 1 : NF);
   maxs = 1;
   for (i = 2; i <= maxi; ++i) {
     if ($i > $maxs) maxs=i;
   }
   printf(" %d", maxs);
   if ( $NF == "]" ) printf("\n");
 }
}' | gawk '{
 printf("%s", $1);
 for (i=2; i <= NF; ++i) if (i == 2 || $i != $(i - 1)) printf(" %s", $i);
 printf("\n");
}' | gawk -v ctc="$ctc" -v SF="$1" '
BEGIN{
  while ((getline < SF) > 0) { S[$2] = $1; if ($1 == ctc) ctc_int=$2; }
}{
 printf("%s", $1);
 for (i=2; i <= NF; ++i) if ($i != ctc_int) printf(" %s", S[$i]);
 printf("\n");
}'
