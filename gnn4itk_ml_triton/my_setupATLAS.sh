#!/bin/bash

if [ -z $ATLAS_LOCAL_ROOT_BASE ]; then
  export ATLAS_LOCAL_ROOT_BASE=/cvmfs/atlas.cern.ch/repo/ATLASLocalRootBase
fi
source ${ATLAS_LOCAL_ROOT_BASE}/user/atlasLocalSetup.sh
