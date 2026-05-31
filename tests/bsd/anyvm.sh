#!/bin/sh

# SPDX-License-Identifier: MIT
#
# AnyVM wrapper to run tests/bsd/runner.sh inside BSD VMs.
#
# Environment:
#   ANYVM_IMAGE, ANYVM_CACHE, ANYVM_DATA, ANYVM_SYNC, ANYVM_WORKDIR, ANYVM_KVM,
#   ANYVM_FRESH, ANYVM_NO_LOCK, ANYVM_SSH_PORT, TEST_USER, VERBOSE.

set -eu

usage() {
  cat <<'EOF' >&2
Usage:
  sh tests/bsd/anyvm.sh <freebsd|openbsd|netbsd|dragonflybsd>
  sh tests/bsd/anyvm.sh --test <os|all>
  sh tests/bsd/anyvm.sh --cmd <string> <os|all>

Interactive: prepare on first boot, then TTY-backed user shell.
EOF
  exit 2
}

_home=${HOME:-/tmp}
_here=$(CDPATH="" cd -P -- "$(dirname -- "$0")" && pwd)
_repo=$(CDPATH="" cd -P -- "$_here/../.." && pwd)

_CACHE_MNT=/usr/local/anyvm-cache
_MNT=/mnt/host
_RUNNER=${_MNT}/tests/bsd/runner.sh

ANYVM_IMAGE=${ANYVM_IMAGE:-anyvm}
ANYVM_CACHE=${ANYVM_CACHE:-${_home}/.anyvm/cache}

_fail() {
  printf '%s: %s\n' "$0" "$1" >&2
  exit 2
}

_sq() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }

_has_qcow() {
  find "$@" -name '*.qcow2' 2>/dev/null | read -r _
}

_setup_image() {
  printf '==> image %s\n' "$ANYVM_IMAGE"
  _q=$([ "${VERBOSE:-0}" = 1 ] || printf '%s' '-q')
  # shellcheck disable=SC2086
  docker build $_q -f "${_here}/AnyVM.Dockerfile" -t "$ANYVM_IMAGE" "$_here" \
    || _fail 'docker build failed (set VERBOSE=1 for logs)'
}

_fix_ownership() {
  docker run --rm --entrypoint /bin/sh \
    -e "ANYVM_HOST_UID=${_uid}" \
    -e "ANYVM_HOST_GID=${_gid}" \
    -v "$ANYVM_CACHE:${_CACHE_MNT}" \
    -v "$_data:/data" \
    "$ANYVM_IMAGE" \
    -c "chown -R \"\${ANYVM_HOST_UID}:\${ANYVM_HOST_GID}\" /data ${_CACHE_MNT} 2>/dev/null || true"
}

_run_os() {
  _os=$1
  _uid=$(id -u)
  _gid=$(id -g)
  _user=${TEST_USER:-user}
  _port=${ANYVM_SSH_PORT:-10022}
  _data=${ANYVM_DATA:-"${_home}/.anyvm/data"}
  _data_os="${_data}/${_os}"
  _cache_os="${ANYVM_CACHE:?}/${_os}"
  _workdir=${ANYVM_WORKDIR:-/src}

  mkdir -p "$ANYVM_CACHE" "$_data"

  _fresh=
  if [ -n "${ANYVM_FRESH:-}" ]; then
    _fix_ownership
    rm -rf "$_cache_os" "$_data_os"
    _fresh=1
  elif ! _has_qcow "$_data_os"; then
    _fresh=1
  fi

  printf '==> AnyVM os=%s mode=%s user=%s\n' "$_os" "$_mode" "$_user"

  _env="BSD_USER='$(_sq "$_user")' BSD_WORKDIR='$(_sq "$_workdir")' BSD_SOURCE='$(_sq "$_MNT")'"
  [ -n "$_fresh" ] && _env="${_env} BSD_FRESH=1"
  [ "$_mode" = cmd ] && _env="${_env} BSD_RUN='$(_sq "$_cmd")'"
  _run="${_env} sh ${_RUNNER}"
  _prepare="${_run} prepare"
  _ensure="test -f '$(_sq "$_workdir")/.runner-setup' || ${_prepare}"
  _su_cmd="cd '$(_sq "$_workdir")' && exec sh"
  _user_sh="su -l '$(_sq "$_user")' -c '$(_sq "$_su_cmd")'"

  _docker_args=
  _tty=0
  case "$_mode" in
    interactive)
      _docker_args="-it"
      _tty=1
      _guest="${_ensure} && ${_user_sh}"
      printf '==> '
      [ -n "$_fresh" ] && printf 'preparing VM, then '
      printf 'opening shell as %s\n' "$_user"
      ;;
    *)
      _guest="${_prepare} && ${_run} test"
      ;;
  esac
  _guest="trap 'halt -p' EXIT INT TERM; ${_guest}"

  _kvm=
  [ "${ANYVM_KVM:-0}" = 1 ] && [ -e /dev/kvm ] && _kvm="--device /dev/kvm:/dev/kvm"

  if [ -z "${ANYVM_NO_LOCK:-}" ]; then
    _lockfile="${_home}/.anyvm/lock/${_os}"
    mkdir -p "${_home}/.anyvm/lock"
    set -- flock -n "$_lockfile"
  else
    set --
  fi

  # shellcheck disable=SC2086
  set -- "$@" docker run --rm $_docker_args $_kvm \
    -e "ANYVM_HOST_UID=${_uid}" \
    -e "ANYVM_HOST_GID=${_gid}" \
    -e "ANYVM_SSH_TTY=${_tty}" \
    -v "$_repo:${_MNT}" \
    -v "$ANYVM_CACHE:${_CACHE_MNT}" \
    -v "$_data:/data" \
    "$ANYVM_IMAGE" \
    --cache-dir "${_CACHE_MNT}" \
    --remote-vnc off \
    --os "$_os" \
    --sync "${ANYVM_SYNC:-sshfs}" \
    --ssh-port "$_port" \
    -- "/bin/sh -ec '$(_sq "$_guest")'"

  _dc=0
  "$@" || _dc=$?

  [ -n "${ANYVM_NO_LOCK:-}" ] && return "$_dc"
  [ "$_dc" -eq 0 ] && return 0
  flock -n "$_lockfile" true 2>/dev/null && return "$_dc"
  _fail "another AnyVM ${_os} is running (lock: ${_lockfile})"
}

# --- main ---
_mode=interactive
_cmd=
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage ;;
    --test|--cmd)
      [ "$_mode" = interactive ] || _fail 'only one of --test or --cmd'
      if [ "$1" = --test ]; then _mode='test'; else _mode=cmd; fi
      shift
      [ "$_mode" = cmd ] || continue
      [ $# -ge 1 ] || _fail '--cmd needs argument'
      _cmd=$1
      shift
      ;;
    *) break ;;
  esac
done

OS=${1:-}
[ -n "$OS" ] || usage

shift
[ $# -eq 0 ] || _fail 'extra arguments after OS'

case "$OS" in
  all) set -- freebsd openbsd netbsd dragonflybsd ;;
  freebsd|openbsd|netbsd|dragonflybsd) set -- "$OS" ;;
  *) usage ;;
esac

if [ "$_mode" = interactive ] && [ "$OS" = all ]; then
  _fail 'interactive mode does not support all (use --test all)'
fi

_setup_image || exit 1

_ec=0
for _os in "$@"; do
  _run_os "$_os" || _ec=1
done
exit "$_ec"
