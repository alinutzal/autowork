#!/bin/bash

INPUT_FILE=""
OUTPUT=""

# Parse arguments
PARTITION="${NERSC_PARTITION:-interactive}"
TIME="${NERSC_TIME:-4:00:00}"
while getopts "i:o:q:t:" opt; do
  case $opt in
    i) INPUT_FILE="$OPTARG" ;;
    o) OUTPUT="$OPTARG" ;;
    q) PARTITION="$OPTARG" ;;
    t) TIME="$OPTARG" ;;
    *) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
  esac
done

INPUT_FILE=$(realpath "$INPUT_FILE")
OUTPUT=$(realpath "$OUTPUT")

echo "Running $0 $(date) @ $(hostname)"
echo "-----------------------------------"
echo "$(date) $(hostname)"
echo "Input File: $INPUT_FILE"
echo "Output File: $OUTPUT"

if [[ -z "$INPUT_FILE" || -z "$OUTPUT" ]]; then
  echo "Error: Missing required arguments."
  echo "Usage: $0 -i <input_file> -o <output_file>"
  exit 1
fi

# Check if the input file exists
if [[ ! -f "$INPUT_FILE" ]]; then
  echo "Error: Input file $INPUT_FILE does not exist."
  exit 1
fi

# parse the input json file.
SOURCE_DIR=$(jq -r '.source_dir' "$INPUT_FILE")
REPO_URL=$(jq -r '.repo_url' "$INPUT_FILE")
REPO_TAG=$(jq -r '.repo_tag // empty' "$INPUT_FILE")
CONFIG_PBTXT_PATH=$(jq -r '.config_pbtxt_path // empty' "$INPUT_FILE")
MODEL_NAME=$(jq -r '.model_name // empty' "$INPUT_FILE")
# Optional Triton server startup flags (e.g. "--model-control-mode=explicit --repository-poll-seconds=30")
TRITON_START_FLAGS=$(jq -r '.triton_start_flags // empty' "$INPUT_FILE")
PARTITION=$(jq -r '.partition // empty' "$INPUT_FILE")
TIME=$(jq -r '.time // empty' "$INPUT_FILE")
JOB_NAME="triton_job"

echo "Start Triton Server for validation"
echo "SOURCE_DIR: $SOURCE_DIR"
echo "OUTPUT: $OUTPUT"
echo "REPO_URL: $REPO_URL"
echo "JOB Name: ${JOB_NAME}"
echo "CONFIG_PBTXT_PATH: $CONFIG_PBTXT_PATH"
echo "MODEL_NAME: $MODEL_NAME"
echo "TRITON_START_FLAGS: $TRITON_START_FLAGS"
echo "NERSC partition: $PARTITION"
echo "Requested walltime: $TIME"

mkdir -p "${SOURCE_DIR}"

cd ${SOURCE_DIR} || { echo "Failed to change directory to $SOURCE_DIR"; exit 1; }

REPO_NAME=$(basename "$REPO_URL" .git)

if [[ ! -d "$REPO_NAME" ]]; then
  echo "Cloning repository $REPO_URL into $SOURCE_DIR"
  git clone "$REPO_URL"
fi
cd "$REPO_NAME" || { echo "Failed to change directory to $REPO_NAME"; exit 1; }

if [[ -n "$REPO_TAG" ]]; then
  git checkout "$REPO_TAG"
fi

# If a custom config.pbtxt is provided, copy it to the model directory
if [[ -n "$CONFIG_PBTXT_PATH" && -n "$MODEL_NAME" ]]; then
  if [[ -f "$CONFIG_PBTXT_PATH" ]]; then
    MODEL_CONFIG_DIR="models/$MODEL_NAME"
    mkdir -p "$MODEL_CONFIG_DIR"
    echo "Copying custom config from $CONFIG_PBTXT_PATH to $MODEL_CONFIG_DIR/config.pbtxt"
    cp "$CONFIG_PBTXT_PATH" "$MODEL_CONFIG_DIR/config.pbtxt"
  else
    echo "Warning: Custom config file not found at $CONFIG_PBTXT_PATH"
  fi
fi

 srun --job-name="$JOB_NAME" -C "gpu&hbm80g" -N 1 -G 1 -c 10 -n 1 -t "$TIME" -A m4439 \
  -q "$PARTITION" /bin/bash -c "if [[ -n \"$TRITON_START_FLAGS\" ]]; then ./scripts/start-tritonserver.sh -o \"$OUTPUT\" -- $TRITON_START_FLAGS; else ./scripts/start-tritonserver.sh -o \"$OUTPUT\"; fi" &

SRUN_PID=$!

# Wait a moment to ensure srun has submitted the job
sleep 3

# Look up the job ID by job name and user
JOB_ID=""
while [[ -z "$JOB_ID" ]]; do
  JOB_ID=$(squeue -u "$USER" -o "%i %j" -h | awk -v name="$JOB_NAME" '$2 == name {print $1}' | tail -n 1)
  if [[ -z "$JOB_ID" ]]; then
    echo "Waiting for job submission to register..."
    sleep 1
  fi
done


# Poll until job is running
echo "Polling for job $JOB_ID ($JOB_NAME) to start..."
while true; do
  STATE=$(squeue -j "$JOB_ID" -h -o "%T")
  if [[ "$STATE" == "RUNNING" ]]; then
    echo "Job $JOB_ID is RUNNING."
    break
  elif [[ -z "$STATE" ]]; then
    echo "Job $JOB_ID is no longer in the queue (exited or failed)."
    break
  else
    echo "Current state: $STATE. Waiting..."
    sleep 5
  fi
done

# wait for the Triton server to start.
sleep 10

echo "DONE $(date +%Y-%m-%dT%H:%M:%S)"