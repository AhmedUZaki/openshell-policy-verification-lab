#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_FILE="$ROOT/tests/filesystem/.state/filesystem.env"
RESULTS_DIR="$ROOT/tests/filesystem/results"
STAMP="${AUDIT_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
[[ "$STAMP" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'The audit run ID contains unsafe characters.' >&2; exit 2; }
REPORT="$RESULTS_DIR/filesystem-$STAMP.md"
RAWLOG="$RESULTS_DIR/filesystem-$STAMP.raw.log"
OBS_ERROR_FILE="$ROOT/tests/filesystem/.state/observation-error"
[[ ! -e "$REPORT" && ! -e "$RAWLOG" ]] || { echo "Result files already exist for run ID: $STAMP" >&2; exit 2; }

export PATH="$HOME/.local/bin:$PATH"

if [[ ! -f "$STATE_FILE" ]]; then
  printf 'State file not found. Run tests/filesystem/setup-filesystem-test-environment.sh first.\n' >&2
  exit 2
fi
# shellcheck disable=SC1090
source "$STATE_FILE"
mkdir -p "$RESULTS_DIR"
: >"$RAWLOG"
rm -f "$OBS_ERROR_FILE"

run_sbx() {
  local name="$1" label="$2" command="$3"
  local output raw_output transport_rc rc
  raw_output="$(openshell sandbox exec --name "$name" --no-tty --timeout 40 -- \
    sh -c "( $command ); audit_command_rc=\$?; printf '\n__AUDIT_COMMAND_RC=%s\n' \"\$audit_command_rc\"; exit 0" 2>&1)"
  transport_rc=$?
  RUN_INFRA=0
  if [[ "$transport_rc" -ne 0 || ! "$raw_output" =~ __AUDIT_COMMAND_RC=([0-9]+) ]]; then
    RUN_INFRA=1
    rc=125
    output="$raw_output"
    touch "$OBS_ERROR_FILE"
  else
    rc="${BASH_REMATCH[1]}"
    output="$(printf '%s\n' "$raw_output" | sed '/^__AUDIT_COMMAND_RC=[0-9][0-9]*$/d')"
  fi
  {
    printf '\n===== %s | sandbox=%s | command_rc=%s | infrastructure_error=%s =====\n' "$label" "$name" "$rc" "$RUN_INFRA"
    printf '%s\n' "$raw_output"
  } >>"$RAWLOG"
  RUN_OUTPUT="$output"
  RUN_RC=$rc
}

hash_of() {
  local name="$1" path="$2" output rc
  output="$(openshell sandbox exec --name "$name" --no-tty --timeout 20 -- \
    sh -c "if test -f '$path'; then value=\$(sha256sum '$path' 2>/dev/null) || exit 3; printf '%s' \"\${value%% *}\"; else printf MISSING; fi" 2>/dev/null)"; rc=$?
  [[ "$rc" -eq 0 ]] || { touch "$OBS_ERROR_FILE"; return 2; }
  printf '%s\n' "$output"
}

size_of() {
  local name="$1" path="$2"
  local output rc
  output="$(openshell sandbox exec --name "$name" --no-tty --timeout 20 -- \
    sh -c "stat -c '%s' '$path' 2>/dev/null" 2>/dev/null)"; rc=$?
  [[ "$rc" -eq 0 ]] || { touch "$OBS_ERROR_FILE"; return 2; }
  printf '%s\n' "$output"
}

exists() {
  local name="$1" path="$2" output rc
  output="$(openshell sandbox exec --name "$name" --no-tty --timeout 20 -- \
    sh -c "if test -e '$path'; then printf EXISTS; else printf MISSING; fi" 2>/dev/null)"; rc=$?
  [[ "$rc" -eq 0 ]] || { touch "$OBS_ERROR_FILE"; return 2; }
  [[ "$output" == EXISTS ]]
}

mode_of() {
  local name="$1" path="$2"
  local output rc
  output="$(openshell sandbox exec --name "$name" --no-tty --timeout 20 -- \
    sh -c "stat -c '%a' '$path' 2>/dev/null" 2>/dev/null)"; rc=$?
  [[ "$rc" -eq 0 ]] || { touch "$OBS_ERROR_FILE"; return 2; }
  printf '%s\n' "$output"
}

mtime_of() {
  local name="$1" path="$2"
  local output rc
  output="$(openshell sandbox exec --name "$name" --no-tty --timeout 20 -- \
    sh -c "stat -c '%Y' '$path' 2>/dev/null" 2>/dev/null)"; rc=$?
  [[ "$rc" -eq 0 ]] || { touch "$OBS_ERROR_FILE"; return 2; }
  printf '%s\n' "$output"
}

xattr_of() {
  local name="$1" path="$2"
  local output rc
  output="$(openshell sandbox exec --name "$name" --no-tty --timeout 20 -- \
    sh -c "getfattr --only-values -n user.audit '$path' 2>/dev/null || true" 2>/dev/null)"; rc=$?
  [[ "$rc" -eq 0 ]] || { touch "$OBS_ERROR_FILE"; return 2; }
  printf '%s\n' "$output"
}

sandbox_is_healthy() {
  local name="$1"
  [[ "$(openshell sandbox exec --name "$name" --no-tty --timeout 10 -- sh -c 'printf AUDIT_SANDBOX_OK' 2>/dev/null)" == *AUDIT_SANDBOX_OK* ]]
}

printf 'Checking pristine fixtures...\n'
for name in "$RESTRICTIVE_NAME" "$PERMISSIVE_NAME"; do
  if ! exists "$name" /opt/claims-fixtures/readonly/delete.txt; then
    printf 'Fixture state is not pristine in %s. Recreate the sandboxes before rerunning.\n' "$name" >&2
    exit 2
  fi
  if [[ "$(size_of "$name" /opt/claims-fixtures/readonly/truncate.txt)" == "0" ]]; then
    printf 'F3_1 fixture is already empty in %s. Recreate the sandboxes.\n' "$name" >&2
    exit 2
  fi
  for path in modify.txt truncate.txt shell-truncate.txt python-open.txt overwrite.txt rename.txt chmod.txt hardlink.txt symlink-source.txt utime.txt xattr.txt cross-rename.txt copy-out.txt symlink-write.txt mmap.txt rdonly-truncate.txt execute-t35.sh; do
    if ! exists "$name" "/opt/claims-fixtures/readonly/$path"; then
      printf 'Extended fixture %s is missing in %s. Recreate the sandboxes.\n' "$path" "$name" >&2
      exit 2
    fi
  done
done

printf 'Running permissive controls...\n'
run_sbx "$PERMISSIVE_NAME" F1_1-control "cat /opt/claims-fixtures/hidden/read.txt"
F1_1_C_RC=$RUN_RC; F1_1_C_OUT=$RUN_OUTPUT

F2_1_C_BEFORE="$(hash_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/modify.txt)"
run_sbx "$PERMISSIVE_NAME" F2_1-control "echo TEST_CHANGE >> /opt/claims-fixtures/readonly/modify.txt"
F2_1_C_RC=$RUN_RC
F2_1_C_AFTER="$(hash_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/modify.txt)"

