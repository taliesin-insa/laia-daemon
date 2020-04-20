#!/bin/bash
set -e;
export LC_NUMERIC=C;

SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)";
[ ! -f "$SDIR/parse_options.inc.sh" ] && \
    echo "Missing $SDIR/parse_options.inc.sh file!" >&2 && exit 1;

column=5;
column_min=;
column_max=;
output_dumb=;
output_pdf=;
show_legend=true;
title=;
xlabel="";
ylabel="";
help_message="
Usage: ${0##*/} [options] file1 [file2 ...] [-TITLES- title1 [title2 ...]]

Example:
  ${0##*/} --column 5 --title \"Valid CER\" --ylabel CER --xlabel Epoch \\
  exp1.dat exp2.dat -TITLES- \"Exper. 1\" \"Exper. 2\"

Options:
  --column      : (type = integer, default = $column)
                  Plot the data in this column.
  --column_max  : (type = integer, default = $column_max)
  --column_min  : (type = integer, default = $column_min)
                  Use this two columns to plot the confidence area surrounding
                  the main curve.
  --output_pdf  : (type = string, default = \"$output_pdf\")
                  Plot the graph into a PDF.
  --output_dumb : (type = string, default = \"$output_dumb\")
                  Plot the graph into the terminal using the given width and
                  height characters (separated by a whitespace, e.g: \"79 24\").
  --show_legend : (type = boolean, default = $show_legend)
                  If true, show the legend/key of the plot.
  --title       : (type = string, default = \"$title\")
                  Plot title.
  --xlabel      : (type = string, default = \"$xlabel\")
                  Label for the x-axis of the histogram.
  --ylabel      : (type = string, default = \"$ylabel\")
                  Label for the y-axis of the histogram.
";
source "${SDIR}/parse_options.inc.sh" || exit 1;
[ $# -lt 1 ] && echo "$help_message" && exit 1;

files=();
titles=();
p=files;
while [ $# -gt 0 ]; do
  case "$1" in
    -TITLES-)
      p=titles;
      shift;
      ;;
    *)
      eval "$p+=('$1')";
      shift;
  esac;
done;



while [ ${#titles[@]} -lt ${#files[@]} ]; do
  titles+=("${files[${#titles[@]}]}");
done;

(
  if [ -n "$output_pdf" ]; then
    cat <<EOF
set term pdf
set output '$output_pdf'
EOF
  elif [ -n "$output_dumb" ]; then
    cat <<EOF
set term dumb $output_dumb enhanced
EOF
  fi;
  if [ "$show_legend" = true ]; then
    cat <<EOF
set key outside vertical
set key center top
EOF
  else
    echo "set key off";
  fi;
  cat <<EOF
set style data lines
set style fill solid 0.3 noborder
set xlabel '$xlabel'
set ylabel '$ylabel'
set title '$title'
plot \\
EOF

  for i in $(seq "${#files[@]}"); do
    [ -n "$column_min" -a -n "$column_max" ] && \
      echo "'${files[i-1]}' u 1:$column_min:$column_max w filledcu notitle lt $i, \\";
    echo "'${files[i-1]}' u 1:$column lt $i t '${titles[i-1]}', \\";
  done;
) | gnuplot -p;
