#!/bin/sh
# Copyright 2026 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# activate-persona.sh — stands in for whatever your real agent does on startup.
#
# Every pod in the warm pool is byte-identical and carries the FULL persona
# catalogue. What differs per claim is a single label. This loop watches the
# downward API projection of that label and swaps the active persona when it
# changes — with no restart, so a warm sandbox stays warm.
#
# Replace the "activate" step with your agent's own reload (re-read the system
# prompt, POST to a local admin endpoint, send SIGHUP, ...).

set -u

LABEL_FILE="${LABEL_FILE:-/etc/podinfo/labels}"
CATALOG_DIR="${CATALOG_DIR:-/opt/personas}"
ACTIVE_FILE="${ACTIVE_FILE:-/opt/active/persona.md}"
LABEL_KEY="${LABEL_KEY:-sandbox.users.io/persona}"
POLL_SECONDS="${POLL_SECONDS:-2}"

log() { echo "[persona-activator] $*"; }

# The downward API writes labels as: key="value" (one per line).
read_persona() {
  [ -f "$LABEL_FILE" ] || return 0
  sed -n "s|^${LABEL_KEY}=\"\\(.*\\)\"$|\\1|p" "$LABEL_FILE" 2>/dev/null | head -n 1
}

activate() {
  persona="$1"
  src="${CATALOG_DIR}/${persona}.md"

  if [ ! -f "$src" ]; then
    log "ERROR persona '${persona}' not found in catalogue; keeping previous persona"
    log "      available: $(ls "$CATALOG_DIR" 2>/dev/null | tr '\n' ' ')"
    return 1
  fi

  mkdir -p "$(dirname "$ACTIVE_FILE")"
  cp "$src" "$ACTIVE_FILE"
  log "activated persona '${persona}' ($(wc -c <"$src" | tr -d ' ') bytes) -> ${ACTIVE_FILE}"
  return 0
}

log "watching ${LABEL_FILE} for ${LABEL_KEY} (poll ${POLL_SECONDS}s)"
log "catalogue: $(ls "$CATALOG_DIR" 2>/dev/null | tr '\n' ' ')"

current=""
while true; do
  desired="$(read_persona)"

  if [ -z "$desired" ]; then
    # Unclaimed warm spare: no persona label yet. This is the normal resting
    # state for a spare sitting in the pool, not an error.
    if [ "$current" != "<none>" ]; then
      log "no ${LABEL_KEY} label present — idle warm spare, awaiting a claim"
      current="<none>"
    fi
  elif [ "$desired" != "$current" ]; then
    if activate "$desired"; then
      current="$desired"
    else
      # Avoid hot-looping on an unresolvable value.
      current="$desired"
    fi
  fi

  sleep "$POLL_SECONDS"
done
