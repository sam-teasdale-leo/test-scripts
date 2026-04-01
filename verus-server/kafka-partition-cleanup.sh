#!/bin/bash

usage() {
  echo "Usage: $(basename "$0") [--dryrun|--apply] <namespace>"
  echo ""
  echo "Clean up Kafka topics for a given tenant namespace. This script spins up a"
  echo "temporary pod (confluentinc/cp-kafka:7.5.3) in the specified namespace and"
  echo "uses kafka-topics to find all topics belonging to the tenant. The pod is"
  echo "automatically removed when the command completes."
  echo ""
  echo "The script reads the KAFKA_URL from the running verus-server pod's"
  echo "environment to determine the bootstrap servers."
  echo ""
  echo "Flags:"
  echo "  --dryrun     List matching topics only (default)"
  echo "  --apply      List and delete matching topics"
  echo ""
  echo "Arguments:"
  echo "  namespace    Kubernetes namespace (e.g. narwhal-ca, development-ca)"
  echo ""
  echo "Examples:"
  echo "  $(basename "$0") narwhal-ca                  # dry run (default)"
  echo "  $(basename "$0") narwhal-ca --dryrun         # explicit dry run"
  echo "  $(basename "$0") narwhal-ca --apply          # do all the things"
  exit 1
}

prompt_continue() {
  if [ "$MODE" = "dryrun" ]; then
    return 0
  fi
  local next_step="$1"
  echo ""
  echo "Esc to exit, Enter to continue to $next_step..."
  while true; do
    read -rsn1 key
    if [ "$key" = "" ]; then
      return 0
    elif [ "$key" = $'\x1b' ]; then
      echo "Exiting."
      exit 0
    fi
  done
}

RELEASE_TOPIC="verus-server-release-task-management"

LAG_CHECK_TOPICS=(
  "verus-{{NAMESPACE}}-v2-post-process-continuous-monitor"
  "verus-{{NAMESPACE}}-v2-post-process-known-unknown"
  "verus-{{NAMESPACE}}-v2-post-process-semantic-monitor"
)

LAG_CHECK_CONSUMER_GROUPS=(
  "verus-{{NAMESPACE}}-post-process-continuous-monitor"
  "verus-{{NAMESPACE}}-post-process-known-unknown"
  "verus-{{NAMESPACE}}-post-process-semantic-monitor"
)

PAUSE_DIGEST_TEMPLATE='{
  "version": 1,
  "data": {
    "target": "{{NAMESPACE}}",
    "release_task": "VerusServer.Tasks.KafkaMaintenanceTask",
    "action": "start_task",
    "expires": "{{EXPIRES}}",
    "args": [
      "consumers=[\"digest\",\"digest_backfill\"]",
      "action=pause"
    ]
  }
}'

PAUSE_PROCESSING_TEMPLATE='{
  "version": 1,
  "data": {
    "target": "{{NAMESPACE}}",
    "release_task": "VerusServer.Tasks.KafkaMaintenanceTask",
    "action": "start_task",
    "expires": "{{EXPIRES}}",
    "args": [
      "consumers=[\"ppcm\",\"ppkuk\",\"semantic_monitor\"]",
      "action=pause"
    ]
  }
}'

MODE="dryrun"
NAMESPACE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dryrun)
      MODE="dryrun"
      shift
      ;;
    --apply)
      MODE="apply"
      shift
      ;;
    --help|-h)
      usage
      ;;
    -*)
      echo "ERROR: Unknown flag '$1'"
      echo ""
      usage
      ;;
    *)
      if [ -n "$NAMESPACE" ]; then
        echo "ERROR: Unexpected argument '$1' (namespace already set to '$NAMESPACE')"
        echo ""
        usage
      fi
      NAMESPACE="$1"
      shift
      ;;
  esac
done

if [ -z "$NAMESPACE" ]; then
  usage
fi

if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
  echo "ERROR: Namespace '$NAMESPACE' does not exist in the current cluster"
  exit 1
fi

echo "Looking up KAFKA_URL from a running verus-server pod in $NAMESPACE..."

