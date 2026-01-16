#!/bin/bash

# Default values for arguments
INPUT_FILE=""
OUTFILE=""
NUM_WORKERS=6
MAX_EVENTS=1
CHAINNAME="CKF_LEGACY"
SETUP_FILE=""
TRITON_MODEL_NAME=""
TRITON_CONFIG=""
# New options: skip events / first event
SKIP_EVENTS=0
FIRST_EVENT=""
# Model version option
TRITON_MODEL_VERSION=""

# Function to display usage
usage() {
    echo "Usage: $0 -i <input_file> -o <output_file>"
    echo "  -i <input_file>   : Input file (e.g., RDO file list)"
    echo "  -o <output_file>  : Output file"
    echo "  -j <num_workers>  : Number of workers (default: $NUM_WORKERS)"
    echo "  -m <max_events>  : Maximum number of events to process (default: $MAX_EVENTS)"
    echo "  -c <chainname>   : Chain name (default: $CHAINNAME)"
    echo "  -s <setup_file>   : Setup file (default: $SETUP_FILE)"
    echo "  -p <triton_model_name> : Triton model name (default: $TRITON_MODEL_NAME)"
    echo "  -u <triton_url>   : Triton URL (default: $TRITON_URL)"
    echo "  -v <triton_model_version> : Triton model version (optional)"
    echo "  -h                : Display this help message"
    exit 1
}

# Parse arguments
while getopts "i:o:j:m:c:s:p:u:v:k:e:" opt; do
    case $opt in
        i) INPUT_FILE="$OPTARG" ;;
        o) OUTFILE="$OPTARG" ;;
        j) NUM_WORKERS="$OPTARG" ;;
        m) MAX_EVENTS="$OPTARG" ;;
        c) CHAINNAME="$OPTARG" ;;
        s) SETUP_FILE="$OPTARG" ;;
        p) TRITON_MODEL_NAME="$OPTARG" ;;
        u) TRITON_CONFIG="$OPTARG" ;;
        v) TRITON_MODEL_VERSION="$OPTARG" ;;
        k) SKIP_EVENTS="$OPTARG" ;;
        e) FIRST_EVENT="$OPTARG" ;;
        h) usage ;;
        \?) echo "Invalid option: -$OPTARG" >&2; usage exit 1 ;;
    esac
done

OUTFILE=$(realpath "$OUTFILE")
RUN_DIR=$(dirname "$OUTFILE")
RUN_DIR=$(realpath "$RUN_DIR")
TRITON_CONFIG=$(realpath "$TRITON_CONFIG")

# Main script logic
echo "Running $0 \n $(date) @ $(hostname)"
echo "-----------------------------------"
echo "Input File: $INPUT_FILE"
echo "Run Directory: $RUN_DIR"
echo "Output File: $OUTFILE"
echo "Number of Workers: $NUM_WORKERS"
echo "Max Events: $MAX_EVENTS"
echo "Chain Name: $CHAINNAME"
echo "Setup File: $SETUP_FILE"
echo "Triton Model Name: $TRITON_MODEL_NAME"
echo "Triton Server Config: $TRITON_CONFIG"


RDO_FILENAME=$(cat ${INPUT_FILE} | paste -sd ',')
echo $RDO_FILENAME

source "workflow/scripts/deactivate_python_env.sh"

source /global/cfs/cdirs/atlas/scripts/setupATLAS.sh
setupATLAS

if [[ -f "$SETUP_FILE" ]]; then
    SETUP_FILE=$(realpath "$SETUP_FILE")
    echo "Set up environment from $SETUP_FILE"
    source workflow/scripts/setup_athena_from_json.sh
    setup_athena_from_json "$SETUP_FILE"
else
    echo "Warning: Setup file $SETUP_FILE not found"
    echo "Using the default setup: \"Athena,main,latest,here\""
    asetup Athena,main,latest,here
fi

export ATHENA_CORE_NUMBER=$NUM_WORKERS

cd ${RUN_DIR} || { echo "Failed to change directory to ${RUN_DIR}"; exit 1; }
echo "Running ${CHAINNAME} in ${RUN_DIR} with ${NUM_WORKERS} workers"

# Extract unique identifiers for directory naming to avoid conflicts
ATH_DEV_NAME="default"
TRITON_DEV_NAME="none"

