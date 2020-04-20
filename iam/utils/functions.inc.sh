#!/bin/bash

### This function prints an error message and exits from the shell.
function error () {
    local cinfo=( $(caller) );
    echo "$(date "+%F %T") [${cinfo[1]##*/}:${cinfo[0]}] ERROR: $@" >&2;
    exit 1;
}

### This function prints an error message, but does not exit from shell.
function error_continue () {
    local cinfo=( $(caller) );
    echo "$(date "+%F %T") [${cinfo[1]##*/}:${cinfo[0]}] ERROR: $@" >&2;
    return 1;
}

### This function shows a warning message.
function warning {
    local cinfo=( $(caller) );
    echo "$(date "+%F %T") [${cinfo[1]##*/}:${cinfo[0]}] WARNING: $@" >&2;
    return 0;
}

### This function shows a info message.
function msg {
    local cinfo=( $(caller) );
    echo "$(date "+%F %T") [${cinfo[1]##*/}:${cinfo[0]}] INFO: $@" >&2;
    return 0;
}

function nltk_tokenize {
    python -c '
import sys
from nltk.tokenize import word_tokenize
for l in sys.stdin:
  l = l.strip()
  print " ".join(word_tokenize(l))
'
}

### Use this function the check if a set of files exists, are readable and not
### empty.
### Examples:
### $ check_files exist not_exists
### ERROR: File \"not_exists\" does not exist!"
function check_files {
    while [ $# -gt 0 ]; do
        [ -f "$1" ] || error "File \"$1\" does not exist!";
        [ -s "$1" ] || error "File \"$1\" is empty!";
        [ -r "$1" ] || error "File \"$1\" cannot be read!";
        shift;
    done;
}

### This function checkes whether a list of executables are available
### in the user's PATH or not.
### Examples:
### $ check_execs HERest cp
### $ check_execs HERest2 cp2
### ERROR: Executable "HERest2" is missing in your PATH!
### $ check_execs HERest cp2
### ERROR: Executable "cp2" is missing in your PATH!
function check_execs () {
    while [ $# -gt 0 ]; do
	which "$1" &> /dev/null || \
	    error "Executable \"$1\" is missing in your PATH!";
	shift;
    done;
}

### Use this function to check wheter a set of directories exist and are
### accessible.
function check_dirs {
    while [ $# -gt 0 ]; do
        [ -d "$1" ] || error "Directory \"$1\" does not exist!";
        [ -r "$1" -a -x "$1" ] || error "Directory \"$1\" cannot be accessed!";
        shift;
    done;
}

### This function creates a bunch of directories with mkdir -p and prints
### a friendly error message if any of them fails.
function make_dirs () {
    while [ $# -gt 0 ]; do
        mkdir -p "$1" || error "Directory \"$1\" could not be created!";
        shift;
    done;
}

### This function normalizes a floating point number.
### Examples:
### $ normalize_float 3
### 3
### $ normalize_float 133333333333333
### 1.33333333e+14
function normalize_float () {
    [ $# -eq 1 ] || error "Usage: normalize_float <f>" || return 1;
    LC_NUMERIC=C printf "%.8g" "$1";
    return 0;
}

### Find all archives with the given prefix in some directory, and append
### the Kaldi rxspec names to the given array (files with the path format
### like DIR/PREFIX.*.ark{,.gz,.bz,.bz2} are accepted).
### e.g: add_archives_from dir $HOME/experiment lattice lattice_array
function add_archives_from_dir () {
    [[ $# -ne 3 || ( ! -d "$1" ) ]] && \
        error "Usage: add_archives_from_dir dir prefix array_name";
    local arx="";
    for arx in $(find "$1" -maxdepth 1 -name "$2.*.ark*" | sort -V); do
        if [ "${arx##*.}" = ark ]; then
            eval "$3+=(\"ark:$arx\");";
        elif [ "${arx##*.}" = gz ]; then
            eval "$3+=(\"ark:gunzip -c $arx|\");";
        elif [ "${arx##*.}" = bz -o "${arx##*.}" = bz2 ]; then
            eval "$3+=(\"ark:bzip2 -dc $arx|\");";
        fi;
    done;
    return 0;
}

function add_kaldi_rspecifiers_to_array () {
    [[ $# -lt 3 ]] && \
        error "Usage: add_kaldi_rspecifiers_to_array array_name ark_prefix inp1 [inp2 ...]";
    array_name="$1";
    ark_prefix="$2";
    shift 2;
    [ -z "$array_name" ] && error "The given array name is empty!";
    while [ $# -gt 0 ]; do
        if [[ "${1:0:4}" = "ark:" || "${1:0:4}" = "scp:" ]]; then
            eval "$array_name+=(\"$1\");";
        elif [[ -f "$1" ]]; then
            if [[ "${1:(-4)}" = ".ark" ]]; then
                eval "$array_name+=(\"ark:$1\");";
            elif [[ "${1:(-4)}" = ".scp" ]]; then
                eval "$array_name+=(\"scp:$1\");";
            elif [[ "${1:(-7)}" = ".ark.gz" ]]; then
                eval "$array_name+=(\"ark:gunzip -c '$1'|\");";
            elif [[ "${1:(-7)}" = ".scp.gz" ]]; then
                eval "$array_name+=(\"scp:gunzip -c '$1'|\");";
            elif [[ "${1:(-7)}" = ".ark.bz" || "${1:(-7)}" = ".ark.bz2" ]]; then
                eval "$array_name+=(\"ark:bzip2 -dc '$1'|\");";
            elif [[ "${1:(-7)}" = ".scp.bz" || "${1:(-7)}" = ".scp.bz2" ]]; then
                eval "$array_name+=(\"scp:bzip2 -dc '$1'|\");";
            else
                warning "Assuming that \"$1\" is an archive file...";
                eval "$array_name+=(\"ark:$1\");";
            fi;
        elif [[ -d "$1" ]]; then
            local empty_dir=1;
            for arx in $(find "$1" -maxdepth 1 -name "$ark_prefix.*.ark*" | sort -V); do
                add_kaldi_rspecifiers_to_array "$array_name" "$ark_prefix" "$arx" || return 1;
                empty_dir=0;
            done;
            [ "$empty_dir" -eq 1 ] && \
                warning "Directory \"$1\" does not contain any file matching $ark_prefix.*.ark*";
        else
            error "Rspecifiers cannot be inferred from \"$1\"!" || return 1;
        fi;
        shift 1;
    done;
    return 0;
}