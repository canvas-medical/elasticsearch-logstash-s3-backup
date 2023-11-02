#!/bin/bash

function now() {
  date +"%m-%d-%Y %H-%M"
}

echo "$(now): backup-all-indexes.sh - Verifying required environment variables"

: ${DATABASE_URL:?"Error: DATABASE_URL environment variable not set"}
: ${S3_BUCKET:?"Error: S3_BUCKET environment variable not set"}
: ${S3_ACCESS_KEY_ID:?"Error: S3_ACCESS_KEY_ID environment variable not set"}
: ${S3_SECRET_ACCESS_KEY:?"Error: S3_SECRET_ACCESS_KEY environment variable not set"}

# Normalize DATABASE_URL by removing the trailing slash.
DATABASE_URL="${DATABASE_URL%/}"

# Set some defaults
REPOSITORY_NAME=${REPOSITORY_NAME:-logstash_snapshots}
WAIT_SECONDS=${WAIT_SECONDS:-1800}
MAX_DAYS_TO_KEEP=${MAX_DAYS_TO_KEEP:-30}
REPOSITORY_URL=${DATABASE_URL}/_snapshot/${REPOSITORY_NAME}

# Ensure that we don't delete indices that are being logged. Using 1 should
# actually be fine here as long as everyone's on the same timezone, but let's
# be safe and require at least 2 days.
if [[ "$MAX_DAYS_TO_KEEP" -lt 2 ]]; then
  echo "$(now): MAX_DAYS_TO_KEEP must be an integer >= 2."
  echo "$(now): Using lower values may break archiving."
  exit 1
fi

backup_index ()
{
  : ${1:?"Error: expected index name passed as parameter"}
  local INDEX_NAME=$1
  local SNAPSHOT_URL=${REPOSITORY_URL}/${INDEX_NAME}
  local INDEX_URL=${DATABASE_URL}/${INDEX_NAME}

  grep -q SUCCESS <(curl -sS ${SNAPSHOT_URL})
  if [ $? -ne 0 ]; then
    echo "$(now): Scheduling snapshot for ${INDEX_NAME}."
    # If the snapshot exists but isn't in a success state, delete it so that we can try again.
    grep -qE "FAILED|PARTIAL|IN_PROGRESS" <(curl -sS ${SNAPSHOT_URL}) && curl -sS -XDELETE ${SNAPSHOT_URL}
    # Indexes have to be open for snapshots to work.
    curl -sS -XPOST "${INDEX_URL}/_open"

    curl -H "Content-Type: application/json" --fail -w "\n" -sS -XPUT ${SNAPSHOT_URL} -d "{
      \"indices\": \"${INDEX_NAME}\",
      \"include_global_state\": false
    }" || return 1

    echo "$(now): Waiting for snapshot to finish..."
    timeout "${WAIT_SECONDS}" bash -c "until grep -q SUCCESS <(curl -sS ${SNAPSHOT_URL}); do sleep 1; done" || return 1
  fi

  echo "Deleting ${INDEX_NAME} from Elasticsearch."
  curl -w "\n" -sS -XDELETE ${INDEX_URL}
}

CUTOFF_DATE=$(date --date="${MAX_DAYS_TO_KEEP} days ago" +"%Y.%m.%d")
echo "$(now) Archiving all indexes with logs before ${CUTOFF_DATE}."
SUBSTITUTION='s/.*\(logstash-[0-9]\{4\}\.[0-9]\{2\}\.[0-9]\{2\}-[0-9]*\).*/\1/'
for index_name in $(curl -sS ${DATABASE_URL}/_cat/indices | grep logstash- | sed $SUBSTITUTION | sort); do
  if [[ "${index_name:9:10}" < "${CUTOFF_DATE}" ]]; then
    echo "$(now): Ensuring ${index_name} is archived..."
    backup_index ${index_name}
    if [ $? -eq 0 ]; then
      echo "$(now): ${index_name} archived."
    else
      echo "$(now): ${index_name} archival failed."
    fi
  fi
done
echo "$(now): Finished archiving."
