#!/usr/bin/env bash

#
# This script runs a replay job, updating status on orchestration service
# 1) performs file setup: create dirs, get snapshot to load
# 2) http GET job details from orchestration service, incls. block range
# 3) local non-priv install of nodeos
# 4) starts nodeos loads the snapshot
# 5) replay transactions to specified block height from blocks.log or networked peers and terminates
# 6) restart nodeos read-only mode to get final integrity hash
# 7) http POST completed status for configured block range
# 8) retain blocks logs copy over to cloud storage
# Communicates to orchestration service via HTTP
# Dependency on aws client, python3, curl, and large volume under /data
#
# Final status report available via HTTP showing all good
#    OR
# Final status shows block ranges with mismatched integrity hashes
#
# Author: Eric Passmore
# Org: ENF EOS Network Foundation
# Date: Nov 21th 2023

ORCH_IP="${1:-127.0.0.1}"
ORCH_PORT="${2:-4000}"

REPLAY_CLIENT_DIR=/home/enf-replay/replay-test/replay-client
CONFIG_DIR=/home/enf-replay/replay-test/config
NODEOS_DIR=/data/nodeos
LOCK_FILE=/tmp/replay.lock

if [ -f "$LOCK_FILE" ]; then
  LOCKED_BY_PID=$(cat "$LOCK_FILE")
  echo "Exiting found lock file from pid ${LOCKED_BY_PID}"
  exit 1
else
  echo $$ > "$LOCK_FILE"
fi

function trap_exit() {
  if [ -n "${BACKGROUND_STATUS_PID}" ]; then
    kill "${BACKGROUND_STATUS_PID}"
  fi
  if [ -n "${BACKGROUND_NODEOS_PID}" ]; then
    kill "${BACKGROUND_NODEOS_PID}"
  fi
  [ -f "$LOCK_FILE" ] && rm "$LOCK_FILE"
  if [ -n "${JOBID}" ]; then
    python3 ${REPLAY_CLIENT_DIR}/job_operations.py --host ${ORCH_IP} --port ${ORCH_PORT} --operation update-status --status "ERROR" --job-id ${JOBID}
  fi
  echo "Caught signal exiting"
  exit 127
}

## set status to error if we exit on signal ##
trap trap_exit INT
trap trap_exit TERM

##################
# 1) performs file setup: create dirs, get snapshot to load
#################
echo "Step 1 of 8 performs setup: cleanup previous replay, create dirs, get snapshot to load"
## who we are ##
USER=enf-replay
TUID=$(id -ur)

## must not be root to run ##
if [ "$TUID" -eq 0 ]; then
  echo "Trying to run as root user exiting"
  exit
fi

## cleanup previous runs ##
"${REPLAY_CLIENT_DIR:?}"/replay-node-cleanup.sh "$USER"

## data volume must be large enough ##
volsize=$(df -h /data | awk 'NR==2 {print $4}' | sed 's/G//' | cut -d. -f1)
if [ ${volsize:-0} -lt 40 ]; then
  echo "/data volume does not exist or does not have 40Gb free space"
  exit 127
fi

## directory setup ##
"${REPLAY_CLIENT_DIR:?}"/create-nodeos-dir-struct.sh "${CONFIG_DIR}"

#################
# 2) http GET job details from orchestration service, incls. block range
#################
echo "Step 2 of 8: Getting job details from orchestration service"
python3 "${REPLAY_CLIENT_DIR:?}"/job_operations.py --host ${ORCH_IP} --port ${ORCH_PORT} --operation pop > /tmp/job.conf.json

STATUS=$(cat /tmp/job.conf.json | python3 "${REPLAY_CLIENT_DIR:?}"/parse_json.py "status_code")
if [ $STATUS -ne 200 ]; then
  echo "Failed to aquire job"
  [ -f "$LOCK_FILE" ] && rm "$LOCK_FILE"
  exit 127
fi
echo "Received job details processing..."