run_sbx "$PERMISSIVE_NAME" F3_1-control "python3 -c 'import os; os.truncate(\"/opt/claims-fixtures/readonly/truncate.txt\", 0)'"
F3_1_C_RC=$RUN_RC
F3_1_C_SIZE="$(size_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/truncate.txt)"

run_sbx "$PERMISSIVE_NAME" F4_1-control "rm -- /opt/claims-fixtures/readonly/delete.txt"
F4_1_C_RC=$RUN_RC
if exists "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/delete.txt; then F4_1_C_EXISTS=yes; else F4_1_C_EXISTS=no; fi

run_sbx "$PERMISSIVE_NAME" F3_2-control ": > /opt/claims-fixtures/readonly/shell-truncate.txt"
F3_2_C_RC=$RUN_RC; F3_2_C_SIZE="$(size_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/shell-truncate.txt)"

run_sbx "$PERMISSIVE_NAME" F2_2-control "python3 -c 'open(\"/opt/claims-fixtures/readonly/python-open.txt\", \"w\").close()'"
F2_2_C_RC=$RUN_RC; F2_2_C_SIZE="$(size_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/python-open.txt)"

F2_3_C_BEFORE="$(hash_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/overwrite.txt)"
run_sbx "$PERMISSIVE_NAME" F2_3-control "printf X | dd of=/opt/claims-fixtures/readonly/overwrite.txt conv=notrunc status=none"
F2_3_C_RC=$RUN_RC; F2_3_C_AFTER="$(hash_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/overwrite.txt)"

run_sbx "$PERMISSIVE_NAME" F4_2-control "mv /opt/claims-fixtures/readonly/rename.txt /opt/claims-fixtures/readonly/renamed-t14.txt"
F4_2_C_RC=$RUN_RC
if exists "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/rename.txt; then F4_2_C_OLD=yes; else F4_2_C_OLD=no; fi
if exists "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/renamed-t14.txt; then F4_2_C_NEW=yes; else F4_2_C_NEW=no; fi

run_sbx "$PERMISSIVE_NAME" F2_4-control "touch /opt/claims-fixtures/readonly/created-t15.txt"
F2_4_C_RC=$RUN_RC
if exists "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/created-t15.txt; then F2_4_C_EXISTS=yes; else F2_4_C_EXISTS=no; fi

F2_5_C_BEFORE="$(mode_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/chmod.txt)"
run_sbx "$PERMISSIVE_NAME" F2_5-control "chmod 0600 /opt/claims-fixtures/readonly/chmod.txt"
F2_5_C_RC=$RUN_RC; F2_5_C_AFTER="$(mode_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/chmod.txt)"

run_sbx "$PERMISSIVE_NAME" F2_6-control "ln /opt/claims-fixtures/readonly/hardlink.txt /opt/claims-fixtures/readonly/hardlink-created-t21"
F2_6_C_RC=$RUN_RC; if exists "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/hardlink-created-t21; then F2_6_C_EXISTS=yes; else F2_6_C_EXISTS=no; fi

run_sbx "$PERMISSIVE_NAME" F2_7-control "ln -s symlink-source.txt /opt/claims-fixtures/readonly/symlink-created-t22"
F2_7_C_RC=$RUN_RC; if exists "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/symlink-created-t22; then F2_7_C_EXISTS=yes; else F2_7_C_EXISTS=no; fi

run_sbx "$PERMISSIVE_NAME" F2_8-control "mkdir /opt/claims-fixtures/readonly/created-dir-t23"
F2_8_C_RC=$RUN_RC; if exists "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/created-dir-t23; then F2_8_C_EXISTS=yes; else F2_8_C_EXISTS=no; fi

run_sbx "$PERMISSIVE_NAME" F4_3-control "rmdir /opt/claims-fixtures/readonly/empty-dir-t24"
F4_3_C_RC=$RUN_RC; if exists "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/empty-dir-t24; then F4_3_C_EXISTS=yes; else F4_3_C_EXISTS=no; fi

F2_9_C_BEFORE="$(mtime_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/utime.txt)"
run_sbx "$PERMISSIVE_NAME" F2_9-control "touch -d @1000000000 /opt/claims-fixtures/readonly/utime.txt"
F2_9_C_RC=$RUN_RC; F2_9_C_AFTER="$(mtime_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/utime.txt)"

run_sbx "$PERMISSIVE_NAME" F2_10-control "setfattr -n user.audit -v control /opt/claims-fixtures/readonly/xattr.txt"
F2_10_C_RC=$RUN_RC; F2_10_C_VALUE="$(xattr_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/xattr.txt)"

run_sbx "$PERMISSIVE_NAME" F4_4-control "mv /opt/claims-fixtures/readonly/cross-rename.txt /work/cross-renamed-t27.txt"
F4_4_C_RC=$RUN_RC
if exists "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/cross-rename.txt; then F4_4_C_OLD=yes; else F4_4_C_OLD=no; fi
if exists "$PERMISSIVE_NAME" /work/cross-renamed-t27.txt; then F4_4_C_NEW=yes; else F4_4_C_NEW=no; fi

F2_11_C_SOURCE="$(hash_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/copy-out.txt)"
run_sbx "$PERMISSIVE_NAME" F2_11-control "cp /opt/claims-fixtures/readonly/copy-out.txt /work/copied-t28.txt"
F2_11_C_RC=$RUN_RC; F2_11_C_DEST="$(hash_of "$PERMISSIVE_NAME" /work/copied-t28.txt)"

run_sbx "$PERMISSIVE_NAME" F2_12-control "cat /opt/claims-fixtures/readonly/hidden-link-t29"
F2_12_C_RC=$RUN_RC; F2_12_C_OUT=$RUN_OUTPUT

F2_13_C_BEFORE="$(hash_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/symlink-write.txt)"
run_sbx "$PERMISSIVE_NAME" F2_13-control "ln -s /opt/claims-fixtures/readonly/symlink-write.txt /work/t30-link && echo VIA_SYMLINK >> /work/t30-link"
F2_13_C_RC=$RUN_RC; F2_13_C_AFTER="$(hash_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/symlink-write.txt)"

F2_14_C_BEFORE="$(hash_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/mmap.txt)"
run_sbx "$PERMISSIVE_NAME" F2_14-control "python3 -c 'import mmap; p=\"/opt/claims-fixtures/readonly/mmap.txt\"; f=open(p,\"r+b\"); m=mmap.mmap(f.fileno(),0); m[0:1]=b\"X\"; m.flush(); m.close(); f.close()'"
F2_14_C_RC=$RUN_RC; F2_14_C_AFTER="$(hash_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/mmap.txt)"

run_sbx "$PERMISSIVE_NAME" F3_3-control "python3 -c 'import os; fd=os.open(\"/opt/claims-fixtures/readonly/rdonly-truncate.txt\", os.O_RDONLY|os.O_TRUNC); os.close(fd)'"
F3_3_C_RC=$RUN_RC; F3_3_C_SIZE="$(size_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/rdonly-truncate.txt)"