# Find a running verus-server pod to read the KAFKA_URL from
POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=verus-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$POD_NAME" ]; then
  # Fallback: find any running verus-server pod by name prefix
  POD_NAME=$(kubectl get pods -n "$NAMESPACE" --field-selector=status.phase=Running -o name 2>/dev/null | grep verus-server | head -1 | sed 's|pod/||')
fi

if [ -z "$POD_NAME" ]; then
  echo "ERROR: Could not find a running verus-server pod in namespace $NAMESPACE"
  exit 1
fi

KAFKA_URL=$(kubectl exec "$POD_NAME" -n "$NAMESPACE" -- printenv KAFKA_URL 2>/dev/null)

if [ -z "$KAFKA_URL" ]; then
  echo "ERROR: Could not read KAFKA_URL from pod $POD_NAME"
  exit 1
fi

EXPIRES=$(date -u -v+30M '+%Y-%m-%dT%H:%M:%SZ')
PAUSE_DIGEST_MESSAGE=$(echo "$PAUSE_DIGEST_TEMPLATE" | sed "s/{{NAMESPACE}}/$NAMESPACE/g; s/{{EXPIRES}}/$EXPIRES/g")

# Step 1: List Kafka topics for the namespace
echo ""
echo "=== Step 1: Kafka Topics for $NAMESPACE ==="
echo ""

STEP1_OUTPUT=$(kubectl run kafka-topic-list --rm -it --restart=Never \
  -n "$NAMESPACE" \
  --image=confluentinc/cp-kafka:7.5.3 \
  -- /bin/bash -c "
cat > /tmp/client.properties << EOF
security.protocol=SSL
EOF

kafka-topics --bootstrap-server '$KAFKA_URL' \
  --command-config /tmp/client.properties \
  --describe 2>/dev/null | grep '$NAMESPACE' | grep 'PartitionCount:' | while IFS=\$'\t' read -r topic_field topicid_field partition_field rest; do
  topic=\$(echo \"\$topic_field\" | awk '{print \$2}')
  partitions=\$(echo \"\$partition_field\" | awk '{print \$2}')
  echo \"\$topic \$partitions\"
done
" 2>&1 | grep -v '^pod "' | grep -v 'If you don'\''t see a command prompt')

echo "$STEP1_OUTPUT"
BEFORE_PARTITIONS=$(echo "$STEP1_OUTPUT" | awk '{total+=$2} END{print total+0}')
echo ""
echo "Total partitions: $BEFORE_PARTITIONS"

prompt_continue "Step 2 - Pause digest consumers"

# Step 2: Pause digest consumers
echo ""
echo "=== Step 2: Pause digest consumers ==="
echo ""
echo "Topic: $RELEASE_TOPIC"
echo "Message:"
echo "$PAUSE_DIGEST_MESSAGE"
echo ""

if [ "$MODE" = "dryrun" ]; then
  echo "(dry run — would write the above message to $RELEASE_TOPIC)"
else
  echo "Spinning up temporary kafka pod to produce message..."

  kubectl run kafka-producer --rm -it --restart=Never \
    -n "$NAMESPACE" \
    --image=confluentinc/cp-kafka:7.5.3 \
    -- /bin/bash -c "
cat > /tmp/client.properties << EOF
security.protocol=SSL
EOF

COMPACT_MESSAGE=\$(echo '$PAUSE_DIGEST_MESSAGE' | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin)))')
echo \"\$COMPACT_MESSAGE\" | kafka-console-producer --bootstrap-server '$KAFKA_URL' \
  --producer.config /tmp/client.properties \
  --topic '$RELEASE_TOPIC'

echo 'Message produced successfully.'
"
fi

prompt_continue "Step 3 - Check consumer lag"

# Step 3: Verify consumer lag is 0 on processing topics
echo ""
echo "=== Step 3: Check consumer lag ==="
echo ""

LAG_CHECK_COMMANDS=""
for i in "${!LAG_CHECK_CONSUMER_GROUPS[@]}"; do
  GROUP=$(echo "${LAG_CHECK_CONSUMER_GROUPS[$i]}" | sed "s/{{NAMESPACE}}/$NAMESPACE/g")
  TOPIC=$(echo "${LAG_CHECK_TOPICS[$i]}" | sed "s/{{NAMESPACE}}/$NAMESPACE/g")
  LAG_CHECK_COMMANDS+="
LAG=\$(kafka-consumer-groups --bootstrap-server '$KAFKA_URL' \
  --command-config /tmp/client.properties \
  --describe --group '$GROUP' 2>/dev/null | awk 'NR>1{total+=\$6} END{print total+0}')
echo '$TOPIC lag: '\$LAG
"
done

kubectl run kafka-lag-check --rm -it --restart=Never \
  -n "$NAMESPACE" \
  --image=confluentinc/cp-kafka:7.5.3 \
  -- /bin/bash -c "
cat > /tmp/client.properties << EOF
security.protocol=SSL
EOF
$LAG_CHECK_COMMANDS
" 2>&1 | grep -v '^pod "' | grep -v 'If you don'\''t see a command prompt'

prompt_continue "Step 4 - Pause processing consumers"

# Step 4: Pause processing consumers
EXPIRES=$(date -u -v+30M '+%Y-%m-%dT%H:%M:%SZ')
PAUSE_PROCESSING_MESSAGE=$(echo "$PAUSE_PROCESSING_TEMPLATE" | sed "s/{{NAMESPACE}}/$NAMESPACE/g; s/{{EXPIRES}}/$EXPIRES/g")

echo ""
echo "=== Step 4: Pause processing consumers ==="
echo ""
echo "Topic: $RELEASE_TOPIC"
echo "Message:"
echo "$PAUSE_PROCESSING_MESSAGE"
echo ""

if [ "$MODE" = "dryrun" ]; then
  echo "(dry run — would write the above message to $RELEASE_TOPIC)"
else
  echo "Spinning up temporary kafka pod to produce message..."

  kubectl run kafka-producer-2 --rm -it --restart=Never \
    -n "$NAMESPACE" \
    --image=confluentinc/cp-kafka:7.5.3 \
    -- /bin/bash -c "
cat > /tmp/client.properties << EOF
security.protocol=SSL
EOF

COMPACT_MESSAGE=\$(echo '$PAUSE_PROCESSING_MESSAGE' | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin)))')
echo \"\$COMPACT_MESSAGE\" | kafka-console-producer --bootstrap-server '$KAFKA_URL' \
  --producer.config /tmp/client.properties \
  --topic '$RELEASE_TOPIC'

