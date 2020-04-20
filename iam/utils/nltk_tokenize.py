#!/usr/bin/env python2.7

import argparse
import re
import sys

# This is a custom modification of the TreebankWordTokenizer.
# The original tokenizer replaced double quotes with `` and ''.
# Since do not want to add new symbols to the sentences, we keep
# the double quotes symbols.
# This also makes trivial the function span_tokens, which
# TreebakWordTokenizer did not have implemented.
# Adapted from: http://www.nltk.org/_modules/nltk/tokenize/treebank.html
class CustomTreebankWordTokenizer:
    #starting quotes
    STARTING_QUOTES = [
        (re.compile(r'^\"'), r'"'),              # This line changes: do not replace "
        (re.compile(r'(``)'), r' \1 '),
        (re.compile(r'([ (\[{<])"'), r'\1 " '),  # This line changes: do not replace "
    ]

    #punctuation
    PUNCTUATION = [
        (re.compile(r'([:,])([^\d])'), r' \1 \2'),
        (re.compile(r'([:,])$'), r' \1 '),
        (re.compile(r'\.\.\.'), r' ... '),
        (re.compile(r'[;@#$%&]'), r' \g<0> '),
        (re.compile(r'([^\.])(\.)([\]\)}>"\']*)\s*$'), r'\1 \2\3 '),
        (re.compile(r'[?!]'), r' \g<0> '),
        (re.compile(r"([^'])' "), r"\1 ' "),
    ]

    #parens, brackets, etc.
    PARENS_BRACKETS = [
        (re.compile(r'[\]\[\(\)\{\}\<\>]'), r' \g<0> '),
        (re.compile(r'--'), r' -- '),
    ]

    #ending quotes
    ENDING_QUOTES = [
        (re.compile(r'"'), ' " '),              # This line changes: do not replace "
        (re.compile(r'(\S)(\'\')'), r'\1 \2 '),

        (re.compile(r"([^' ])('[sS]|'[mM]|'[dD]|') "), r"\1 \2 "),
        (re.compile(r"([^' ])('ll|'LL|'re|'RE|'ve|'VE|n't|N'T) "), r"\1 \2 "),
    ]

    # List of contractions adapted from Robert MacIntyre's tokenizer.
    CONTRACTIONS2 = [re.compile(r"(?i)\b(can)(not)\b"),
                     re.compile(r"(?i)\b(d)('ye)\b"),
                     re.compile(r"(?i)\b(gim)(me)\b"),
                     re.compile(r"(?i)\b(gon)(na)\b"),
                     re.compile(r"(?i)\b(got)(ta)\b"),
                     re.compile(r"(?i)\b(lem)(me)\b"),
                     re.compile(r"(?i)\b(mor)('n)\b"),
                     re.compile(r"(?i)\b(wan)(na) ")]
    CONTRACTIONS3 = [re.compile(r"(?i) ('t)(is)\b"),
                     re.compile(r"(?i) ('t)(was)\b")]
    CONTRACTIONS4 = [re.compile(r"(?i)\b(whad)(dd)(ya)\b"),
                     re.compile(r"(?i)\b(wha)(t)(cha)\b")]

    def tokenize(self, text):
        for regexp, substitution in self.STARTING_QUOTES:
            text = regexp.sub(substitution, text)

        for regexp, substitution in self.PUNCTUATION:
            text = regexp.sub(substitution, text)

        for regexp, substitution in self.PARENS_BRACKETS:
            text = regexp.sub(substitution, text)

        #add extra space to make things easier
        text = " " + text + " "

        for regexp, substitution in self.ENDING_QUOTES:
            text = regexp.sub(substitution, text)

        for regexp in self.CONTRACTIONS2:
            text = regexp.sub(r' \1 \2 ', text)
        for regexp in self.CONTRACTIONS3:
            text = regexp.sub(r' \1 \2 ', text)

        # We are not using CONTRACTIONS4 since
        # they are also commented out in the SED scripts
        # for regexp in self.CONTRACTIONS4:
        #     text = regexp.sub(r' \1 \2 \3 ', text)

        return text.split()

    def span_tokens(self, text):
        tokens = self.tokenize(text)
        spans = []
        i = 0
        for tok in tokens:
            spans.append((i, i + len(tok)))
            i += len(tok)
            if i < len(text) and str.isspace(text[i]):
                i += 1
        return spans


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument(
        'input', type=argparse.FileType('r'), nargs='?', default=sys.stdin,
        help='input text file')
    parser.add_argument(
        'output', type=argparse.FileType('w'), nargs='?', default=sys.stdout,
        help='output text file')
    parser.add_argument(
        '--write-boundaries', type=argparse.FileType('w'), default=None,
        help='write token boundaries to this file')
    parser.add_argument(
        '--boundary', type=str, default='\\s',
        help='use this token as the boundary token')
    args = parser.parse_args()

    tokenizer = CustomTreebankWordTokenizer()
    lexicon = {}
    for line in args.input:
        line = re.sub('\s+', ' ', line.strip())
        spans = tokenizer.span_tokens(line)
        tokens = map(lambda x: line[x[0]:x[1]], spans)
        args.output.write(' '.join(tokens) + '\n')
        if args.write_boundaries is not None:
            for i in xrange(len(tokens)):
                pron = [args.boundary, tokens[i], args.boundary]
                if i > 0 and spans[i][0] == spans[i - 1][1]:
                    pron = pron[1:]
                if i < len(tokens) - 1 and spans[i][1] == spans[i + 1][0]:
                    pron = pron[:-1]
                pron = tuple(pron)
                if tokens[i] not in lexicon: lexicon[tokens[i]] = {}
                if pron not in lexicon[tokens[i]]: lexicon[tokens[i]][pron] = 1
                else: lexicon[tokens[i]][pron] += 1

    if args.write_boundaries:
        lexicon = lexicon.items()
        lexicon.sort()
        for (token, prons) in lexicon:
            for pron, cnt in prons.iteritems():
                args.write_boundaries.write('%s\t%d\t%s\n' % (token, cnt, ' '.join(pron)))
        args.write_boundaries.close()

    args.output.close()