# Extract ath_dev_name from setup file path if available
if [[ -n "$SETUP_FILE" && "$SETUP_FILE" =~ athena\.([^.]+)\.([^.]+)\.built\.json$ ]]; then
    # Pattern: athena.{prefix}.{ath_dev_name}.built.json
    # Use both matched items for more unique identifier
    ATH_DEV_NAME="${BASH_REMATCH[1]}_${BASH_REMATCH[2]}"
fi

# Extract triton_dev_name from triton config file path if available
if [[ -n "$TRITON_CONFIG" && "$TRITON_CONFIG" =~ triton_server\.([^.]+)\.ready\.json$ ]]; then
    TRITON_DEV_NAME="${BASH_REMATCH[1]}"
fi

echo "Athena Dev Name: $ATH_DEV_NAME"
echo "Triton Dev Name: $TRITON_DEV_NAME"

if [ -f "PoolFileCatalog.xml" ]; then
    echo "Cleanup workarea."
    rm InDetIdDict.xml PoolFileCatalog.xml hostnamelookup.tmp eventLoopHeartBeat.txt
fi

# if TRITON_CONFIG is provided, set the Triton URL, port, and model version if not set by user
if [[ -n "$TRITON_CONFIG" ]]; then
    echo "Using Triton Server configuration from $TRITON_CONFIG"
    TRITON_URL=$(jq -r '.url' "$TRITON_CONFIG")
    if [[ -z "$TRITON_URL" ]]; then
        echo "Error: Triton URL not found in $TRITON_CONFIG"
        exit 1
    fi
    TRITON_PORT=$(jq -r '.port' "$TRITON_CONFIG")
    if [[ -z "$TRITON_PORT" ]]; then
        echo "Error: Triton port not found in $TRITON_CONFIG"
        echo "Using default port 8001"
        TRITON_PORT=8001
    fi
    # Read model_version from config if not set by user
    if [[ -z "$TRITON_MODEL_VERSION" ]]; then
        TRITON_MODEL_VERSION=$(jq -r '.model_version // empty' "$TRITON_CONFIG")
        if [[ -n "$TRITON_MODEL_VERSION" ]]; then
            echo "Model version set from config: $TRITON_MODEL_VERSION"
        fi
    fi
else
    TRITON_URL="localhost"
    TRITON_PORT=8001
fi
echo "Triton URL: $TRITON_URL"
echo "Triton Port: $TRITON_PORT"
echo "Triton Model Version: $TRITON_MODEL_VERSION"
if [[ -n "$TRITON_MODEL_VERSION" ]]; then
    TRITON_MODEL_PATH="${TRITON_MODEL_NAME}/${TRITON_MODEL_VERSION}"
else
    TRITON_MODEL_PATH="$TRITON_MODEL_NAME"
fi
echo "Full Triton Model Path: $TRITON_MODEL_PATH"

DETECTOR_CONDITIONS="all:OFLCOND-MC15c-SDR-14-05"
GEOMETRY_VERSION="all:ATLAS-P2-RUN4-03-00-00"

# Set feature names based on model
# Note: module_id extraction requires C++ recompilation - using 15 features for now
if [[ "$TRITON_MODEL_NAME" == "ModuleMap" ]]; then
    FEATURE_NAMES="x,y,z,module_id,hit_id,r,phi,eta,cluster_r_1,cluster_phi_1,cluster_z_1,cluster_eta_1,cluster_r_2,cluster_phi_2,cluster_z_2,cluster_eta_2"
    FEATURE_FLAG="flags.Tracking.GNN.Triton.features=\"$FEATURE_NAMES\"; "
else
    FEATURE_FLAG=""
fi