echo 'Message produced successfully.'
" 2>&1 | grep -v '^pod "' | grep -v 'If you don'\''t see a command prompt'
fi

prompt_continue "Step 5 - Delete processing topics"

# Step 5: Delete processing topics
echo ""
echo "=== Step 5: Delete processing topics ==="
echo ""

DELETE_TOPICS=""
for TOPIC_TEMPLATE in "${LAG_CHECK_TOPICS[@]}"; do
  TOPIC=$(echo "$TOPIC_TEMPLATE" | sed "s/{{NAMESPACE}}/$NAMESPACE/g")
  echo "  $TOPIC"
  DELETE_TOPICS+="$TOPIC "
done
echo ""

if [ "$MODE" = "dryrun" ]; then
  echo "(dry run — would delete the above topics)"
else
  DELETE_COMMANDS=""
  for TOPIC_TEMPLATE in "${LAG_CHECK_TOPICS[@]}"; do
    TOPIC=$(echo "$TOPIC_TEMPLATE" | sed "s/{{NAMESPACE}}/$NAMESPACE/g")
    DELETE_COMMANDS+="
echo 'Deleting $TOPIC...'
kafka-topics --bootstrap-server '$KAFKA_URL' \
  --command-config /tmp/client.properties \
  --delete --topic '$TOPIC'
"
  done

  kubectl run kafka-topic-delete --rm -it --restart=Never \
    -n "$NAMESPACE" \
    --image=confluentinc/cp-kafka:7.5.3 \
    -- /bin/bash -c "
cat > /tmp/client.properties << EOF
security.protocol=SSL
EOF
$DELETE_COMMANDS
echo 'Done.'
" 2>&1 | grep -v '^pod "' | grep -v 'If you don'\''t see a command prompt'
fi

