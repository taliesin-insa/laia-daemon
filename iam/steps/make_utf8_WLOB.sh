#!/bin/bash
set -e;
export LC_NUMERIC=C;

sed -r 's|a\*\?1|ä|g;' |
sed -r 's|a\*\?2|á|g;s|e\*\?2|é|g;s|i\*\?2|í|g;s|o\*\?2|ó|g;s|u\*\?2|ú|g;s|A\*\?2|Á|g;s|E\*\?2|É|g;s|I\*\?2|Í|g;s|O\*\?2|Ó|g;s|U\*\?2|Ú|g;' |
sed -r 's|a\*\?3|à|g;s|e\*\?3|è|g;s|i\*\?3|ì|g;s|o\*\?3|ò|g;s|u\*\?3|ù|g;s|A\*\?3|À|g;s|E\*\?3|È|g;s|I\*\?3|Ì|g;s|O\*\?3|Ò|g;s|U\*\?3|Ù|g;' |
sed -r 's|a\*\?4|ã|g;s|A\*\?4|Ã|g;s|n\*\?4|ñ|g;s|N\*\?4|Ñ|g;' |
sed -r 's|a\*\?5|â|g;s|e\*\?5|ê|g;s|i\*\?5|î|g;s|o\*\?5|ô|g;s|u\*\?5|û|g;s|A\*\?5|Â|g;s|E\*\?5|Ê|g;s|I\*\?5|Î|g;s|O\*\?5|Ô|g;s|U\*\?5|Û|g;' |
sed -r 's|c\*\?6|ç|g;s|C\*\?6|Ç|g;' |
sed -r 's|s\*\?10|š|g;s|S\*\?10|Š|g;' |
sed -r 's|l\*\?11|ł|g;s|L\*\?11|Ł|g;';