if [[ "$CHAINNAME" == "CKF_LEGACY" ]]; then
    mkdir ckf_legacy
    cd ckf_legacy || { echo "Failed to create or change directory to ckf_legacy"; exit 1; }
    Reco_tf.py \
        --CA 'all:True' --autoConfiguration 'everything' \
        --conditionsTag ${DETECTOR_CONDITIONS} \
        --geometryVersion ${GEOMETRY_VERSION} \
        --multithreaded 'True' \
        --steering 'doRAWtoALL' \
        --digiSteeringConf 'StandardInTimeOnlyTruth' \
        --postInclude 'all:PyJobTransforms.UseFrontier' \
        --preInclude 'all:Campaigns.PhaseIIPileUp200' 'InDetConfig.ConfigurationHelpers.OnlyTrackingPreInclude' \
        --preExec 'flags.Tracking.ITkMainPass.maxSctHoles = [4]; flags.Tracking.ITkMainPass.maxPixelHoles = [4]; flags.Tracking.ITkMainPass.maxHoles = [4]; flags.Tracking.ITkMainPass.minClusters = [7,7,7]; flags.Tracking.ITkMainPass.minSiNotShared = [5,5,5] ' \
        --inputRDOFile "${RDO_FILENAME}" \
        --outputAODFile "${OUTFILE}"  \
        --jobNumber '1' \
        --athenaopts='--loglevel=INFO' \
        --maxEvents ${MAX_EVENTS} \
        --skipEvents ${SKIP_EVENTS} ${FIRST_EVENT:+--firstEvent ${FIRST_EVENT}}
elif [[ "$CHAINNAME" == "GNN4ITk_ML_LOCAL" ]]; then
    mkdir gnn4itk_ml_local
    cd gnn4itk_ml_local || { echo "Failed to create or change directory to gnn4itk_ml_local"; exit 1; }
    Reco_tf.py \
        --CA 'all:True' --autoConfiguration 'everything' \
        --conditionsTag ${DETECTOR_CONDITIONS} \
        --geometryVersion ${GEOMETRY_VERSION} \
        --multithreaded 'True' \
        --steering 'doRAWtoALL' \
        --digiSteeringConf 'StandardInTimeOnlyTruth' \
        --postInclude 'all:PyJobTransforms.UseFrontier' \
        --preExec "all:flags.ITk.doEndcapEtaNeighbour=True; flags.Tracking.ITkGNNPass.minClusters = [7,7,7]; flags.Tracking.ITkGNNPass.maxHoles = [4,4,2]; " \
        --preInclude 'all:Campaigns.PhaseIIPileUp200' 'InDetConfig.ConfigurationHelpers.OnlyTrackingPreInclude' 'InDetGNNTracking.InDetGNNTrackingFlags.gnnFinderValidation' \
        --inputRDOFile "${RDO_FILENAME}" \
        --outputAODFile "${OUTFILE}"  \
        --jobNumber '1' \
        --athenaopts='--loglevel=INFO' \
        --maxEvents ${MAX_EVENTS} \
        --skipEvents ${SKIP_EVENTS} ${FIRST_EVENT:+--firstEvent ${FIRST_EVENT}}
elif [[ "$CHAINNAME" == "GNN4ITk_ML_TRITON" ]]; then
    WORK_DIR="gnn4itk_ml_triton_${ATH_DEV_NAME}_${TRITON_DEV_NAME}"
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR" || { echo "Failed to create or change directory to $WORK_DIR"; exit 1; }
    Reco_tf.py \
        --CA 'all:True' --autoConfiguration 'everything' \
        --conditionsTag ${DETECTOR_CONDITIONS} \
        --geometryVersion ${GEOMETRY_VERSION} \
        --multithreaded 'True' \
        --steering 'doRAWtoALL' \
        --digiSteeringConf 'StandardInTimeOnlyTruth' \
        --postInclude 'all:PyJobTransforms.UseFrontier' \
        --preExec "all:flags.ITk.doEndcapEtaNeighbour=True; flags.Tracking.ITkGNNPass.minClusters = [7,7,7]" \
        --preExec "flags.Tracking.ITkGNNPass.maxHoles = [4,4,2]; flags.Tracking.GNN.Triton.model = \"$TRITON_MODEL_PATH\"; flags.Tracking.GNN.Triton.url = \"$TRITON_URL\" "\
        --preInclude 'all:Campaigns.PhaseIIPileUp200' 'InDetConfig.ConfigurationHelpers.OnlyTrackingPreInclude' 'InDetGNNTracking.InDetGNNTrackingFlags.gnnTritonValidation' \
        --inputRDOFile "${RDO_FILENAME}" \
        --outputAODFile "${OUTFILE}"  \
        --jobNumber '1' \
        --athenaopts='--loglevel=INFO' \
        --perfmon 'fullmonmt' \
        --maxEvents ${MAX_EVENTS} \
        --skipEvents ${SKIP_EVENTS} ${FIRST_EVENT:+--firstEvent ${FIRST_EVENT}}