run_sbx "$PERMISSIVE_NAME" F2_15-control "python3 -c 'import socket; s=socket.socket(socket.AF_UNIX); s.bind(\"/opt/claims-fixtures/readonly/socket-t33\"); s.close()'"
F2_15_C_RC=$RUN_RC; if exists "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/socket-t33; then F2_15_C_EXISTS=yes; else F2_15_C_EXISTS=no; fi

run_sbx "$PERMISSIVE_NAME" F2_16-control "mkfifo /opt/claims-fixtures/readonly/fifo-t34"
F2_16_C_RC=$RUN_RC; if exists "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/fifo-t34; then F2_16_C_EXISTS=yes; else F2_16_C_EXISTS=no; fi

run_sbx "$PERMISSIVE_NAME" F2_17-control "/opt/claims-fixtures/readonly/execute-t35.sh"
F2_17_C_RC=$RUN_RC; F2_17_C_OUT=$RUN_OUTPUT

run_sbx "$PERMISSIVE_NAME" F1_2-control "stat -c '%n:%s:%a' /opt/claims-fixtures/hidden/read.txt"
F1_2_C_RC=$RUN_RC; F1_2_C_OUT=$RUN_OUTPUT

printf 'Running restrictive tests...\n'
run_sbx "$RESTRICTIVE_NAME" F1_1-restrictive "cat /opt/claims-fixtures/hidden/read.txt"
F1_1_R_RC=$RUN_RC; F1_1_R_OUT=$RUN_OUTPUT

F2_1_R_BEFORE="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/modify.txt)"
run_sbx "$RESTRICTIVE_NAME" F2_1-restrictive "echo TEST_CHANGE >> /opt/claims-fixtures/readonly/modify.txt"
F2_1_R_RC=$RUN_RC
F2_1_R_AFTER="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/modify.txt)"

F3_1_R_BEFORE="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/truncate.txt)"
run_sbx "$RESTRICTIVE_NAME" F3_1-restrictive "python3 -c 'import os; os.truncate(\"/opt/claims-fixtures/readonly/truncate.txt\", 0)'"
F3_1_R_RC=$RUN_RC
F3_1_R_AFTER="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/truncate.txt)"
F3_1_R_SIZE="$(size_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/truncate.txt)"

run_sbx "$RESTRICTIVE_NAME" F4_1-restrictive "rm -- /opt/claims-fixtures/readonly/delete.txt"
F4_1_R_RC=$RUN_RC
if exists "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/delete.txt; then F4_1_R_EXISTS=yes; else F4_1_R_EXISTS=no; fi

F3_2_R_BEFORE="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/shell-truncate.txt)"
run_sbx "$RESTRICTIVE_NAME" F3_2-restrictive ": > /opt/claims-fixtures/readonly/shell-truncate.txt"
F3_2_R_RC=$RUN_RC; F3_2_R_AFTER="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/shell-truncate.txt)"; F3_2_R_SIZE="$(size_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/shell-truncate.txt)"

F2_2_R_BEFORE="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/python-open.txt)"
run_sbx "$RESTRICTIVE_NAME" F2_2-restrictive "python3 -c 'open(\"/opt/claims-fixtures/readonly/python-open.txt\", \"w\").close()'"
F2_2_R_RC=$RUN_RC; F2_2_R_AFTER="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/python-open.txt)"; F2_2_R_SIZE="$(size_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/python-open.txt)"

F2_3_R_BEFORE="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/overwrite.txt)"
run_sbx "$RESTRICTIVE_NAME" F2_3-restrictive "printf X | dd of=/opt/claims-fixtures/readonly/overwrite.txt conv=notrunc status=none"
F2_3_R_RC=$RUN_RC; F2_3_R_AFTER="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/overwrite.txt)"

run_sbx "$RESTRICTIVE_NAME" F4_2-restrictive "mv /opt/claims-fixtures/readonly/rename.txt /opt/claims-fixtures/readonly/renamed-t14.txt"
F4_2_R_RC=$RUN_RC
if exists "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/rename.txt; then F4_2_R_OLD=yes; else F4_2_R_OLD=no; fi
if exists "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/renamed-t14.txt; then F4_2_R_NEW=yes; else F4_2_R_NEW=no; fi

run_sbx "$RESTRICTIVE_NAME" F2_4-restrictive "touch /opt/claims-fixtures/readonly/created-t15.txt"
F2_4_R_RC=$RUN_RC
if exists "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/created-t15.txt; then F2_4_R_EXISTS=yes; else F2_4_R_EXISTS=no; fi

F2_5_R_BEFORE="$(mode_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/chmod.txt)"
run_sbx "$RESTRICTIVE_NAME" F2_5-restrictive "chmod 0600 /opt/claims-fixtures/readonly/chmod.txt"
F2_5_R_RC=$RUN_RC; F2_5_R_AFTER="$(mode_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/chmod.txt)"

run_sbx "$RESTRICTIVE_NAME" F2_6-restrictive "ln /opt/claims-fixtures/readonly/hardlink.txt /opt/claims-fixtures/readonly/hardlink-created-t21"
F2_6_R_RC=$RUN_RC; if exists "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/hardlink-created-t21; then F2_6_R_EXISTS=yes; else F2_6_R_EXISTS=no; fi

run_sbx "$RESTRICTIVE_NAME" F2_7-restrictive "ln -s symlink-source.txt /opt/claims-fixtures/readonly/symlink-created-t22"
F2_7_R_RC=$RUN_RC; if exists "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/symlink-created-t22; then F2_7_R_EXISTS=yes; else F2_7_R_EXISTS=no; fi

run_sbx "$RESTRICTIVE_NAME" F2_8-restrictive "mkdir /opt/claims-fixtures/readonly/created-dir-t23"
F2_8_R_RC=$RUN_RC; if exists "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/created-dir-t23; then F2_8_R_EXISTS=yes; else F2_8_R_EXISTS=no; fi

run_sbx "$RESTRICTIVE_NAME" F4_3-restrictive "rmdir /opt/claims-fixtures/readonly/empty-dir-t24"
F4_3_R_RC=$RUN_RC; if exists "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/empty-dir-t24; then F4_3_R_EXISTS=yes; else F4_3_R_EXISTS=no; fi

F2_9_R_BEFORE="$(mtime_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/utime.txt)"
run_sbx "$RESTRICTIVE_NAME" F2_9-restrictive "touch -d @1000000000 /opt/claims-fixtures/readonly/utime.txt"
F2_9_R_RC=$RUN_RC; F2_9_R_AFTER="$(mtime_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/utime.txt)"

run_sbx "$RESTRICTIVE_NAME" F2_10-restrictive "setfattr -n user.audit -v restrictive /opt/claims-fixtures/readonly/xattr.txt"
F2_10_R_RC=$RUN_RC; F2_10_R_VALUE="$(xattr_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/xattr.txt)"

run_sbx "$RESTRICTIVE_NAME" F4_4-restrictive "mv /opt/claims-fixtures/readonly/cross-rename.txt /work/cross-renamed-t27.txt"
F4_4_R_RC=$RUN_RC
if exists "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/cross-rename.txt; then F4_4_R_OLD=yes; else F4_4_R_OLD=no; fi
if exists "$RESTRICTIVE_NAME" /work/cross-renamed-t27.txt; then F4_4_R_NEW=yes; else F4_4_R_NEW=no; fi

