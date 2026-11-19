#!/usr/bin/env bash
#
# Housekeeping for a persistent self-hosted GitHub Actions runner. Meant to be run
# from cron or a systemd timer on the runner host, not from a workflow.
#
# Usage: runner-maintenance.sh <runner-directory>
#
# What it removes:
#   - _diag logs older than LOG_DAYS (GitHub keeps the run logs for 90 days anyway).
#   - Cached actions (_work/_actions/<owner>/<repo>/<ref>) and tool cache
#     (_work/_tool) not touched for CACHE_DAYS. The runner downloads an action again
#     when it is missing, so this only costs one download; it is skipped while a job runs.
#   - Leftovers in _work/_temp older than TEMP_DAYS (skipped while a job runs).
#
# What it never touches: the workspaces, the runner binaries and credentials, and the
# last uploaded package kept by the release workflow (GLPI_KEEP_DIR).
#
# Schedule it once a week on each runner host, e.g. in the runner user's crontab:
#   17 3 * * 0  /path/to/runner-maintenance.sh /path/to/actions-runner >> /path/to/actions-runner/maintenance.log 2>&1
#
# Environment:
#   LOG_DAYS=14  CACHE_DAYS=30  TEMP_DAYS=2   Ages in days.
#   DRY_RUN=1                                  Only list what would be removed.

set -euo pipefail

dir=${1:?runner directory required}
LOG_DAYS=${LOG_DAYS:-14}
CACHE_DAYS=${CACHE_DAYS:-30}
TEMP_DAYS=${TEMP_DAYS:-2}
DRY_RUN=${DRY_RUN:-0}

for n in "$LOG_DAYS" "$CACHE_DAYS" "$TEMP_DAYS"; do
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "ages must be whole numbers of days" >&2; exit 2; }
done

dir=$(cd "$dir" 2>/dev/null && pwd -P) || { echo "not a directory: $1" >&2; exit 2; }
# Refuse anything that does not look like a runner directory (never / or a home).
if [ "$dir" = "/" ] || [ "$dir" = "${HOME:-/nonexistent}" ] || [ ! -f "$dir/config.sh" ] || [ ! -d "$dir/_diag" ]; then
  echo "refusing: $dir does not look like a runner directory" >&2
  exit 2
fi

used() { du -sk "$dir" 2>/dev/null | cut -f1; }
before=$(used)
removed=0

# remove_old <label> <find-args...>: lists (and removes unless DRY_RUN) the matches.
remove_old() {
  local label=$1; shift
  local item n=0
  while IFS= read -r -d '' item; do
    n=$((n + 1))
    if [ "$DRY_RUN" = "1" ]; then echo "would remove: ${item#"$dir"/}"; else rm -rf -- "$item"; fi
  done < <(find "$@" -print0 2>/dev/null)
  removed=$((removed + n))
  echo "${label}: ${n} item(s)$([ "$DRY_RUN" = "1" ] && echo ' (dry run)')"
}

# Logs: one file per runner start and per job; safe to age out even while a job runs
# because a running job's log is being written, so it is newer than any limit.
remove_old "logs older than ${LOG_DAYS} days" "$dir/_diag" -mindepth 1 -maxdepth 1 -mtime "+${LOG_DAYS}"

if pgrep -f "$dir/bin/Runner.Worker" >/dev/null 2>&1; then
  echo "a job is running: the action cache and _temp are left alone this time"
else
  if [ -d "$dir/_work/_actions" ]; then
    # <owner>/<repo>/<ref> directories and their <ref>.completed markers.
    remove_old "cached actions not refreshed for ${CACHE_DAYS} days" "$dir/_work/_actions" -mindepth 3 -maxdepth 3 -mtime "+${CACHE_DAYS}"
    if [ "$DRY_RUN" != "1" ]; then
      # Drop the <owner>/<repo> and <owner> folders that were left empty.
      find "$dir/_work/_actions" -mindepth 1 -type d -empty -delete 2>/dev/null || true
    fi
  fi
  [ -d "$dir/_work/_tool" ] && remove_old "tool cache not used for ${CACHE_DAYS} days" "$dir/_work/_tool" -mindepth 1 -maxdepth 1 -mtime "+${CACHE_DAYS}"
  [ -d "$dir/_work/_temp" ] && remove_old "_temp leftovers older than ${TEMP_DAYS} days" "$dir/_work/_temp" -mindepth 1 -maxdepth 1 -mtime "+${TEMP_DAYS}"
fi

after=$(used)
echo "runner directory: ${before} KB -> ${after} KB (${removed} item(s) $([ "$DRY_RUN" = "1" ] && echo 'would be ')removed)"