elif [[ "$CHAINNAME" == "GNN4ITk_ML_TRITON-NoEndcapOLSP" ]]; then
    # should be the same as GNN4ITk_ML_TRITON, but with no endcap overlap SPs for Strip subdetector.
    mkdir gnn4itk_ml_triton-noendcapolsp
    cd gnn4itk_ml_triton-noendcapolsp || { echo "Failed to create or change directory to gnn4itk_ml_triton-noendcapolsp"; exit 1; }
    Reco_tf.py \
        --CA 'all:True' --autoConfiguration 'everything' \
        --conditionsTag ${DETECTOR_CONDITIONS} \
        --geometryVersion ${GEOMETRY_VERSION} \
        --multithreaded 'True' \
        --steering 'doRAWtoALL' \
        --digiSteeringConf 'StandardInTimeOnlyTruth' \
        --postInclude 'all:PyJobTransforms.UseFrontier' \
        --preExec "all:flags.Tracking.ITkGNNPass.minClusters = [7,7,7]; flags.Tracking.ITkGNNPass.maxHoles = [4,4,2]; " \
        --preInclude 'all:Campaigns.PhaseIIPileUp200' 'InDetConfig.ConfigurationHelpers.OnlyTrackingPreInclude' 'InDetGNNTracking.InDetGNNTrackingFlags.gnnTritonValidation' \
        --preExec "flags.Tracking.GNN.Triton.model = \"$TRITON_MODEL_NAME\"; flags.Tracking.GNN.Triton.url = \"$TRITON_URL\";" \
        --inputRDOFile "${RDO_FILENAME}" \
        --outputAODFile "${OUTFILE}"  \
        --jobNumber '1' \
        --athenaopts='--loglevel=INFO' \
        --maxEvents ${MAX_EVENTS}
elif [[ "$CHAINNAME" == "GNN4ITk_ML_TRITON-DefaultCuts" ]]; then
    mkdir gnn4itk_ml_triton-defaultcuts
    cd gnn4itk_ml_triton-defaultcuts || { echo "Failed to create or change directory to gnn4itk_ml_triton-defaultcuts"; exit 1; }
    Reco_tf.py \
        --CA 'all:True' --autoConfiguration 'everything' \
        --conditionsTag ${DETECTOR_CONDITIONS} \
        --geometryVersion ${GEOMETRY_VERSION} \
        --multithreaded 'True' \
        --steering 'doRAWtoALL' \
        --digiSteeringConf 'StandardInTimeOnlyTruth' \
        --postInclude 'all:PyJobTransforms.UseFrontier' \
        --preExec "all:flags.ITk.doEndcapEtaNeighbour=True;" \
        --preInclude 'all:Campaigns.PhaseIIPileUp200' 'InDetConfig.ConfigurationHelpers.OnlyTrackingPreInclude' 'InDetGNNTracking.InDetGNNTrackingFlags.gnnTritonValidation' \
        --preExec "flags.Tracking.GNN.Triton.model = \"$TRITON_MODEL_NAME\"; flags.Tracking.GNN.Triton.url = \"$TRITON_URL\";" \
        --inputRDOFile "${RDO_FILENAME}" \
        --outputAODFile "${OUTFILE}"  \
        --jobNumber '1' \
        --athenaopts='--loglevel=INFO' \
        --maxEvents ${MAX_EVENTS}
elif [[ "$CHAINNAME" == "CKF_LEGACY_LRT" ]]; then
    mkdir ckf_legacy_lrt
    cd ckf_legacy_lrt || { echo "Failed to create or change directory to ckf_legacy_lrt"; exit 1; }
    Reco_tf.py --CA 'all:True' \
        --inputRDOFile "${RDO_FILENAME}" \
        --outputAODFile "${OUTFILE}"  \
        --conditionsTag ${DETECTOR_CONDITIONS} \
        --geometryVersion ${GEOMETRY_VERSION} \
        --multithreaded 'True' \
        --steering doRAWtoALL \
        --digiSteeringConf 'StandardInTimeOnlyTruth' \
        --preInclude 'all:Campaigns.PhaseIIPileUp200' 'InDetConfig.ConfigurationHelpers.OnlyTrackingPreInclude' \
        --preExec "flags.Tracking.doLargeD0=True;" \
        --maxEvents ${MAX_EVENTS}