F2_11_R_SOURCE="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/copy-out.txt)"
run_sbx "$RESTRICTIVE_NAME" F2_11-restrictive "cp /opt/claims-fixtures/readonly/copy-out.txt /work/copied-t28.txt"
F2_11_R_RC=$RUN_RC; F2_11_R_DEST="$(hash_of "$RESTRICTIVE_NAME" /work/copied-t28.txt)"

run_sbx "$RESTRICTIVE_NAME" F2_12-restrictive "cat /opt/claims-fixtures/readonly/hidden-link-t29"
F2_12_R_RC=$RUN_RC; F2_12_R_OUT=$RUN_OUTPUT

F2_13_R_BEFORE="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/symlink-write.txt)"
run_sbx "$RESTRICTIVE_NAME" F2_13-restrictive "ln -s /opt/claims-fixtures/readonly/symlink-write.txt /work/t30-link && echo VIA_SYMLINK >> /work/t30-link"
F2_13_R_RC=$RUN_RC; F2_13_R_AFTER="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/symlink-write.txt)"

F2_14_R_BEFORE="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/mmap.txt)"
run_sbx "$RESTRICTIVE_NAME" F2_14-restrictive "python3 -c 'import mmap; p=\"/opt/claims-fixtures/readonly/mmap.txt\"; f=open(p,\"r+b\"); m=mmap.mmap(f.fileno(),0); m[0:1]=b\"X\"; m.flush(); m.close(); f.close()'"
F2_14_R_RC=$RUN_RC; F2_14_R_AFTER="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/mmap.txt)"

F3_3_R_BEFORE="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/rdonly-truncate.txt)"
run_sbx "$RESTRICTIVE_NAME" F3_3-restrictive "python3 -c 'import os; fd=os.open(\"/opt/claims-fixtures/readonly/rdonly-truncate.txt\", os.O_RDONLY|os.O_TRUNC); os.close(fd)'"
F3_3_R_RC=$RUN_RC; F3_3_R_AFTER="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/rdonly-truncate.txt)"; F3_3_R_SIZE="$(size_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/rdonly-truncate.txt)"

run_sbx "$RESTRICTIVE_NAME" F2_15-restrictive "python3 -c 'import socket; s=socket.socket(socket.AF_UNIX); s.bind(\"/opt/claims-fixtures/readonly/socket-t33\"); s.close()'"
F2_15_R_RC=$RUN_RC; if exists "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/socket-t33; then F2_15_R_EXISTS=yes; else F2_15_R_EXISTS=no; fi

run_sbx "$RESTRICTIVE_NAME" F2_16-restrictive "mkfifo /opt/claims-fixtures/readonly/fifo-t34"
F2_16_R_RC=$RUN_RC; if exists "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/fifo-t34; then F2_16_R_EXISTS=yes; else F2_16_R_EXISTS=no; fi

run_sbx "$RESTRICTIVE_NAME" F2_17-restrictive "/opt/claims-fixtures/readonly/execute-t35.sh"
F2_17_R_RC=$RUN_RC; F2_17_R_OUT=$RUN_OUTPUT

run_sbx "$RESTRICTIVE_NAME" F1_2-restrictive "stat -c '%n:%s:%a' /opt/claims-fixtures/hidden/read.txt"
F1_2_R_RC=$RUN_RC; F1_2_R_OUT=$RUN_OUTPUT

if [[ -f "$OBS_ERROR_FILE" ]] || ! sandbox_is_healthy "$PERMISSIVE_NAME" || ! sandbox_is_healthy "$RESTRICTIVE_NAME"; then
  printf 'Infrastructure or observation failure detected. No enforcement verdicts will be inferred from generic command errors.\n' >&2
  exit 2
fi

if [[ $F1_1_C_RC -ne 0 || "$F1_1_C_OUT" != *HIDDEN_MARKER_F1_1* ]]; then
  F1_1_VERDICT=INCONCLUSIVE; F1_1_DETAIL="Permissive read control failed"
elif [[ $F1_1_R_RC -ne 0 && "$F1_1_R_OUT" != *HIDDEN_MARKER_F1_1* ]]; then
  F1_1_VERDICT=PASS; F1_1_DETAIL="Control revealed marker; restrictive read did not"
else
  F1_1_VERDICT=FAIL; F1_1_DETAIL="Restrictive read revealed the hidden marker"
fi

if [[ $F2_1_C_RC -ne 0 || "$F2_1_C_BEFORE" == "$F2_1_C_AFTER" ]]; then
  F2_1_VERDICT=INCONCLUSIVE; F2_1_DETAIL="Permissive append control did not change content"
elif [[ $F2_1_R_RC -ne 0 && "$F2_1_R_BEFORE" == "$F2_1_R_AFTER" ]]; then
  F2_1_VERDICT=PASS; F2_1_DETAIL="Restrictive append denied; hash unchanged"
else
  F2_1_VERDICT=FAIL; F2_1_DETAIL="Restrictive append rc=$F2_1_R_RC; before=$F2_1_R_BEFORE after=$F2_1_R_AFTER"
fi

if [[ $F3_1_C_RC -ne 0 || "$F3_1_C_SIZE" != "0" ]]; then
  F3_1_VERDICT=INCONCLUSIVE; F3_1_DETAIL="Permissive truncate control failed"
elif [[ $F3_1_R_RC -ne 0 && "$F3_1_R_BEFORE" == "$F3_1_R_AFTER" && "$F3_1_R_SIZE" != "0" ]]; then
  F3_1_VERDICT=PASS; F3_1_DETAIL="Restrictive truncate denied; size/hash unchanged"
else
  F3_1_VERDICT=FAIL; F3_1_DETAIL="Restrictive truncate rc=$F3_1_R_RC; size=$F3_1_R_SIZE; hash changed=$([[ "$F3_1_R_BEFORE" != "$F3_1_R_AFTER" ]] && echo yes || echo no)"
fi

if [[ $F4_1_C_RC -ne 0 || "$F4_1_C_EXISTS" != "no" ]]; then
  F4_1_VERDICT=INCONCLUSIVE; F4_1_DETAIL="Permissive delete control failed"
elif [[ $F4_1_R_RC -ne 0 && "$F4_1_R_EXISTS" == "yes" ]]; then
  F4_1_VERDICT=PASS; F4_1_DETAIL="Restrictive delete denied; file remains"
else
  F4_1_VERDICT=FAIL; F4_1_DETAIL="Restrictive delete rc=$F4_1_R_RC; file_exists=$F4_1_R_EXISTS"
fi

if [[ $F3_2_C_RC -ne 0 || "$F3_2_C_SIZE" != 0 ]]; then
  F3_2_VERDICT=INCONCLUSIVE; F3_2_DETAIL="Permissive shell-truncate control failed"
elif [[ $F3_2_R_RC -ne 0 && "$F3_2_R_BEFORE" == "$F3_2_R_AFTER" && "$F3_2_R_SIZE" != 0 ]]; then
  F3_2_VERDICT=PASS; F3_2_DETAIL="Shell redirection truncate denied; content unchanged"
