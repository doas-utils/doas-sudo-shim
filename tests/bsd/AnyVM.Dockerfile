# syntax=docker/dockerfile:1
# Wrapper: patch AnyVM final SSH for TTY; chown mounts; stop QEMU on exit.

FROM ghcr.io/anyvm-org/anyvm

# Legacy builder ignores Dockerfile heredoc; use printf for the patch script.
RUN printf '%s\n' \
  'from pathlib import Path' \
  'import re' \
  '' \
  'path = Path("/anyvm.org/anyvm.py")' \
  'src = path.read_text()' \
  'pat = r"^(\s*)ssh_cmd = ssh_base_cmd \+ ssh_passthrough$"' \
  '' \
  'def repl(m):' \
  '    ind = m.group(1)' \
  '    return (' \
  '        f"{ind}ssh_cmd = ssh_base_cmd[:]\n"' \
  '        f"{ind}if os.environ.get(\"ANYVM_SSH_TTY\") == \"1\" and ssh_passthrough:\n"' \
  '        f"{ind}    ssh_cmd.insert(len(ssh_cmd) - 1, \"-tt\")\n"' \
  '        f"{ind}ssh_cmd += ssh_passthrough"' \
  '    )' \
  '' \
  'out = re.sub(pat, repl, src, count=1, flags=re.M)' \
  'assert out != src, "anyvm.py final SSH hook not found"' \
  'path.write_text(out)' \
  > /tmp/patch-anyvm-ssh.py \
  && python3 /tmp/patch-anyvm-ssh.py \
  && rm -f /tmp/patch-anyvm-ssh.py

RUN printf '%s\n' \
  '#!/bin/sh' \
  '# SPDX-License-Identifier: MIT' \
  'set -eu' \
  '' \
  'UPSTREAM=/anyvm.org/entrypoint.sh' \
  '' \
  '_chown_mounts() {' \
  '  if [ -z "${ANYVM_HOST_UID:-}" ] || [ -z "${ANYVM_HOST_GID:-}" ]; then' \
  '    return 0' \
  '  fi' \
  '  for d in /data /usr/local/anyvm-cache; do' \
  '    [ -d "$d" ] || continue' \
  '    chown -R "${ANYVM_HOST_UID}:${ANYVM_HOST_GID}" "$d" 2>/dev/null || true' \
  '    chmod 700 "$d" 2>/dev/null || true' \
  '    find "$d" -type d ! -perm 700 -exec chmod 700 {} + 2>/dev/null || true' \
  '    find "$d" -name '"'"'*-host.id_rsa'"'"' -exec chmod 600 {} + 2>/dev/null || true' \
  '  done' \
  '}' \
  '' \
  '_setup_kvm() {' \
  '  if [ -z "${ANYVM_HOST_UID:-}" ] || [ -z "${ANYVM_HOST_GID:-}" ]; then' \
  '    return 0' \
  '  fi' \
  '  if [ -e /dev/kvm ]; then' \
  '    chown "${ANYVM_HOST_UID}:${ANYVM_HOST_GID}" /dev/kvm 2>/dev/null || true' \
  '  fi' \
  '}' \
  '' \
  '_kill_qemu() {' \
  '  pids=$(ps -eo pid=,comm= 2>/dev/null | awk '"'"'$2 ~ /^qemu-system-/ { print $1 }'"'"') || pids=' \
  '  [ -n "$pids" ] || return 0' \
  '  kill -TERM $pids 2>/dev/null || true' \
  '  sleep 5' \
  '  kill -KILL $pids 2>/dev/null || true' \
  '}' \
  '' \
  'trap "_kill_qemu; _chown_mounts" EXIT' \
  "trap 'exit 130' INT" \
  "trap 'exit 143' TERM" \
  '' \
  '_chown_mounts' \
  '_setup_kvm' \
  '' \
  'if [ ! -x "$UPSTREAM" ]; then' \
  '  echo "entrypoint-wrapper: missing $UPSTREAM" >&2' \
  '  exit 1' \
  'fi' \
  '' \
  '"$UPSTREAM" "$@"' \
  > /anyvm.org/entrypoint-wrapper.sh && chmod +x /anyvm.org/entrypoint-wrapper.sh

ENTRYPOINT ["/anyvm.org/entrypoint-wrapper.sh"]
