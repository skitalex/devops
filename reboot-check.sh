#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "usage: $0 <command> [args]" >&2
  echo "commands:" >&2
  echo "  sum <a> <b>   sum of two non-negative integers" >&2
  echo "  eq <a> <b>    compare two strings" >&2
  echo "  check         is a reboot required (exit 1 if yes)" >&2
  exit 1
}

readonly REBOOT_FLAG=/var/run/reboot-required
readonly REBOOT_PKGS=/var/run/reboot-required.pkgs

function cmd_check() {
  if [[ -f "$REBOOT_FLAG" ]]; then
    echo "reboot required"
    if [[ -f "$REBOOT_PKGS" ]]; then
      echo "packages:"
      sed 's/^/  /' "$REBOOT_PKGS"
    fi
    return 1
  else
    echo "reboot not require"
  fi
}

readonly re='^[0-9]+$'
function cmd_is_eq() {
  [[ $# -eq 2 ]] || usage
  if [[ "$1" == "$2" ]]; then
    echo "eq"
  else
    echo "not eq"
  fi
}
function cmd_sum() {
  [[ $# -eq 2 ]] || usage
  if [[ "$1" =~ $re && "$2" =~ $re ]]; then
    echo "$((10#$1 + 10#$2))"
  else
    echo "args must be a number" >&2
    return 1
  fi
}

[[ $# -ge 1 ]] || usage

cmd=$1
shift

case "$cmd" in
  check) cmd_check "$@" ;;
  *) usage ;;
esac