else
  F3_2_VERDICT=FAIL; F3_2_DETAIL="Shell truncate rc=$F3_2_R_RC; size=$F3_2_R_SIZE; hash changed=$([[ "$F3_2_R_BEFORE" != "$F3_2_R_AFTER" ]] && echo yes || echo no)"
fi

if [[ $F2_2_C_RC -ne 0 || "$F2_2_C_SIZE" != 0 ]]; then
  F2_2_VERDICT=INCONCLUSIVE; F2_2_DETAIL="Permissive Python open(w) control failed"
elif [[ $F2_2_R_RC -ne 0 && "$F2_2_R_BEFORE" == "$F2_2_R_AFTER" && "$F2_2_R_SIZE" != 0 ]]; then
  F2_2_VERDICT=PASS; F2_2_DETAIL="Python open(w) denied; content unchanged"
else
  F2_2_VERDICT=FAIL; F2_2_DETAIL="Python open(w) rc=$F2_2_R_RC; size=$F2_2_R_SIZE; hash changed=$([[ "$F2_2_R_BEFORE" != "$F2_2_R_AFTER" ]] && echo yes || echo no)"
fi

if [[ $F2_3_C_RC -ne 0 || "$F2_3_C_BEFORE" == "$F2_3_C_AFTER" ]]; then
  F2_3_VERDICT=INCONCLUSIVE; F2_3_DETAIL="Permissive in-place overwrite control failed"
elif [[ $F2_3_R_RC -ne 0 && "$F2_3_R_BEFORE" == "$F2_3_R_AFTER" ]]; then
  F2_3_VERDICT=PASS; F2_3_DETAIL="In-place overwrite denied; hash unchanged"
else
  F2_3_VERDICT=FAIL; F2_3_DETAIL="In-place overwrite rc=$F2_3_R_RC; hash changed=$([[ "$F2_3_R_BEFORE" != "$F2_3_R_AFTER" ]] && echo yes || echo no)"
fi

if [[ $F4_2_C_RC -ne 0 || "$F4_2_C_OLD" != no || "$F4_2_C_NEW" != yes ]]; then
  F4_2_VERDICT=INCONCLUSIVE; F4_2_DETAIL="Permissive rename control failed"
elif [[ $F4_2_R_RC -ne 0 && "$F4_2_R_OLD" == yes && "$F4_2_R_NEW" == no ]]; then
  F4_2_VERDICT=PASS; F4_2_DETAIL="Rename denied; original remains and destination absent"
else
  F4_2_VERDICT=FAIL; F4_2_DETAIL="Rename rc=$F4_2_R_RC; old=$F4_2_R_OLD new=$F4_2_R_NEW"
fi

if [[ $F2_4_C_RC -ne 0 || "$F2_4_C_EXISTS" != yes ]]; then
  F2_4_VERDICT=INCONCLUSIVE; F2_4_DETAIL="Permissive file-creation control failed"
elif [[ $F2_4_R_RC -ne 0 && "$F2_4_R_EXISTS" == no ]]; then
  F2_4_VERDICT=PASS; F2_4_DETAIL="New file creation denied"
else
  F2_4_VERDICT=FAIL; F2_4_DETAIL="Creation rc=$F2_4_R_RC; file_exists=$F2_4_R_EXISTS"
fi

if [[ $F2_5_C_RC -ne 0 || "$F2_5_C_AFTER" != 600 || -z "$F2_5_R_BEFORE" || -z "$F2_5_R_AFTER" ]]; then
  F2_5_VERDICT=INCONCLUSIVE; F2_5_DETAIL="Permissive chmod control failed"
elif [[ "$F2_5_R_BEFORE" == "$F2_5_R_AFTER" ]]; then
  F2_5_VERDICT=PASS; F2_5_DETAIL="chmod did not change mode; rc=$F2_5_R_RC"
elif [[ "$F2_5_R_AFTER" == 600 ]]; then
  F2_5_VERDICT=LANDLOCK-LIMITATION; F2_5_DETAIL="chmod changed metadata as Landlock does not mediate chmod; rc=$F2_5_R_RC before=$F2_5_R_BEFORE after=$F2_5_R_AFTER"
else
  F2_5_VERDICT=FAIL; F2_5_DETAIL="chmod produced an unexpected mode; rc=$F2_5_R_RC before=$F2_5_R_BEFORE after=$F2_5_R_AFTER"
fi

if [[ $F2_6_C_RC -ne 0 || "$F2_6_C_EXISTS" != yes ]]; then
  F2_6_VERDICT=INCONCLUSIVE; F2_6_DETAIL="Permissive hard-link control failed"
elif [[ $F2_6_R_RC -ne 0 && "$F2_6_R_EXISTS" == no ]]; then
  F2_6_VERDICT=PASS; F2_6_DETAIL="Hard-link creation in read_only directory denied"
else
  F2_6_VERDICT=FAIL; F2_6_DETAIL="Hard-link rc=$F2_6_R_RC; created=$F2_6_R_EXISTS"
fi

if [[ $F2_7_C_RC -ne 0 || "$F2_7_C_EXISTS" != yes ]]; then
  F2_7_VERDICT=INCONCLUSIVE; F2_7_DETAIL="Permissive symlink-creation control failed"
elif [[ $F2_7_R_RC -ne 0 && "$F2_7_R_EXISTS" == no ]]; then
  F2_7_VERDICT=PASS; F2_7_DETAIL="Symlink creation in read_only directory denied"
else
  F2_7_VERDICT=FAIL; F2_7_DETAIL="Symlink creation rc=$F2_7_R_RC; created=$F2_7_R_EXISTS"
fi

if [[ $F2_8_C_RC -ne 0 || "$F2_8_C_EXISTS" != yes ]]; then
  F2_8_VERDICT=INCONCLUSIVE; F2_8_DETAIL="Permissive mkdir control failed"
elif [[ $F2_8_R_RC -ne 0 && "$F2_8_R_EXISTS" == no ]]; then
  F2_8_VERDICT=PASS; F2_8_DETAIL="Directory creation under read_only denied"
else
  F2_8_VERDICT=FAIL; F2_8_DETAIL="mkdir rc=$F2_8_R_RC; created=$F2_8_R_EXISTS"
fi

if [[ $F4_3_C_RC -ne 0 || "$F4_3_C_EXISTS" != no ]]; then
  F4_3_VERDICT=INCONCLUSIVE; F4_3_DETAIL="Permissive rmdir control failed"
elif [[ $F4_3_R_RC -ne 0 && "$F4_3_R_EXISTS" == yes ]]; then
  F4_3_VERDICT=PASS; F4_3_DETAIL="Removal of directory under read_only denied"
else
  F4_3_VERDICT=FAIL; F4_3_DETAIL="rmdir rc=$F4_3_R_RC; directory_exists=$F4_3_R_EXISTS"
fi

if [[ $F2_9_C_RC -ne 0 || "$F2_9_C_BEFORE" == "$F2_9_C_AFTER" || -z "$F2_9_R_BEFORE" || -z "$F2_9_R_AFTER" ]]; then
  F2_9_VERDICT=INCONCLUSIVE; F2_9_DETAIL="Permissive timestamp control failed"
elif [[ "$F2_9_R_BEFORE" == "$F2_9_R_AFTER" ]]; then
  F2_9_VERDICT=PASS; F2_9_DETAIL="Timestamp did not change; rc=$F2_9_R_RC"
