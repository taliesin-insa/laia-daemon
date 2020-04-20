#!/bin/bash
set -e;
export LC_NUMERIC=C;

SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)";
[ ! -f "$SDIR/parse_options.inc.sh" ] && \
    echo "Missing $SDIR/parse_options.inc.sh file!" >&2 && exit 1;

column=1;
histogram=false;
sorted=false;
xlabel="";
help_message="
Usage: ${0##*/} [options] ...

Options:
  --column     : (type = integer, default = $column)
                 Compute statistics over the
  --histogram  : (type = boolean, default = $histogram)
                 Scale lines to have this height, keeping the aspect ratio
                 of the original image.
  --sorted     : (type = boolean, default = $sorted)
                 If true, assumes that the input file is sorted in increasing
                 order, Otherwise, it will sort it by the given --column.
  --xlabel     : (type = string, default = \"$xlabel\")
                 Label for the x-axis of the histogram.
";
source "${SDIR}/parse_options.inc.sh" || exit 1;

if [[ $# -gt 1 || "$sorted" = false ]]; then
    # If more than 1 input, or if the input is not sorted, then sort
    # everything and write to a single temporal file.
    input="$(mktemp)";
    args=( "${@}" );
    sort -n -k"$column" "${args[@]}" > "$input";
elif [[ $# -eq 0 ]]; then
    # If no input file was given and the input from stdin is sorted,
    # we still need to store stdin to a file, since we need to know
    # the total number of lines later.
    input="$(mktemp)";
    cat > "$input";
else
    # The input is just the given file.
    input="$1";
fi;

# Count number of samples in the input file (i.e. lines).
N="$(wc -l "$input" | cut -d\  -f1)";

stats=( $(gawk -v C="$column" -v N="$N" '
function ceil(v) { return (v == int(v)) ? v : int(v)+1 }
BEGIN{
  pidx[0]   = 1;  # Minimum
  pidx[1]   = ceil(0.01 * N);
  pidx[5]   = ceil(0.05 * N);
  pidx[25]  = ceil(0.25 * N);
  pidx[75]  = ceil(0.75 * N);
  pidx[95]  = ceil(0.95 * N);
  pidx[99]  = ceil(0.99 * N);
  pidx[100] = N;  # Maximum
  ## 50% percentile is treated differently since it corresponds to the median
  pidx50a = (N % 2 == 0 ? int(N / 2) : int(N / 2) + 1);
  pidx50b = int(N / 2) + 1;
}{
  if (NF < C) {
    print "The number of columns in the input file is lower than --column" > "/dev/stderr";
    exit 1;
  }
  for (p in pidx) { if(pidx[p] == NR) pval[p] = $C;  }
  if (N % 2 == 0 && (NR == pidx50a || NR == pidx50b)) pval[50] += 0.5 * $C;
  else if (NR == pidx50a) pval[50] = $C;
  S += $C;
  S2 += $C * $C;
}END{
  a = S / N;
  s = S2 / N - a * a;
  printf("%f %f %f %f %f %f %f %f %f %f %f\n", a, sqrt(s),
         pval[0], pval[1], pval[5], pval[25], pval[50],
         pval[75], pval[95], pval[99], pval[100]);
}' "$input") );

# Print statistics
echo "Mean:            ${stats[0]}";
echo "Std. Deviation:  ${stats[1]}";
echo "Percentile   0%: ${stats[2]}";
echo "Percentile   1%: ${stats[3]}";
echo "Percentile   5%: ${stats[4]}";
echo "Percentile  25%: ${stats[5]}";
echo "Percentile  50%: ${stats[6]}";
echo "Percentile  75%: ${stats[7]}";
echo "Percentile  95%: ${stats[8]}";
echo "Percentile  99%: ${stats[9]}";
echo "Percentile 100%: ${stats[10]}";

# Plot histogram
if [ "$histogram" = true ]; then
    if [ "$DISPLAY" = "" ]; then gterm="dumb"; else gterm="x11"; fi;
    if which gnuplot &> /dev/null ; then
	W="$(echo "${stats[9]} / 50" | bc -l)";
	( cat <<EOF
set term $gterm
set xrange [0:${stats[9]}]
set ylabel '% of samples'
set xlabel '$xlabel'
bin(x, w) = w * floor(x / w)
plot '$input' using (bin(\$$column, $W)):(1.0 / $N) smooth freq with boxes notitle
EOF
	) | gnuplot -p
    else
	echo "WARNING: gnuplot was not found in your PATH, ignoring histogram!" >&2;
    fi;
fi;

[ "$input" != "$1" ] && rm -f "$input";
exit 0;
