# Step-by-step Training Guide Using IAM Database

The IAM Handwriting Database contains forms of handwritten English text which
can be used to train and test handwritten text recognizers and to perform
writer identification and verification experiments.

![Example](a01-122-02.jpg)

This folder contains the scripts to reproduce the results from the paper
"Are Multidimensional Recurrent Layers Really Necessary for Handwritten Text Recognition?", by Joan Puigcerver.

## Requirements
- [ImageMagick](https://www.imagemagick.org/):
  Needed for processing the images.
- [imgtxtenh](https://github.com/mauvilsa/imgtxtenh):
  Needed for processing the images.
- [SRILM](http://www.speech.sri.com/projects/srilm/):
  Needed to build the n-gram language model.
- [Kaldi](https://github.com/kaldi-asr/kaldi):
  Needed to decode using n-gram language models.
- [Custom Kaldi decoders](https://github.com/jpuigcerver/kaldi-decoders):
  Needed to decode using n-gram language models.
- [R](https://www.r-project.org/) _(optional, but higly recommended)_:
  Needed to compute confidence intervals.
- Brown, LOB and Wellington text corpora _(optional, but required to_
  _reproduce results from the paper)_.

## Pipeline

This section explains some details of the `run.sh` script, which will reproduce
the main experiments reported in the paper. If you are too lazy to read this
(or you are in a hurry), just type:

```bash
./steps/run.sh
```

If you have not downloaded the IAM data before, you will need to provide your
username and password for FKI's webpage (see next section). You can specify
them through the `$IAM_USER` and `$IAM_PASS` environment variables.
For instance:

```bash
IAM_USER=your_username IAM_PASS=your_password ./steps/run.sh
```

### Step 1. Download data.

The first step is to obtain the IAM dataset from the FKI's webpage. You'll need
to be registered in their website, in order to download it. Please, go to
http://www.fki.inf.unibe.ch/DBs/iamDB/iLogin/index.php and register.

One you have registered to the website, you can now download the data providing
your username and password to the `steps/download.sh` script:

```bash
./steps/download.sh --iam_user "$IAM_USER" --iam_pass "$IAM_PASS";
```

This will download the _lines_ partition of the dataset, where all the lines
from the original forms have been segmented, and the images will be placed
all together in the `data/original/lines` directory.
The script will also download the ASCII ground-truth of the dataset.

### Step 2. Prepare images.

Once you have downloaded the data, you are ready to process the line images
that will be used for training and testing your model. The image lines are
enhanced using [imgtxtenh](https://github.com/mauvilsa/imgtxtenh).
Skewing is also corrected using ImageMagick's convert. This tool is also used
to remove all white borders from the images and leaving a fixed size of
20 pixels on the left and the right of the image.

Finally, because our model requires that all input image have the same height,
all images are scaled to a fixed height of 128 pixels, while keeping the
aspect ratio.

```bash
./steps/prepare_images.sh;
```

### Step 3. Prepare IAM text data.

You will also need to process the ground-truth in order to train the neural
network and the corresponding n-gram word language models (see Step 7).

We will use (what we call) Aachen's partition of the dataset. Each set of
this partition has the following statistics:

- Train: 6161 lines from 747 forms.
- Validation: 966 lines from 115 forms.
- Test: 2915 lines from 336 forms.

This is not the official partition of the dataset, but it is widely used
for HTR experiments (notice that in other applications, like KWS, other
partitions are used).

```bash
./steps/prepare_iam_text.sh --partition aachen;
```

The ground-truth is processed in several ways to fix some of its
irregularities. First, some the characters of some words that were originally
separated by white spaces in the ground-truth are put together again
(e.g. "B B C" -> "BBC"). Secondly, the original data was trivially
(and unconsistently) tokenized by separating contractions from the words,
we put contactions attached to the word again (e.g. "I 'll" -> "I'll",
"We 've" -> "We've").

Once these irregularities have been fixed, the character-level transcripts
are produced by simply separating each of the characters from the word
and adding a `<space>` symbol to represent the whitespace character.

In order to train the n-gram language model, the word-level transcripts are
tokenized using a custom version of NLTK's PennTreebank tokenizer. The main
difference between NLTK's tokenizer and ours, is that we keep track on how
words were tokenized, in order to produce a lexicon that can recover the
original text (since we will measure the Word Error Rate on the original
word transcripts).

### Step 4. Train the neural network.

You are finally ready to train the neural network used in the final section
of the paper. Summarizing, the model consists of:

- 5 Convolutional blocks with 3x3 convolutions, LeakyReLU activations
  and batch normalization. The first 3 blocks include a MaxPooling layer,
  and the last 3 blocks use dropout with probability 0.2. The number of
  features in each block is 16, 32, 48, 64, and 80, respectively.
- 5 bidirectional LSTM recurrent layers with 256 hidden units and dropout with
  probability 0.5.
- A final linear layer with 80 output units (79 characters + CTC blank symbol).
- Training stops after 80 epochs without any improvement on the validation
  CER.


```bash
./steps/train_lstm1d.sh --partition aachen --model_name "lstm1d_h128";
```

This script will create the file `train/lstm1d_h128.t7`, where
`lstm_h${height}` is the default model name used by the training script.
If you change your height, or you change the model name with `--model_name`,
keep that in mind during the next steps.

__IMPORTANT:__ Be aware that this script may take a considerable amount of time
to run (37h on a NVIDIA Titan X) and GPU memory (10.5GB). If this is not
feasible for you, reduce the batch size (the default is 16) by passing
`--batch_size $your_batch_size` to the script, and/or reduce the early stop
epochs with `--early_stop_epochs $your_max_stop_epochs` (the default is 80).

### Step 5. Decode using only the neural network.

Once the training is finished, you can obtain the transcript directly from
the neural network, using the CTC decoding algorithm. This algorithm simply
obtains the most likely label on each frame independently and then removes
repetitions of labels, and finally it removes the instances of the CTC blank
symbol.

The script `steps/decode_net.sh` will use Laia to decode the validation and
test lines. Just type in your console the following command:

```bash
./steps/decode_net.sh "train/aachen/lstm1d_h128.t7";
```

The expected results at this point on the validation and test sets are:

| Set    | CER (%) | WER (%) |
|:------ | -------:| -------:|
| Valid. | 3.8     | 13.5    |
| Test   | 5.8     | 18.4    |

In order to obtain the word-level transcripts to compute the WER, the script
simply merges into one word everything in between the whitespace symbol.

### Step 6. Output raw network label pseudo log-likelihoods.

In order to combine the neural network output with a n-gram language model,
we first need to obtain the raw label posteriors, output by the neural
network, and transform them into _pseudo_ log-likelihoods.

This step is done by the `steps/output_net.sh` script, which first force
aligns the training transcripts to estimate the prior probability of the
labels (including the CTC blank symbol), and then creates the pseudo
log-likelihood matrices, used by Kaldi, as explained in the paper.

```bash
./steps/output_net.sh --partition aachen "train/aachen/lstm1d_h128.t7";
```

Take into account that force alignment can take a while, so be patient.

### Step 7. Decode using external n-gram language model.

Finally, the `steps/decode_lm.sh` script will create the n-gram language
model using the IAM's training text and the Brown, LOB (excluding the lines
in IAM's test set) and Wellington text corpora.

__IMPORTANT__: Unfortunately, these additional corpora have a restrictive
copyright that forbids us from publishing the files. However, these are very
commonly used in the HTR community. Your team probably has three text files
named `brown.txt`, `lob_excludealltestsets.txt` and `wellington.txt`.
Please, place these files into the `data/external` directory and proceed.
If you don't have these files, you won't be able to reproduce the results
from the paper.

```bash
./steps/decode_lm.sh --partition aachen \
    decode/lkh/forms/aachen/{va,te}_lstm1d_h128.scp;
```

The script recieves as input the log-likelihood matrices produced in the
previous step (first argument the validation, and secondly the test set).

First, it will process the external text corpora and tokenize it in the
same way as we did with the original IAM text data. And then, a lexicon
file will be built using all the available (tokenized) text data.
The lexicon is reduced to the 50000 most common words (a.k.a. tokens).

A 3-gram language model is also built using SRILM on the tokenized data,
for each text corpus independently (IAM, Brown, LOB and Wellington).
Each language model uses Kneser-Ney discounting and interpolation between
the different n-grams.
Once the four independent language models have been estimated, a final
language model is produced by interpolating them using SRILM's and the EM
algorithm.

The decoding is performed using a special decoder that we built on top of
Kaldi: `decode-lazylm-faster-mapped`. This decoder is similar to Kaldi's
`decode-faster-mapped`, but instead of asking for the complete decoding
transducer _HCLG_, you pass the _HCL_ and _G_ transducers separately and the
composition is done dynamically during decoding. During decoding, a beam
prunning threshold of 65 was used reduce the decoding time
(which is already very high).

__IMPORTANT__: This step is very slow, if you have access to a Sun Grid Engine
(SGE) cluster, we encourage you to use `qsub` to speed up the decoding.
Please use the `--qsub_opts` option to costumize the options passed to `qsub`
(options regarding the number of tasks are automatically set).

```bash
./steps/decode_lm.sh --qsub_opts "-l h_vmem=32G,h_rt=8:00:00" train/lstm1d_h128.t7
```

The expected results at this point are:

| Set    | CER (%) | WER (%) |
|:------ | -------:| -------:|
| Valid. | 2.9     | 9.2     |
| Test   | 4.4     | 12.2    |

In order to compute the WER, we obtain the character-level alignment from
the decoding and put all characters between whitespaces together. We can
recover from tokenization, since kept this information in the lexicon
(notice that the output of the LM are _tokens_, not original _words_).

## Any problem?

If you have any issue reproducing the results of the paper, please contact the
author at joapuipe@prhlt.upv.es.