elif [[ "$F2_9_R_AFTER" == 1000000000 ]]; then
  F2_9_VERDICT=LANDLOCK-LIMITATION; F2_9_DETAIL="utime metadata changed; Landlock does not mediate utime; rc=$F2_9_R_RC before=$F2_9_R_BEFORE after=$F2_9_R_AFTER"
else
  F2_9_VERDICT=FAIL; F2_9_DETAIL="utime produced an unexpected timestamp; rc=$F2_9_R_RC before=$F2_9_R_BEFORE after=$F2_9_R_AFTER"
fi

if [[ $F2_10_C_RC -ne 0 || "$F2_10_C_VALUE" != control ]]; then
  F2_10_VERDICT=INCONCLUSIVE; F2_10_DETAIL="Permissive xattr control failed"
elif [[ -z "$F2_10_R_VALUE" ]]; then
  F2_10_VERDICT=PASS; F2_10_DETAIL="Extended attribute did not change; rc=$F2_10_R_RC"
elif [[ "$F2_10_R_VALUE" == restrictive ]]; then
  F2_10_VERDICT=LANDLOCK-LIMITATION; F2_10_DETAIL="user xattr changed; Landlock does not mediate setxattr; rc=$F2_10_R_RC value=$F2_10_R_VALUE"
else
  F2_10_VERDICT=FAIL; F2_10_DETAIL="setxattr produced an unexpected value; rc=$F2_10_R_RC value=$F2_10_R_VALUE"
fi

if [[ $F4_4_C_RC -ne 0 || "$F4_4_C_OLD" != no || "$F4_4_C_NEW" != yes ]]; then
  F4_4_VERDICT=INCONCLUSIVE; F4_4_DETAIL="Permissive cross-directory rename control failed"
elif [[ $F4_4_R_RC -ne 0 && "$F4_4_R_OLD" == yes && "$F4_4_R_NEW" == no ]]; then
  F4_4_VERDICT=PASS; F4_4_DETAIL="Rename from read_only into writable directory denied"
else
  F4_4_VERDICT=FAIL; F4_4_DETAIL="Cross-rename rc=$F4_4_R_RC; source=$F4_4_R_OLD destination=$F4_4_R_NEW"
fi

if [[ $F2_11_C_RC -ne 0 || -z "$F2_11_C_SOURCE" || "$F2_11_C_SOURCE" != "$F2_11_C_DEST" ]]; then
  F2_11_VERDICT=INCONCLUSIVE; F2_11_DETAIL="Permissive copy-out control failed"
elif [[ $F2_11_R_RC -eq 0 && -n "$F2_11_R_SOURCE" && "$F2_11_R_SOURCE" == "$F2_11_R_DEST" ]]; then
  F2_11_VERDICT=PASS; F2_11_DETAIL="Positive control: read_only content copied into writable /work"
else
  F2_11_VERDICT=FAIL; F2_11_DETAIL="Allowed copy-out was blocked or corrupted; rc=$F2_11_R_RC"
fi

if [[ $F2_12_C_RC -ne 0 || "$F2_12_C_OUT" != *HIDDEN_MARKER_F1_1* ]]; then
  F2_12_VERDICT=INCONCLUSIVE; F2_12_DETAIL="Permissive symlink-read control failed"
elif [[ $F2_12_R_RC -ne 0 && "$F2_12_R_OUT" != *HIDDEN_MARKER_F1_1* ]]; then
  F2_12_VERDICT=PASS; F2_12_DETAIL="Symlink did not bypass target-path read restriction"
else
  F2_12_VERDICT=FAIL; F2_12_DETAIL="Symlink exposed content from an ungranted target"
fi

if [[ $F2_13_C_RC -ne 0 || "$F2_13_C_BEFORE" == "$F2_13_C_AFTER" ]]; then
  F2_13_VERDICT=INCONCLUSIVE; F2_13_DETAIL="Permissive write-through-symlink control failed"
elif [[ $F2_13_R_RC -ne 0 && "$F2_13_R_BEFORE" == "$F2_13_R_AFTER" ]]; then
  F2_13_VERDICT=PASS; F2_13_DETAIL="Writable-directory symlink did not bypass read_only target"
else
  F2_13_VERDICT=FAIL; F2_13_DETAIL="Symlink write rc=$F2_13_R_RC; content_changed=$([[ "$F2_13_R_BEFORE" != "$F2_13_R_AFTER" ]] && echo yes || echo no)"
fi

if [[ $F2_14_C_RC -ne 0 || "$F2_14_C_BEFORE" == "$F2_14_C_AFTER" ]]; then
  F2_14_VERDICT=INCONCLUSIVE; F2_14_DETAIL="Permissive mmap control failed"
elif [[ $F2_14_R_RC -ne 0 && "$F2_14_R_BEFORE" == "$F2_14_R_AFTER" ]]; then
  F2_14_VERDICT=PASS; F2_14_DETAIL="Writable mmap attempt denied; content unchanged"
else
  F2_14_VERDICT=FAIL; F2_14_DETAIL="mmap rc=$F2_14_R_RC; content_changed=$([[ "$F2_14_R_BEFORE" != "$F2_14_R_AFTER" ]] && echo yes || echo no)"
fi

if [[ $F3_3_C_RC -ne 0 || "$F3_3_C_SIZE" != 0 ]]; then
  F3_3_VERDICT=INCONCLUSIVE; F3_3_DETAIL="Permissive O_RDONLY|O_TRUNC control failed"
elif [[ $F3_3_R_RC -ne 0 && "$F3_3_R_BEFORE" == "$F3_3_R_AFTER" && "$F3_3_R_SIZE" != 0 ]]; then
  F3_3_VERDICT=PASS; F3_3_DETAIL="O_RDONLY|O_TRUNC denied; content unchanged"
else
  F3_3_VERDICT=FAIL; F3_3_DETAIL="O_RDONLY|O_TRUNC changed content under the applied read_only policy; rc=$F3_3_R_RC size=$F3_3_R_SIZE"
fi

if [[ $F2_15_C_RC -ne 0 || "$F2_15_C_EXISTS" != yes ]]; then
  F2_15_VERDICT=INCONCLUSIVE; F2_15_DETAIL="Permissive UNIX-socket control failed"
elif [[ $F2_15_R_RC -ne 0 && "$F2_15_R_EXISTS" == no ]]; then
  F2_15_VERDICT=PASS; F2_15_DETAIL="UNIX socket creation under read_only denied"
else
  F2_15_VERDICT=FAIL; F2_15_DETAIL="UNIX socket bind rc=$F2_15_R_RC; created=$F2_15_R_EXISTS"
fi

if [[ $F2_16_C_RC -ne 0 || "$F2_16_C_EXISTS" != yes ]]; then
  F2_16_VERDICT=INCONCLUSIVE; F2_16_DETAIL="Permissive FIFO control failed"
elif [[ $F2_16_R_RC -ne 0 && "$F2_16_R_EXISTS" == no ]]; then
  F2_16_VERDICT=PASS; F2_16_DETAIL="FIFO creation under read_only denied"
