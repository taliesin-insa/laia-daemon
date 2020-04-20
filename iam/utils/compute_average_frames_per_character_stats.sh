#!/bin/bash
set -e;
export LC_NUMERIC=C;

SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)";
[ ! -f "$SDIR/compute_statistics.sh" ] && \
    echo "Missing $SDIR/compute_statistics.sh file!" >&2 && exit 1;

usage="
Usage: ${0##*/} [--histo] <width_factor> <images_dir> <transcripts_file>
  e.g: ${0##*/} 4 data/imgs_proc data/lang/chars/train.txt
";
[[ $# -ne 3 && ( $# -ne 4 || "$1" != "--histo" ) ]] && \
    echo "$usage" >&2 && exit 1;

histo=false;
[[ $# -eq 4 && "$1" = "--histo" ]] && { histo=true; shift 1; };

tmpf="$(mktemp)";
gawk -v F="$1" -v D="$2" '
BEGIN{ sexts="jpg,jpeg,png,pgm"; NE = split(sexts, exts, ","); }
{
  for (i=1;i<=NE;++i) {
    imgf = D"/"$1"."exts[i];
    if ( system("[ -f "imgf" ]") == 0 ) break;
    imgf = "";
  }
  if (imgf == "") {
    print "File "D"/"$1".{"sexts"} does not exist!" > "/dev/stderr";
    exit 1;
  }
  cmd="convert -print '\''%[width]\n'\'' "imgf" /dev/null";
  if ( (cmd | getline r) < 1) {
    print "Error obtaining width of image "imgf"!" > "/dev/stderr";
    exit 1;
  }
  close(cmd);
  num_frames = int((r / F) + 0.5)
  print num_frames / (NF - 1), $1;
}' "$3" > "$tmpf.tmp";
sort -n "$tmpf.tmp" > "$tmpf";

"$SDIR/compute_statistics.sh" --column 1 --sorted true --histogram "$histo" \
    --xlabel "Average number of frames / character" "$tmpf";

rm "$tmpf";
exit 0;
