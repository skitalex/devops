#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: $0 <command> [args]" >&2
  echo "commands:" >&2
  echo "  check         is a reboot required (exit 1 if yes)" >&2
  echo "  verify        wait system up, take snapshot, compare before/after" >&2
  echo "  snapshot      take snapshot in before/after" >&2
  echo "  reboot        if check 1 reboot is required, takes snapshot and reboot" >&2
  exit 2
}

readonly REBOOT_FLAG="/var/run/reboot-required"
readonly REBOOT_PKGS="/var/run/reboot-required.pkgs"
readonly SNAPSHOT_DIR="/var/lib/reboot-check"
readonly LOGS_DIR="/var/log/reboot-check"
readonly KERNEL_FILE="kernel.txt"
readonly SERVICES_FILE="services.txt"
readonly PORTS_FILE="ports.txt"
readonly CONTAINERS_FILE="containers.txt"

require_root() {
  ((EUID == 0)) || {
    echo "script must run as root (use sudo)" >&2
    exit 1
  }
}

cmd_reboot() {
  require_root

  local rc=0
  cmd_check || rc=$?

  case $rc in
  0) return 0 ;;
  1)
    echo "taking 'before' snapshot"
    if ! cmd_snapshot before; then
      echo "snapshot failed, reboot cancelled" >&2
      return 1
    fi
    logger -t reboot-check "snapshot taken, rebooting"
    # systemctl reboot
    ;;
  *)
    echo "check failed (code $rc)" >&2
    return 1
    ;;
  esac
}

cmd_snapshot() {
  require_root

  [[ $# -eq 1 ]] || usage

  local dir

  if [[ "$1" == "after" || "$1" == "before" ]]; then
    dir="$1"
  else
    echo "snapshot args must be after/before" >&2
    return 1
  fi
  
  rm -rf "${SNAPSHOT_DIR:?}/before" "${SNAPSHOT_DIR:?}/after"

  mkdir -p "${SNAPSHOT_DIR:?}/$dir"

  # kernel snapshot
  uname -r >"${SNAPSHOT_DIR:?}/$dir/$KERNEL_FILE"

  # services snapshot
  systemctl list-units --type=service --state=running --no-legend | awk '{print $1}' | sort -u >"${SNAPSHOT_DIR:?}/$dir/$SERVICES_FILE"

  # ports snapshot
  ss -H -t -u -l -n | awk '{print $1, $5}' | sort -u >"${SNAPSHOT_DIR:?}/$dir/$PORTS_FILE"

  # Docker containers snapshot
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker not installed" >"${SNAPSHOT_DIR:?}/$dir/$CONTAINERS_FILE"
  elif ! { docker ps --format '{{.Names}}' | sort -u; } >"${SNAPSHOT_DIR:?}/$dir/$CONTAINERS_FILE" 2>/dev/null; then
    echo "docker unavailable" >"${SNAPSHOT_DIR:?}/$dir/$CONTAINERS_FILE"
  fi

  return 0
}

cmd_verify() {
  require_root

  local state
  state=$(systemctl is-system-running --wait) || true

  mkdir -p "$LOGS_DIR"

  if [[ ! -d "${SNAPSHOT_DIR:?}/before" ]]; then
    echo "folder before does not exist" >&2
    return 1
  fi
  local report=""
  report+="system status: $state"$'\n'

  cmd_snapshot after

  local rc=0
  local diffs
  diffs=$(diff -ru "${SNAPSHOT_DIR:?}/before/" "${SNAPSHOT_DIR:?}/after/") || rc=$?

  case $rc in
  0) report+="snapshot diff: none"$'\n' ;;
  1)
    report+="snapshot diff:"$'\n'"$diffs"$'\n'
    ;;
  *)
    echo "diff failed (code $rc)" >&2
    return 1
    ;;
  esac

  local failed
  failed=$(systemctl --failed --no-legend)
  if [[ -n $failed ]]; then
    report+="failed units:"$'\n'"$failed"$'\n'
  else
    report+="failed units:none"$'\n'
  fi

  local before_kernel
  before_kernel=$(cat "${SNAPSHOT_DIR:?}/before/$KERNEL_FILE")
  local after_kernel
  after_kernel=$(cat "${SNAPSHOT_DIR:?}/after/$KERNEL_FILE")
  report+="kernel: $before_kernel -> $after_kernel"$'\n'

  local file_name
  file_name="reboot-check_$(date +%F_%H-%M-%S).log"

  printf '%s' "$report" >"$LOGS_DIR/$file_name"
  logger -t reboot-check -f "$LOGS_DIR/$file_name"
  rm -rf "${SNAPSHOT_DIR:?}/before"
  if [[ ! $rc -eq 0 ]]; then
    return 1
  fi
}

cmd_check() {
  if [[ -f "$REBOOT_FLAG" ]]; then
    echo "reboot required"
    if [[ -f "$REBOOT_PKGS" ]]; then
      echo "packages:"
      sed 's/^/  /' "$REBOOT_PKGS"
    fi
    return 1
  fi
  echo "reboot not required"
  return 0
}

[[ $# -ge 1 ]] || usage

cmd=$1
shift

case "$cmd" in
check) cmd_check "$@" ;;
verify) cmd_verify "$@" ;;
reboot) cmd_reboot "$@" ;;
snapshot) cmd_snapshot "$@" ;;
*) usage ;;
esac