else
  F2_16_VERDICT=FAIL; F2_16_DETAIL="mkfifo rc=$F2_16_R_RC; created=$F2_16_R_EXISTS"
fi

if [[ $F2_17_C_RC -ne 0 || "$F2_17_C_OUT" != *EXEC_MARKER_F2_17* ]]; then
  F2_17_VERDICT=INCONCLUSIVE; F2_17_DETAIL="Permissive execution control failed"
elif [[ $F2_17_R_RC -eq 0 && "$F2_17_R_OUT" == *EXEC_MARKER_F2_17* ]]; then
  F2_17_VERDICT=EXPECTED; F2_17_DETAIL="Execution from read_only is intentionally allowed; file content remained protected"
else
  F2_17_VERDICT=FAIL; F2_17_DETAIL="Execution from read_only was unexpectedly blocked; rc=$F2_17_R_RC"
fi

if [[ $F1_2_C_RC -ne 0 || -z "$F1_2_C_OUT" ]]; then
  F1_2_VERDICT=INCONCLUSIVE; F1_2_DETAIL="Permissive stat control failed"
elif [[ $F1_2_R_RC -ne 0 && -z "$F1_2_R_OUT" ]]; then
  F1_2_VERDICT=PASS; F1_2_DETAIL="Metadata lookup on ungranted path denied"
elif [[ $F1_2_R_RC -eq 0 && -n "$F1_2_R_OUT" ]]; then
  F1_2_VERDICT=LANDLOCK-LIMITATION; F1_2_DETAIL="stat exposed path metadata; Landlock does not mediate stat"
else
  F1_2_VERDICT=INCONCLUSIVE; F1_2_DETAIL="stat returned inconsistent status/output; rc=$F1_2_R_RC"
fi

EVIDENCE_COMPLETE=yes
OPEN_VERSION="$(openshell --version 2>&1 | tail -n 1)" || EVIDENCE_COMPLETE=no
KERNEL="$(uname -r)"
POLICY_RESTRICTIVE="$(openshell policy get "$RESTRICTIVE_NAME" --full 2>&1)" || EVIDENCE_COMPLETE=no
POLICY_PERMISSIVE="$(openshell policy get "$PERMISSIVE_NAME" --full 2>&1)" || EVIDENCE_COMPLETE=no
LANDLOCK_LOGS="$(openshell logs "$RESTRICTIVE_NAME" --source sandbox -n 300 2>&1)" || EVIDENCE_COMPLETE=no
LANDLOCK_LINES="$(printf '%s\n' "$LANDLOCK_LOGS" | grep -i landlock | head -n 10 || true)"

