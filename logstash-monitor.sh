#!/usr/bin/env bash

set -euo pipefail

LOGSTASH_API="${LOGSTASH_API:-http://localhost:9600}"
TOP="${TOP:-15}"
WINDOW="${WINDOW:-last_1_minute}"

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required"
  exit 1
fi

DATA=$(curl -sf "${LOGSTASH_API}/_node/stats/pipelines")

echo
echo "============================================================"
echo " Logstash Pipeline Monitor"
echo " API    : ${LOGSTASH_API}"
echo " Window : ${WINDOW}"
echo "============================================================"
echo

#
# Pipeline summary
#
echo "[ PIPELINES ]"
echo

echo "${DATA}" | jq -r --arg window "${WINDOW}" '
  def n:
    if type == "number" then .
    elif type == "string" then (try tonumber catch 0)
    else 0
    end;

  [
    .pipelines
    | to_entries[]
    | {
        pipeline: .key,
        workers: (.value.pipeline.workers // 0),
        input_eps: (
          .value.flow.input_throughput[$window]
          // .value.flow.input_throughput.current
          // 0
          | n
        ),
        output_eps: (
          .value.flow.output_throughput[$window]
          // .value.flow.output_throughput.current
          // 0
          | n
        ),
        utilization: (
          .value.flow.worker_utilization[$window]
          // .value.flow.worker_utilization.current
          // 0
          | n
        ),
        queue: (
          .value.queue.events_count
          // .value.queue.events
          // 0
        )
      }
  ]
  | sort_by(.utilization)
  | reverse[]
  | [
      .pipeline,
      (.workers | tostring),
      (.input_eps | tostring),
      (.output_eps | tostring),
      (.utilization | tostring),
      (.queue | tostring)
    ]
  | @tsv
' | awk '
BEGIN {
  printf "%-35s %8s %12s %12s %10s %12s\n",
    "PIPELINE", "WORKERS", "IN/s", "OUT/s", "UTIL(%)", "QUEUE"
  printf "%-35s %8s %12s %12s %10s %12s\n",
    "-----------------------------------",
    "--------",
    "------------",
    "------------",
    "----------",
    "------------"
}
{
  printf "%-35s %8s %12.1f %12.1f %10.2f %12s\n",
    $1, $2, $3, $4, $5, $6
}
'

echo
echo "============================================================"
echo
echo "[ TOP ${TOP} SLOWEST FILTERS - ms/event ]"
echo

echo "${DATA}" | jq -r --arg window "${WINDOW}" --argjson top "${TOP}" '
  def n:
    if type == "number" then .
    elif type == "string" then
      if . == "Infinity" then 999999999
      else (try tonumber catch 0)
      end
    else 0
    end;

  [
    .pipelines
    | to_entries[]
    | .key as $pipeline
    | .value.plugins.filters[]?
    | {
        pipeline: $pipeline,
        name: .name,
        id: (.id // "-"),
        events: (.events.in // 0),
        ms_event: (
          .flow.worker_millis_per_event[$window]
          // .flow.worker_millis_per_event.current
          // (
            if (.events.in // 0) > 0
            then (.events.duration_in_millis / .events.in)
            else 0
            end
          )
          | n
        ),
        utilization: (
          .flow.worker_utilization[$window]
          // .flow.worker_utilization.current
          // 0
          | n
        )
      }
  ]
  | sort_by(.ms_event)
  | reverse
  | .[:$top]
  | .[]
  | [
      .pipeline,
      .name,
      (.ms_event | tostring),
      (.utilization | tostring),
      (.events | tostring),
      .id
    ]
  | @tsv
' | awk '
BEGIN {
  printf "%-30s %-15s %12s %10s %12s %s\n",
    "PIPELINE", "FILTER", "MS/EVENT", "UTIL(%)", "EVENTS", "ID"
  printf "%-30s %-15s %12s %10s %12s %s\n",
    "------------------------------",
    "---------------",
    "------------",
    "----------",
    "------------",
    "----------------"
}
{
  printf "%-30s %-15s %12.3f %10.2f %12s %s\n",
    $1, $2, $3, $4, $5, $6
}
'

echo
echo "============================================================"
echo
echo "[ TOP ${TOP} BUSIEST FILTERS - worker utilization ]"
echo

echo "${DATA}" | jq -r --arg window "${WINDOW}" --argjson top "${TOP}" '
  def n:
    if type == "number" then .
    elif type == "string" then
      if . == "Infinity" then 999999999
      else (try tonumber catch 0)
      end
    else 0
    end;

  [
    .pipelines
    | to_entries[]
    | .key as $pipeline
    | .value.plugins.filters[]?
    | {
        pipeline: $pipeline,
        name: .name,
        id: (.id // "-"),
        events: (.events.in // 0),
        ms_event: (
          .flow.worker_millis_per_event[$window]
          // .flow.worker_millis_per_event.current
          // (
            if (.events.in // 0) > 0
            then (.events.duration_in_millis / .events.in)
            else 0
            end
          )
          | n
        ),
        utilization: (
          .flow.worker_utilization[$window]
          // .flow.worker_utilization.current
          // 0
          | n
        )
      }
  ]
  | sort_by(.utilization)
  | reverse
  | .[:$top]
  | .[]
  | [
      .pipeline,
      .name,
      (.utilization | tostring),
      (.ms_event | tostring),
      (.events | tostring),
      .id
    ]
  | @tsv
' | awk '
BEGIN {
  printf "%-30s %-15s %10s %12s %12s %s\n",
    "PIPELINE", "FILTER", "UTIL(%)", "MS/EVENT", "EVENTS", "ID"
  printf "%-30s %-15s %10s %12s %12s %s\n",
    "------------------------------",
    "---------------",
    "----------",
    "------------",
    "------------",
    "----------------"
}
{
  printf "%-30s %-15s %10.2f %12.3f %12s %s\n",
    $1, $2, $3, $4, $5, $6
}
'

echo
echo "============================================================"
echo
echo "[ TOP ${TOP} OUTPUTS ]"
echo

echo "${DATA}" | jq -r --arg window "${WINDOW}" --argjson top "${TOP}" '
  def n:
    if type == "number" then .
    elif type == "string" then
      if . == "Infinity" then 999999999
      else (try tonumber catch 0)
      end
    else 0
    end;

  [
    .pipelines
    | to_entries[]
    | .key as $pipeline
    | .value.plugins.outputs[]?
    | {
        pipeline: $pipeline,
        name: .name,
        events: (.events.in // 0),

        ms_event: (
          .flow.worker_millis_per_event[$window]
          // .flow.worker_millis_per_event.current
          // (
            if (.events.in // 0) > 0
            then (.events.duration_in_millis / .events.in)
            else 0
            end
          )
          | n
        ),

        utilization: (
          .flow.worker_utilization[$window]
          // .flow.worker_utilization.current
          // 0
          | n
        )
      }
  ]
  | sort_by(.utilization)
  | reverse
  | .[:$top]
  | .[]
  | [
      .pipeline,
      .name,
      (.utilization | tostring),
      (.ms_event | tostring),
      (.events | tostring)
    ]
  | @tsv
' | awk '
BEGIN {
  printf "%-30s %-18s %10s %12s %12s\n",
    "PIPELINE", "OUTPUT", "UTIL(%)", "MS/EVENT", "EVENTS"
}
{
  printf "%-30s %-18s %10.2f %12.3f %12s\n",
    $1, $2, $3, $4, $5
}
'

echo