elif [[ "$CHAINNAME" == "GNN4Pixel_ML_TRITON" ]]; then
    mkdir gnn4pixel_ml_triton
    cd gnn4pixel_ml_triton || { echo "Failed to create or change directory to gnn4pixel_ml_triton"; exit 1; }
    FEATURE_NAMES="r,phi,z,cluster_x_1,cluster_y_1,cluster_z_1,charge_count_1,count_1,loc_eta_1,loc_phi_1,glob_eta_1,glob_phi_1,localDir0_1,localDir1_1,localDir2_1"
    Reco_tf.py \
        --CA 'all:True' --autoConfiguration 'everything' \
        --conditionsTag ${DETECTOR_CONDITIONS} \
        --geometryVersion ${GEOMETRY_VERSION} \
        --multithreaded 'True' \
        --steering 'doRAWtoALL' \
        --digiSteeringConf 'StandardInTimeOnlyTruth' \
        --postInclude 'all:PyJobTransforms.UseFrontier' \
        --preExec "all:flags.ITk.doEndcapEtaNeighbour=True; flags.Tracking.ITkGNNPass.minClusters = [7,7,7]" \
        --preExec "flags.Tracking.ITkGNNPass.maxHoles = [4,4,2]; " \
        --preInclude 'all:Campaigns.PhaseIIPileUp200' 'InDetConfig.ConfigurationHelpers.OnlyTrackingPreInclude' 'InDetGNNTracking.InDetGNNTrackingFlags.gnnTritonValidation' \
        --preExec "flags.Tracking.GNN.usePixelHitsOnly = True; flags.Tracking.GNN.Triton.model = \"$TRITON_MODEL_PATH\"; flags.Tracking.GNN.Triton.url = \"$TRITON_URL\"; flags.Tracking.GNN.Triton.features=\"$FEATURE_NAMES\"; flags.Tracking.GNN.SeedTrackMaker.usePixelWP2=True;" \
        --inputRDOFile "${RDO_FILENAME}" \
        --outputAODFile "${OUTFILE}"  \
        --jobNumber '1' \
        --athenaopts='--loglevel=INFO' \
        --maxEvents ${MAX_EVENTS}
elif [[ "$CHAINNAME" == "GNN4ITk_DML_TRITON" ]]; then
    WORK_DIR="gnn4itk_dml_triton_${ATH_DEV_NAME}_${TRITON_DEV_NAME}"
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR" || { echo "Failed to create or change directory to $WORK_DIR"; exit 1; }

    Reco_tf.py \
        --CA 'all:True' --autoConfiguration 'everything' \
        --conditionsTag ${DETECTOR_CONDITIONS} \
        --geometryVersion ${GEOMETRY_VERSION} \
        --multithreaded 'True' \
        --steering 'doRAWtoALL' \
        --digiSteeringConf 'StandardInTimeOnlyTruth' \
        --postInclude 'all:PyJobTransforms.UseFrontier' \
        --preExec "all:flags.ITk.doEndcapEtaNeighbour=True; flags.Tracking.ITkGNNPass.minClusters = [7,7,7]" \
        --preExec "flags.Tracking.ITkGNNPass.maxHoles = [4,4,2]" \
        --preExec "flags.Tracking.GNN.Triton.model = \"$TRITON_MODEL_NAME\"; flags.Tracking.GNN.Triton.url = \"$TRITON_URL\" " \
        --preInclude 'all:Campaigns.PhaseIIPileUp200' 'InDetConfig.ConfigurationHelpers.OnlyTrackingPreInclude' 'InDetGNNTracking.InDetGNNTrackingFlags.gnnTritonValidation' \
        --inputRDOFile "${RDO_FILENAME}" \
        --outputAODFile "${OUTFILE}"  \
        --jobNumber '1' \
        --athenaopts='--loglevel=INFO' \
        --perfmon 'fullmonmt' \
        --maxEvents ${MAX_EVENTS}
else
    echo "not implemented yet."
    exit 1
fi

# Check for errors
if [ $? -ne 0 ]; then
    echo "Error: Reco_tf.py failed."
    exit 1
fi

# Write output
echo "-----------------------------------"
echo "DONE $(date +%Y-%m-%dT%H:%M:%S)"