{
  printf '# M4 filesystem results\n\n'
  printf -- '- Run: `%s`\n' "$STAMP"
  printf -- '- Evidence complete: `%s`\n' "$EVIDENCE_COMPLETE"
  printf -- '- OpenShell: `%s`\n' "$OPEN_VERSION"
  printf -- '- Kernel: `%s`\n' "$KERNEL"
  printf -- '- Restrictive sandbox: `%s`\n' "$RESTRICTIVE_NAME"
  printf -- '- Permissive sandbox: `%s`\n' "$PERMISSIVE_NAME"
  printf -- '- Raw evidence: `%s`\n\n' "$(basename "$RAWLOG")"
  printf '| Test | Verdict | Evidence summary |\n|---|---|---|\n'
  for id in F1_1 F1_2 F2_1 F2_2 F2_3 F2_4 F2_5 F2_6 F2_7 F2_8 F2_9 F2_10 F2_11 F2_12 F2_13 F2_14 F2_15 F2_16 F2_17 F3_1 F3_2 F3_3 F4_1 F4_2 F4_3 F4_4; do
    verdict_var="${id}_VERDICT"; detail_var="${id}_DETAIL"
    printf '| %s | %s | %s |\n' "$id" "${!verdict_var}" "${!detail_var}"
  done
  printf '\nA `FAIL` here means the measured test expectation failed; it is not, by itself, a confirmed vulnerability claim.\n\n'
  printf '## Detailed measurements\n\n'
  printf '| Test | Permissive control | Restrictive run |\n|---|---|---|\n'
  printf '| F1_1 | rc=%s, marker_seen=%s | rc=%s, marker_seen=%s |\n' \
    "$F1_1_C_RC" "$([[ "$F1_1_C_OUT" == *HIDDEN_MARKER_F1_1* ]] && echo yes || echo no)" \
    "$F1_1_R_RC" "$([[ "$F1_1_R_OUT" == *HIDDEN_MARKER_F1_1* ]] && echo yes || echo no)"
  printf '| F2_1 | rc=%s, before=%s, after=%s | rc=%s, before=%s, after=%s |\n' \
    "$F2_1_C_RC" "$F2_1_C_BEFORE" "$F2_1_C_AFTER" "$F2_1_R_RC" "$F2_1_R_BEFORE" "$F2_1_R_AFTER"
  printf '| F3_1 | rc=%s, final_size=%s | rc=%s, before=%s, after=%s, final_size=%s |\n' \
    "$F3_1_C_RC" "$F3_1_C_SIZE" "$F3_1_R_RC" "$F3_1_R_BEFORE" "$F3_1_R_AFTER" "$F3_1_R_SIZE"
  printf '| F4_1 | rc=%s, file_exists=%s | rc=%s, file_exists=%s |\n' \
    "$F4_1_C_RC" "$F4_1_C_EXISTS" "$F4_1_R_RC" "$F4_1_R_EXISTS"
  printf '| F3_2 | rc=%s, final_size=%s | rc=%s, final_size=%s |\n' "$F3_2_C_RC" "$F3_2_C_SIZE" "$F3_2_R_RC" "$F3_2_R_SIZE"
  printf '| F2_2 | rc=%s, final_size=%s | rc=%s, final_size=%s |\n' "$F2_2_C_RC" "$F2_2_C_SIZE" "$F2_2_R_RC" "$F2_2_R_SIZE"
  printf '| F2_3 | rc=%s, hash_changed=%s | rc=%s, hash_changed=%s |\n' "$F2_3_C_RC" "$([[ "$F2_3_C_BEFORE" != "$F2_3_C_AFTER" ]] && echo yes || echo no)" "$F2_3_R_RC" "$([[ "$F2_3_R_BEFORE" != "$F2_3_R_AFTER" ]] && echo yes || echo no)"
  printf '| F4_2 | rc=%s, old=%s, new=%s | rc=%s, old=%s, new=%s |\n' "$F4_2_C_RC" "$F4_2_C_OLD" "$F4_2_C_NEW" "$F4_2_R_RC" "$F4_2_R_OLD" "$F4_2_R_NEW"
  printf '| F2_4 | rc=%s, created=%s | rc=%s, created=%s |\n' "$F2_4_C_RC" "$F2_4_C_EXISTS" "$F2_4_R_RC" "$F2_4_R_EXISTS"
  printf '| F2_5 | rc=%s, before=%s, after=%s | rc=%s, before=%s, after=%s |\n' "$F2_5_C_RC" "$F2_5_C_BEFORE" "$F2_5_C_AFTER" "$F2_5_R_RC" "$F2_5_R_BEFORE" "$F2_5_R_AFTER"
  printf '| F2_6 | rc=%s, created=%s | rc=%s, created=%s |\n' "$F2_6_C_RC" "$F2_6_C_EXISTS" "$F2_6_R_RC" "$F2_6_R_EXISTS"
  printf '| F2_7 | rc=%s, created=%s | rc=%s, created=%s |\n' "$F2_7_C_RC" "$F2_7_C_EXISTS" "$F2_7_R_RC" "$F2_7_R_EXISTS"
  printf '| F2_8 | rc=%s, created=%s | rc=%s, created=%s |\n' "$F2_8_C_RC" "$F2_8_C_EXISTS" "$F2_8_R_RC" "$F2_8_R_EXISTS"
  printf '| F4_3 | rc=%s, remains=%s | rc=%s, remains=%s |\n' "$F4_3_C_RC" "$F4_3_C_EXISTS" "$F4_3_R_RC" "$F4_3_R_EXISTS"
  printf '| F2_9 | rc=%s, before=%s, after=%s | rc=%s, before=%s, after=%s |\n' "$F2_9_C_RC" "$F2_9_C_BEFORE" "$F2_9_C_AFTER" "$F2_9_R_RC" "$F2_9_R_BEFORE" "$F2_9_R_AFTER"
  printf '| F2_10 | rc=%s, value=%s | rc=%s, value=%s |\n' "$F2_10_C_RC" "$F2_10_C_VALUE" "$F2_10_R_RC" "$F2_10_R_VALUE"
  printf '| F4_4 | rc=%s, source=%s, destination=%s | rc=%s, source=%s, destination=%s |\n' "$F4_4_C_RC" "$F4_4_C_OLD" "$F4_4_C_NEW" "$F4_4_R_RC" "$F4_4_R_OLD" "$F4_4_R_NEW"
  printf '| F2_11 | rc=%s, hashes_equal=%s | rc=%s, hashes_equal=%s |\n' "$F2_11_C_RC" "$([[ "$F2_11_C_SOURCE" == "$F2_11_C_DEST" ]] && echo yes || echo no)" "$F2_11_R_RC" "$([[ "$F2_11_R_SOURCE" == "$F2_11_R_DEST" ]] && echo yes || echo no)"
  printf '| F2_12 | rc=%s, marker_seen=%s | rc=%s, marker_seen=%s |\n' "$F2_12_C_RC" "$([[ "$F2_12_C_OUT" == *HIDDEN_MARKER_F1_1* ]] && echo yes || echo no)" "$F2_12_R_RC" "$([[ "$F2_12_R_OUT" == *HIDDEN_MARKER_F1_1* ]] && echo yes || echo no)"
  printf '| F2_13 | rc=%s, hash_changed=%s | rc=%s, hash_changed=%s |\n' "$F2_13_C_RC" "$([[ "$F2_13_C_BEFORE" != "$F2_13_C_AFTER" ]] && echo yes || echo no)" "$F2_13_R_RC" "$([[ "$F2_13_R_BEFORE" != "$F2_13_R_AFTER" ]] && echo yes || echo no)"
  printf '| F2_14 | rc=%s, hash_changed=%s | rc=%s, hash_changed=%s |\n' "$F2_14_C_RC" "$([[ "$F2_14_C_BEFORE" != "$F2_14_C_AFTER" ]] && echo yes || echo no)" "$F2_14_R_RC" "$([[ "$F2_14_R_BEFORE" != "$F2_14_R_AFTER" ]] && echo yes || echo no)"
  printf '| F3_3 | rc=%s, final_size=%s | rc=%s, before=%s, after=%s, final_size=%s, hash_changed=%s |\n' "$F3_3_C_RC" "$F3_3_C_SIZE" "$F3_3_R_RC" "$F3_3_R_BEFORE" "$F3_3_R_AFTER" "$F3_3_R_SIZE" "$([[ "$F3_3_R_BEFORE" != "$F3_3_R_AFTER" ]] && echo yes || echo no)"
  printf '| F2_15 | rc=%s, created=%s | rc=%s, created=%s |\n' "$F2_15_C_RC" "$F2_15_C_EXISTS" "$F2_15_R_RC" "$F2_15_R_EXISTS"
  printf '| F2_16 | rc=%s, created=%s | rc=%s, created=%s |\n' "$F2_16_C_RC" "$F2_16_C_EXISTS" "$F2_16_R_RC" "$F2_16_R_EXISTS"
  printf '| F2_17 | rc=%s, marker_seen=%s | rc=%s, marker_seen=%s |\n' "$F2_17_C_RC" "$([[ "$F2_17_C_OUT" == *EXEC_MARKER_F2_17* ]] && echo yes || echo no)" "$F2_17_R_RC" "$([[ "$F2_17_R_OUT" == *EXEC_MARKER_F2_17* ]] && echo yes || echo no)"
  printf '| F1_2 | rc=%s, metadata_seen=%s | rc=%s, metadata_seen=%s |\n' "$F1_2_C_RC" "$([[ -n "$F1_2_C_OUT" ]] && echo yes || echo no)" "$F1_2_R_RC" "$([[ -n "$F1_2_R_OUT" ]] && echo yes || echo no)"
  printf '\n## Applied-policy snapshots\n\n'
  printf '### Restrictive\n\n```text\n%s\n```\n\n' "$POLICY_RESTRICTIVE"
  printf '### Permissive\n\n```text\n%s\n```\n\n' "$POLICY_PERMISSIVE"
  printf '## Landlock-related log lines\n\n```text\n%s\n```\n' "${LANDLOCK_LINES:-No Landlock lines found}"
} >"$REPORT"

printf '\nResults:\n'
for id in F1_1 F1_2 F2_1 F2_2 F2_3 F2_4 F2_5 F2_6 F2_7 F2_8 F2_9 F2_10 F2_11 F2_12 F2_13 F2_14 F2_15 F2_16 F2_17 F3_1 F3_2 F3_3 F4_1 F4_2 F4_3 F4_4; do
  verdict_var="${id}_VERDICT"; detail_var="${id}_DETAIL"
  printf '  %-3s %-12s %s\n' "$id" "${!verdict_var}" "${!detail_var}"
done
printf 'Report: %s\nRaw log: %s\n' "$REPORT" "$RAWLOG"

HAS_FAIL=0
HAS_INCONCLUSIVE=0
for id in F1_1 F1_2 F2_1 F2_2 F2_3 F2_4 F2_5 F2_6 F2_7 F2_8 F2_9 F2_10 F2_11 F2_12 F2_13 F2_14 F2_15 F2_16 F2_17 F3_1 F3_2 F3_3 F4_1 F4_2 F4_3 F4_4; do
  verdict_var="${id}_VERDICT"
  [[ "${!verdict_var}" == FAIL ]] && HAS_FAIL=1
  [[ "${!verdict_var}" == INCONCLUSIVE ]] && HAS_INCONCLUSIVE=1
done
[[ "$HAS_INCONCLUSIVE" -eq 0 ]] || exit 2
[[ "$EVIDENCE_COMPLETE" == yes ]] || exit 2
[[ "$HAS_FAIL" -eq 0 ]] || exit 1
exit 0
