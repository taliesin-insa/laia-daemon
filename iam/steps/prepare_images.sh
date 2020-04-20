#!/bin/bash
set -e;

# Directory where the prepare.sh script is placed.
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)";
[ "$(pwd)/steps" != "$SDIR" ] && \
    echo "Please, run this script from the experiment top directory!" >&2 && \
    exit 1;
[ ! -f "$(pwd)/utils/parse_options.inc.sh" ] && \
    echo "Missing $(pwd)/utils/parse_options.inc.sh file!" >&2 && exit 1;

height=128;
nproc="$(nproc)";
overwrite=false;
partition=lines;
help_message="
Usage: ${0##*/} [options]

Options:
  --height     : (type = integer, default = $height)
                 Scale images to have this height, keeping the aspect ratio of
                 the original image.
  --nproc      : (type = integer, default = $nproc)
                 Use this number of concurrent processes to prepare the images.
  --overwrite  : (type = boolean, default = $overwrite)
                 Overwrite previously created files.
  --partition  : (type = string, default = \"$partition\")
                 Select the \"lines\" or \"sentences\" partition.
                 Note: Typically the \"lines\" partition is used.
";
source "$(pwd)/utils/parse_options.inc.sh" || exit 1;

which convert &> /dev/null ||
( echo "ERROR: Install ImageMagick's convert" >&2 && exit 1 );

tmpd="$(mktemp -d)";

function process_image () {
  local bn="$(basename "$1" .png)";
  # Process image
  [ "$overwrite" = false -a -s "data/imgs/$partition/$bn.jpg" ] ||
  convert png:- -deskew 40% \
    -bordercolor white -border 5 -trim \
    -bordercolor white -border 20x0 +repage \
    -strip "data/imgs/$partition/$bn.jpg" ||
  ( echo "ERROR: Processing image $1" >&2 && return 1 );
  # Resize image
  [ "$overwrite" = false -a -s "data/imgs/${partition}_h$height/$bn.jpg" ] ||
  convert "data/imgs/$partition/$bn.jpg" -resize "x$height" +repage \
    -strip "data/imgs/${partition}_h$height/$bn.jpg" ||
  ( echo "ERROR: Processing image $1" >&2 && return 1 );
  return 0;
}

function wait_jobs () {
  local n=0;
  while [ $# -gt 0 ]; do
    if ! wait "$1"; then
      echo "Failed image processing:" >&2 && cat "$tmpd/$n" >&2 && return 1
    fi;
    shift 1; ((++n));
  done;
  return 0;
}

# Check that the partition was downloaded and extracted!
[ ! -d "data/original/$partition" ] &&
echo "ERROR: No data found for partition \"$partition\"!" >&2 &&
exit 1;

# Enhance images with Mauricio's tool, deskew the line, crop white borders
# and resize to the given height.
mkdir -p data/imgs/${partition}{,_h$height};
bkg_pids=();
for f in data/original/$partition/*.png; do
  process_image "$f" &> "$tmpd/${#bkg_pids[@]}" &
  bkg_pids+=("$!");
  [ "${#bkg_pids[@]}" -lt "$nproc" ] ||
  { wait_jobs "${bkg_pids[@]}" && bkg_pids=(); } ||
  exit 1;
done;
wait_jobs "${bkg_pids[@]}" || exit 1;


mkdir -p data/lists/$partition/{aachen,original};
for c in aachen original; do
  for f in data/part/$partition/$c/*.lst; do
    bn=$(basename "$f" .lst);
    [ -s "data/lists/$partition/$c/$bn.lst" ] ||
    gawk -v p="$partition" '{ print "data/imgs/"p"/"$1".jpg" }' "$f" \
      > "data/lists/$partition/$c/$bn.lst" || exit 1;
    [ -s "data/lists/$partition/$c/${bn}_h${h}.lst" ] ||
    gawk -v h="$height" -v p="$partition" \
      '{ print "data/imgs/"p"_h"h"/"$1".jpg" }' "$f" \
      > "data/lists/$partition/$c/${bn}_h${height}.lst" || exit 1;
  done;
done;

rm -rf "$tmpd";
exit 0;