## Parse from json ###
JOBID=$(cat /tmp/job.conf.json | python3 ${REPLAY_CLIENT_DIR}/parse_json.py "job_id")
START_BLOCK=$(cat /tmp/job.conf.json | python3 ${REPLAY_CLIENT_DIR}/parse_json.py "start_block_num")
END_BLOCK=$(cat /tmp/job.conf.json | python3 ${REPLAY_CLIENT_DIR}/parse_json.py "end_block_num")
REPLAY_SLICE_ID=$(cat /tmp/job.conf.json | python3 ${REPLAY_CLIENT_DIR}/parse_json.py "replay_slice_id")
SNAPSHOT_PATH=$(cat /tmp/job.conf.json | python3 ${REPLAY_CLIENT_DIR}/parse_json.py "snapshot_path")
STORAGE_TYPE=$(cat /tmp/job.conf.json | python3 ${REPLAY_CLIENT_DIR}/parse_json.py "storage_type")
EXPECTED_INTEGRITY_HASH=$(cat /tmp/job.conf.json | python3 ${REPLAY_CLIENT_DIR}/parse_json.py "expected_integrity_hash")
LEAP_VERSION=$(cat /tmp/job.conf.json | python3 ${REPLAY_CLIENT_DIR}/parse_json.py "leap_version")
# get network/source needed to find S3 Files (eg "mainnet" vs "jungle")
SOURCE_TYPE=$(dirname "$SNAPSHOT_PATH"  | sed 's#s3://##' | cut -d'/' -f2)

#################
# 3) local non-priv install of nodeos
#################
echo "Step 3 of 8: local non-priv install of nodeos"
"${REPLAY_CLIENT_DIR:?}"/install-nodeos.sh $LEAP_VERSION
PATH=${PATH}:${HOME}/nodeos/usr/bin
export PATH

## copy snapshot ##
if [ $STORAGE_TYPE = "s3" ]; then
  if [ $START_BLOCK -gt 0 ] && [ -n "${SNAPSHOT_PATH}" ]; then
    echo "Copying snapshot to localhost"
    aws s3 cp "${SNAPSHOT_PATH}" "${NODEOS_DIR}"/snapshot/snapshot.bin.zst
  else
    echo "Warning: No snapshot provided in config or start block is zero (0)"
  fi
else
  python3 "${REPLAY_CLIENT_DIR:?}"/job_operations.py --host ${ORCH_IP} --port ${ORCH_PORT} \
        --operation update-status --status "ERROR" --job-id ${JOBID}
  echo "Unknown snapshot type ${STORAGE_TYPE}"
  [ -f "$LOCK_FILE" ] && rm "$LOCK_FILE"
  exit 127
fi

# restore blocks.log from cloud storage
echo "Restoring Blocks.log from Cloud Storage"
"${REPLAY_CLIENT_DIR:?}"/manage_blocks_log.sh "$NODEOS_DIR" "restore" $START_BLOCK $END_BLOCK "${SNAPSHOT_PATH}"


## when start block 0 no snapshot to process ##
if [ $START_BLOCK -gt 0 ] && [ -f "${NODEOS_DIR}"/snapshot/snapshot.bin.zst ]; then
  echo "Unzip snapshot"
  zstd --decompress "${NODEOS_DIR}"/snapshot/snapshot.bin.zst
  # sometimes compression format is bad error out on failure
  if [ $? != 0 ]; then
    python3 "${REPLAY_CLIENT_DIR:?}"/job_operations.py --host ${ORCH_IP} --port ${ORCH_PORT} \
        --operation update-status --status "ERROR" --job-id ${JOBID}
    echo "Error uncompressing ${SNAPSHOT_PATH}"
    [ -f "$LOCK_FILE" ] && rm "$LOCK_FILE"
    exit 1
  fi
fi

## update status that snapshot is loading ##
echo "Job status updated to LOADING_SNAPSHOT"
python3 ${REPLAY_CLIENT_DIR}/job_operations.py --host ${ORCH_IP} --port ${ORCH_PORT} \
        --operation update-status --status "LOADING_SNAPSHOT" --job-id ${JOBID}

#################
# 4) starts nodeos loads the snapshot, syncs to end block, and terminates
#################
echo "Step 4 of 8: Start nodeos, load snapshot, and sync till ${END_BLOCK}"

## update status when snapshot is complete: updates last block processed ##
## Background process grep logs on fixed interval secs ##
${REPLAY_CLIENT_DIR}/background_status_update.sh $ORCH_IP $ORCH_PORT $JOBID "$NODEOS_DIR" &
BACKGROUND_STATUS_PID=$!

