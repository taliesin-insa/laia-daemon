#!/usr/bin/env python2.7

import argparse
import sys

def levenshtein(u, v):
    prev = None
    curr = [0] + range(1, len(v) + 1)
    # Operations: (SUB, DEL, INS)
    prev_ops = None
    curr_ops = [(0, 0, i) for i in range(len(v) + 1)]
    for x in xrange(1, len(u) + 1):
        prev, curr = curr, [x] + ([None] * len(v))
        prev_ops, curr_ops = curr_ops, [(0, x, 0)] + ([None] * len(v))
        for y in xrange(1, len(v) + 1):
            delcost = prev[y] + 1
            addcost = curr[y - 1] + 1
            subcost = prev[y - 1] + int(u[x - 1] != v[y - 1])
            curr[y] = min(subcost, delcost, addcost)
            if curr[y] == subcost:
                (n_s, n_d, n_i) = prev_ops[y - 1]
                curr_ops[y] = (n_s + int(u[x - 1] != v[y - 1]), n_d, n_i)
            elif curr[y] == delcost:
                (n_s, n_d, n_i) = prev_ops[y]
                curr_ops[y] = (n_s, n_d + 1, n_i)
            else:
                (n_s, n_d, n_i) = curr_ops[y - 1]
                curr_ops[y] = (n_s, n_d, n_i + 1)
    return curr[len(v)], curr_ops[len(v)]


if __name__ == '__main__':
    parser = argparse.ArgumentParser(
        description='''Compute the error operations (total errors, subtitutions,
        insertions, deletions) between a transcript and its reference.''')
    parser.add_argument('reference', type=argparse.FileType('r'),
                        help='''Text file containing the ID of each sentence
                        and its reference transcript.''')
    parser.add_argument('hypothesis', type=argparse.FileType('r'),
                        default=sys.stdin,
                        help='''Text file containing the ID of each sentence
                        and its hypothesis transcript.''')
    args = parser.parse_args()

    # Load references
    ref = {}
    for line in args.reference:
        line = line.split()
        ref[line[0]] = line[1:]
    # Load hypotheses
    hyp = {}
    for line in args.hypothesis:
        line = line.split()
        hyp[line[0]] = line[1:]
    # Compute errors
    for r in ref:
        len_r = len(ref[r])
        if r in hyp:
            len_h = len(hyp[r])
            n_err, (n_sub, n_del, n_ins) = levenshtein(ref[r], hyp[r])
            print '%s %d %d %d %d %d %d' % (r, n_err, n_sub, n_del, n_ins, len_r, len_h)
        else:
            print '%s %d %d %d %d %d %d' % (r, len_r, 0, len_r, 0, len_r, 0)
