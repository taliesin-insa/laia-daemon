#!/bin/bash
set -e;
export LC_NUMERIC=C;
export LUA_PATH="$(pwd)/../../?/init.lua;$(pwd)/../../?.lua;$LUA_PATH";

# Directory where the run.sh script is placed.
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)";
[ "$(pwd)" != "$SDIR" ] &&
echo "Please, run this script from the experiment top directory!" >&2 &&
exit 1;

# Step 1. Download data.
./steps/download.sh --iam_user "$IAM_USER" --iam_pass "$IAM_PASS";

# Step 2. Prepare images.
./steps/prepare_images.sh;

# Step 3. Prepare IAM text data.
./steps/prepare_iam_text.sh --partition aachen;

# Step 4. Train the neural network.
./steps/train_lstm1d.sh --partition aachen --model_name "lstm1d_h128" --batch_size 8;