prompt_continue "Step 5a - Recreate events-backfill topic"

# Step 5a: Delete and recreate events-backfill topic with 3 partitions
BACKFILL_TOPIC="events-backfill-${NAMESPACE}-v1"

echo ""
echo "=== Step 5a: Recreate $BACKFILL_TOPIC with 3 partitions ==="
echo ""
echo "  Delete: $BACKFILL_TOPIC"
echo "  Create: $BACKFILL_TOPIC (3 partitions)"
echo ""

if [ "$MODE" = "dryrun" ]; then
  echo "(dry run — would delete and recreate $BACKFILL_TOPIC with 3 partitions)"
else
  kubectl run kafka-recreate-backfill --rm -it --restart=Never \
    -n "$NAMESPACE" \
    --image=confluentinc/cp-kafka:7.5.3 \
    -- /bin/bash -c "
cat > /tmp/client.properties << EOF
security.protocol=SSL
EOF

echo 'Deleting $BACKFILL_TOPIC...'
kafka-topics --bootstrap-server '$KAFKA_URL' \
  --command-config /tmp/client.properties \
  --delete --topic '$BACKFILL_TOPIC'

echo 'Waiting for topic deletion to propagate...'
sleep 5

echo 'Creating $BACKFILL_TOPIC with 3 partitions...'
kafka-topics --bootstrap-server '$KAFKA_URL' \
  --command-config /tmp/client.properties \
  --create --topic '$BACKFILL_TOPIC' \
  --partitions 3 \
  --replication-factor 3

echo 'Done.'
" 2>&1 | grep -v '^pod "' | grep -v 'If you don'\''t see a command prompt'
fi

prompt_continue "Step 6 - Rolling restart"

# Step 6: Rolling restart of deployments in the namespace
echo ""
echo "=== Step 6: Rolling restart ==="
echo ""

DEPLOYMENT="verus-server"

echo "  deployment/$DEPLOYMENT"
echo ""

if [ "$MODE" = "dryrun" ]; then
  echo "(dry run — would rollout restart deployment/$DEPLOYMENT)"
else
  echo "Restarting deployment/$DEPLOYMENT..."
  kubectl rollout restart deployment/"$DEPLOYMENT" -n "$NAMESPACE"
  kubectl rollout status deployment/"$DEPLOYMENT" -n "$NAMESPACE" --timeout=300s
  echo "Rollout complete."
fi

prompt_continue "Step 7 - Post-cleanup summary"

# Step 7: List topics and partitions after cleanup, compare with Step 1
echo ""
echo "=== Step 7: Post-cleanup topics for $NAMESPACE ==="
echo ""

STEP7_OUTPUT=$(kubectl run kafka-topic-list-after --rm -it --restart=Never \
  -n "$NAMESPACE" \
  --image=confluentinc/cp-kafka:7.5.3 \
  -- /bin/bash -c "
cat > /tmp/client.properties << EOF
security.protocol=SSL
EOF

kafka-topics --bootstrap-server '$KAFKA_URL' \
  --command-config /tmp/client.properties \
  --describe 2>/dev/null | grep '$NAMESPACE' | grep 'PartitionCount:' | while IFS=\$'\t' read -r topic_field topicid_field partition_field rest; do
  topic=\$(echo \"\$topic_field\" | awk '{print \$2}')
  partitions=\$(echo \"\$partition_field\" | awk '{print \$2}')
  echo \"\$topic \$partitions\"
done
" 2>&1 | grep -v '^pod "' | grep -v 'If you don'\''t see a command prompt')

echo "$STEP7_OUTPUT"
AFTER_PARTITIONS=$(echo "$STEP7_OUTPUT" | awk '{total+=$2} END{print total+0}')
echo ""
echo "Total partitions: $AFTER_PARTITIONS"
echo ""
echo "=== Summary ==="
echo "  Before: $BEFORE_PARTITIONS partitions"
echo "  After:  $AFTER_PARTITIONS partitions"
echo "  Removed: $((BEFORE_PARTITIONS - AFTER_PARTITIONS)) partitions"