sleep 5

## special treament for sync from genesis, start block 0 ##
if [ $START_BLOCK == 0 ]; then
  aws s3 cp s3://chicken-dance/"$SOURCE_TYPE"/"$SOURCE_TYPE"-genesis.json /data/nodeos/genesis.json

  nodeos \
       --genesis-json "${NODEOS_DIR}"/genesis.json \
       --data-dir "${NODEOS_DIR}"/data/ \
       --config "${CONFIG_DIR}"/sync-config.ini \
       --terminate-at-block ${END_BLOCK} \
       --integrity-hash-on-start \
       &> "${NODEOS_DIR}"/log/nodeos.log
else
  nodeos \
      --snapshot "${NODEOS_DIR}"/snapshot/snapshot.bin \
      --data-dir "${NODEOS_DIR}"/data/ \
      --config "${CONFIG_DIR}"/sync-config.ini \
      --terminate-at-block ${END_BLOCK} \
      --integrity-hash-on-start \
      &> "${NODEOS_DIR}"/log/nodeos.log
fi

kill $BACKGROUND_STATUS_PID
sleep 30

#################
# 5) get replay details from logs
#################
echo "Step 5 of 8: Reached End Block ${END_BLOCK}, getting replay details from logs"
END_TIME=$(date '+%Y-%m-%dT%H:%M:%S')
START_BLOCK_ACTUAL_INTEGRITY_HASH=$("${REPLAY_CLIENT_DIR:?}"/get_integrity_hash_from_log.sh "started" "$NODEOS_DIR")

#################
# 6) restart nodeos read-only mode to get final integrity hash
#################
echo "Step 6 of 8: restart nodeos read-only mode to get final integrity hash"
nodeos \
     --data-dir "${NODEOS_DIR}"/data/ \
     --config "${CONFIG_DIR}"/readonly-config.ini \
     &> "${NODEOS_DIR}"/log/nodeos-readonly.log &
BACKGROUND_NODEOS_PID=$!
sleep 30

END_BLOCK_ACTUAL_INTEGRITY_HASH=$(curl -s http://127.0.0.1:8888/v1/producer/get_integrity_hash | python3 ${REPLAY_CLIENT_DIR}/parse_json.py "integrity_hash")
# write hash to file, file not needed, backup for safety
echo "$END_BLOCK_ACTUAL_INTEGRITY_HASH" > "$NODEOS_DIR"/log/end_integrity_hash.txt

##
# we don't always know the integrity hash from the snapshot
# for example moving to a new version of leap, or upgrade to state db
# this updates the config and write out to a meta-data file on the server side
# POST back to config with expected integrity hash
if [ $START_BLOCK -gt 0 ]; then
  echo "Updating Configuration with expected integrity hash"
  python3 "${REPLAY_CLIENT_DIR:?}"/config_operations.py --host ${ORCH_IP} --port ${ORCH_PORT} \
    --end-block-num "$START_BLOCK" --integrity-hash "$START_BLOCK_ACTUAL_INTEGRITY_HASH"
else
  echo "Processing from genesis no expected integrity hash to update"
fi

# terminate read only nodeos in background
kill $BACKGROUND_NODEOS_PID

#################
# 7) http POST completed status for configured block range
#################
echo "Step 7 of 8: Sending COMPLETE status"
python3 "${REPLAY_CLIENT_DIR:?}"/job_operations.py --host ${ORCH_IP} --port ${ORCH_PORT} \
    --operation complete --job-id ${JOBID} \
    --block-processed ${END_BLOCK} \
    --end-time "${END_TIME}" \
    --integrity-hash "${END_BLOCK_ACTUAL_INTEGRITY_HASH}"

#################
# 8) retain block log copy over to cloud storage
# retain - copies from local host to cloud storage
#################
echo "Step 8 of 8: copying blocks.log to cloud storage"
"${REPLAY_CLIENT_DIR:?}"/manage_blocks_log.sh "$NODEOS_DIR" "retain" $START_BLOCK $END_BLOCK "${SNAPSHOT_PATH}"

[ -f "$LOCK_FILE" ] && rm "$LOCK_FILE"
