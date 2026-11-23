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
    printf 'T09 fixture is already empty in %s. Recreate the sandboxes.\n' "$name" >&2
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
run_sbx "$PERMISSIVE_NAME" T07-control "cat /opt/claims-fixtures/hidden/read.txt"
T07_C_RC=$RUN_RC; T07_C_OUT=$RUN_OUTPUT

T08_C_BEFORE="$(hash_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/modify.txt)"
run_sbx "$PERMISSIVE_NAME" T08-control "echo TEST_CHANGE >> /opt/claims-fixtures/readonly/modify.txt"
T08_C_RC=$RUN_RC
T08_C_AFTER="$(hash_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/modify.txt)"

run_sbx "$PERMISSIVE_NAME" T09-control "python3 -c 'import os; os.truncate(\"/opt/claims-fixtures/readonly/truncate.txt\", 0)'"
T09_C_RC=$RUN_RC
T09_C_SIZE="$(size_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/truncate.txt)"

run_sbx "$PERMISSIVE_NAME" T10-control "rm -- /opt/claims-fixtures/readonly/delete.txt"
T10_C_RC=$RUN_RC
if exists "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/delete.txt; then T10_C_EXISTS=yes; else T10_C_EXISTS=no; fi

run_sbx "$PERMISSIVE_NAME" T11-control ": > /opt/claims-fixtures/readonly/shell-truncate.txt"
T11_C_RC=$RUN_RC; T11_C_SIZE="$(size_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/shell-truncate.txt)"

run_sbx "$PERMISSIVE_NAME" T12-control "python3 -c 'open(\"/opt/claims-fixtures/readonly/python-open.txt\", \"w\").close()'"
T12_C_RC=$RUN_RC; T12_C_SIZE="$(size_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/python-open.txt)"

T13_C_BEFORE="$(hash_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/overwrite.txt)"
run_sbx "$PERMISSIVE_NAME" T13-control "printf X | dd of=/opt/claims-fixtures/readonly/overwrite.txt conv=notrunc status=none"
T13_C_RC=$RUN_RC; T13_C_AFTER="$(hash_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/overwrite.txt)"

run_sbx "$PERMISSIVE_NAME" T14-control "mv /opt/claims-fixtures/readonly/rename.txt /opt/claims-fixtures/readonly/renamed-t14.txt"
T14_C_RC=$RUN_RC
if exists "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/rename.txt; then T14_C_OLD=yes; else T14_C_OLD=no; fi
if exists "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/renamed-t14.txt; then T14_C_NEW=yes; else T14_C_NEW=no; fi

run_sbx "$PERMISSIVE_NAME" T15-control "touch /opt/claims-fixtures/readonly/created-t15.txt"
T15_C_RC=$RUN_RC
if exists "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/created-t15.txt; then T15_C_EXISTS=yes; else T15_C_EXISTS=no; fi

T16_C_BEFORE="$(mode_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/chmod.txt)"
run_sbx "$PERMISSIVE_NAME" T16-control "chmod 0600 /opt/claims-fixtures/readonly/chmod.txt"
T16_C_RC=$RUN_RC; T16_C_AFTER="$(mode_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/chmod.txt)"

run_sbx "$PERMISSIVE_NAME" T21-control "ln /opt/claims-fixtures/readonly/hardlink.txt /opt/claims-fixtures/readonly/hardlink-created-t21"
T21_C_RC=$RUN_RC; if exists "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/hardlink-created-t21; then T21_C_EXISTS=yes; else T21_C_EXISTS=no; fi

run_sbx "$PERMISSIVE_NAME" T22-control "ln -s symlink-source.txt /opt/claims-fixtures/readonly/symlink-created-t22"
T22_C_RC=$RUN_RC; if exists "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/symlink-created-t22; then T22_C_EXISTS=yes; else T22_C_EXISTS=no; fi

run_sbx "$PERMISSIVE_NAME" T23-control "mkdir /opt/claims-fixtures/readonly/created-dir-t23"
T23_C_RC=$RUN_RC; if exists "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/created-dir-t23; then T23_C_EXISTS=yes; else T23_C_EXISTS=no; fi

run_sbx "$PERMISSIVE_NAME" T24-control "rmdir /opt/claims-fixtures/readonly/empty-dir-t24"
T24_C_RC=$RUN_RC; if exists "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/empty-dir-t24; then T24_C_EXISTS=yes; else T24_C_EXISTS=no; fi

T25_C_BEFORE="$(mtime_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/utime.txt)"
run_sbx "$PERMISSIVE_NAME" T25-control "touch -d @1000000000 /opt/claims-fixtures/readonly/utime.txt"
T25_C_RC=$RUN_RC; T25_C_AFTER="$(mtime_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/utime.txt)"

run_sbx "$PERMISSIVE_NAME" T26-control "setfattr -n user.audit -v control /opt/claims-fixtures/readonly/xattr.txt"
T26_C_RC=$RUN_RC; T26_C_VALUE="$(xattr_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/xattr.txt)"

run_sbx "$PERMISSIVE_NAME" T27-control "mv /opt/claims-fixtures/readonly/cross-rename.txt /work/cross-renamed-t27.txt"
T27_C_RC=$RUN_RC
if exists "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/cross-rename.txt; then T27_C_OLD=yes; else T27_C_OLD=no; fi
if exists "$PERMISSIVE_NAME" /work/cross-renamed-t27.txt; then T27_C_NEW=yes; else T27_C_NEW=no; fi

T28_C_SOURCE="$(hash_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/copy-out.txt)"
run_sbx "$PERMISSIVE_NAME" T28-control "cp /opt/claims-fixtures/readonly/copy-out.txt /work/copied-t28.txt"
T28_C_RC=$RUN_RC; T28_C_DEST="$(hash_of "$PERMISSIVE_NAME" /work/copied-t28.txt)"

run_sbx "$PERMISSIVE_NAME" T29-control "cat /opt/claims-fixtures/readonly/hidden-link-t29"
T29_C_RC=$RUN_RC; T29_C_OUT=$RUN_OUTPUT

T30_C_BEFORE="$(hash_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/symlink-write.txt)"
run_sbx "$PERMISSIVE_NAME" T30-control "ln -s /opt/claims-fixtures/readonly/symlink-write.txt /work/t30-link && echo VIA_SYMLINK >> /work/t30-link"
T30_C_RC=$RUN_RC; T30_C_AFTER="$(hash_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/symlink-write.txt)"

T31_C_BEFORE="$(hash_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/mmap.txt)"
run_sbx "$PERMISSIVE_NAME" T31-control "python3 -c 'import mmap; p=\"/opt/claims-fixtures/readonly/mmap.txt\"; f=open(p,\"r+b\"); m=mmap.mmap(f.fileno(),0); m[0:1]=b\"X\"; m.flush(); m.close(); f.close()'"
T31_C_RC=$RUN_RC; T31_C_AFTER="$(hash_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/mmap.txt)"

run_sbx "$PERMISSIVE_NAME" T32-control "python3 -c 'import os; fd=os.open(\"/opt/claims-fixtures/readonly/rdonly-truncate.txt\", os.O_RDONLY|os.O_TRUNC); os.close(fd)'"
T32_C_RC=$RUN_RC; T32_C_SIZE="$(size_of "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/rdonly-truncate.txt)"

run_sbx "$PERMISSIVE_NAME" T33-control "python3 -c 'import socket; s=socket.socket(socket.AF_UNIX); s.bind(\"/opt/claims-fixtures/readonly/socket-t33\"); s.close()'"
T33_C_RC=$RUN_RC; if exists "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/socket-t33; then T33_C_EXISTS=yes; else T33_C_EXISTS=no; fi

run_sbx "$PERMISSIVE_NAME" T34-control "mkfifo /opt/claims-fixtures/readonly/fifo-t34"
T34_C_RC=$RUN_RC; if exists "$PERMISSIVE_NAME" /opt/claims-fixtures/readonly/fifo-t34; then T34_C_EXISTS=yes; else T34_C_EXISTS=no; fi

run_sbx "$PERMISSIVE_NAME" T35-control "/opt/claims-fixtures/readonly/execute-t35.sh"
T35_C_RC=$RUN_RC; T35_C_OUT=$RUN_OUTPUT

run_sbx "$PERMISSIVE_NAME" T36-control "stat -c '%n:%s:%a' /opt/claims-fixtures/hidden/read.txt"
T36_C_RC=$RUN_RC; T36_C_OUT=$RUN_OUTPUT

printf 'Running restrictive tests...\n'
run_sbx "$RESTRICTIVE_NAME" T07-restrictive "cat /opt/claims-fixtures/hidden/read.txt"
T07_R_RC=$RUN_RC; T07_R_OUT=$RUN_OUTPUT

T08_R_BEFORE="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/modify.txt)"
run_sbx "$RESTRICTIVE_NAME" T08-restrictive "echo TEST_CHANGE >> /opt/claims-fixtures/readonly/modify.txt"
T08_R_RC=$RUN_RC
T08_R_AFTER="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/modify.txt)"

T09_R_BEFORE="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/truncate.txt)"
run_sbx "$RESTRICTIVE_NAME" T09-restrictive "python3 -c 'import os; os.truncate(\"/opt/claims-fixtures/readonly/truncate.txt\", 0)'"
T09_R_RC=$RUN_RC
T09_R_AFTER="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/truncate.txt)"
T09_R_SIZE="$(size_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/truncate.txt)"

run_sbx "$RESTRICTIVE_NAME" T10-restrictive "rm -- /opt/claims-fixtures/readonly/delete.txt"
T10_R_RC=$RUN_RC
if exists "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/delete.txt; then T10_R_EXISTS=yes; else T10_R_EXISTS=no; fi

T11_R_BEFORE="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/shell-truncate.txt)"
run_sbx "$RESTRICTIVE_NAME" T11-restrictive ": > /opt/claims-fixtures/readonly/shell-truncate.txt"
T11_R_RC=$RUN_RC; T11_R_AFTER="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/shell-truncate.txt)"; T11_R_SIZE="$(size_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/shell-truncate.txt)"

T12_R_BEFORE="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/python-open.txt)"
run_sbx "$RESTRICTIVE_NAME" T12-restrictive "python3 -c 'open(\"/opt/claims-fixtures/readonly/python-open.txt\", \"w\").close()'"
T12_R_RC=$RUN_RC; T12_R_AFTER="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/python-open.txt)"; T12_R_SIZE="$(size_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/python-open.txt)"

T13_R_BEFORE="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/overwrite.txt)"
run_sbx "$RESTRICTIVE_NAME" T13-restrictive "printf X | dd of=/opt/claims-fixtures/readonly/overwrite.txt conv=notrunc status=none"
T13_R_RC=$RUN_RC; T13_R_AFTER="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/overwrite.txt)"

run_sbx "$RESTRICTIVE_NAME" T14-restrictive "mv /opt/claims-fixtures/readonly/rename.txt /opt/claims-fixtures/readonly/renamed-t14.txt"
T14_R_RC=$RUN_RC
if exists "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/rename.txt; then T14_R_OLD=yes; else T14_R_OLD=no; fi
if exists "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/renamed-t14.txt; then T14_R_NEW=yes; else T14_R_NEW=no; fi

run_sbx "$RESTRICTIVE_NAME" T15-restrictive "touch /opt/claims-fixtures/readonly/created-t15.txt"
T15_R_RC=$RUN_RC
if exists "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/created-t15.txt; then T15_R_EXISTS=yes; else T15_R_EXISTS=no; fi

T16_R_BEFORE="$(mode_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/chmod.txt)"
run_sbx "$RESTRICTIVE_NAME" T16-restrictive "chmod 0600 /opt/claims-fixtures/readonly/chmod.txt"
T16_R_RC=$RUN_RC; T16_R_AFTER="$(mode_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/chmod.txt)"

run_sbx "$RESTRICTIVE_NAME" T21-restrictive "ln /opt/claims-fixtures/readonly/hardlink.txt /opt/claims-fixtures/readonly/hardlink-created-t21"
T21_R_RC=$RUN_RC; if exists "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/hardlink-created-t21; then T21_R_EXISTS=yes; else T21_R_EXISTS=no; fi

run_sbx "$RESTRICTIVE_NAME" T22-restrictive "ln -s symlink-source.txt /opt/claims-fixtures/readonly/symlink-created-t22"
T22_R_RC=$RUN_RC; if exists "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/symlink-created-t22; then T22_R_EXISTS=yes; else T22_R_EXISTS=no; fi

run_sbx "$RESTRICTIVE_NAME" T23-restrictive "mkdir /opt/claims-fixtures/readonly/created-dir-t23"
T23_R_RC=$RUN_RC; if exists "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/created-dir-t23; then T23_R_EXISTS=yes; else T23_R_EXISTS=no; fi

run_sbx "$RESTRICTIVE_NAME" T24-restrictive "rmdir /opt/claims-fixtures/readonly/empty-dir-t24"
T24_R_RC=$RUN_RC; if exists "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/empty-dir-t24; then T24_R_EXISTS=yes; else T24_R_EXISTS=no; fi

T25_R_BEFORE="$(mtime_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/utime.txt)"
run_sbx "$RESTRICTIVE_NAME" T25-restrictive "touch -d @1000000000 /opt/claims-fixtures/readonly/utime.txt"
T25_R_RC=$RUN_RC; T25_R_AFTER="$(mtime_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/utime.txt)"

run_sbx "$RESTRICTIVE_NAME" T26-restrictive "setfattr -n user.audit -v restrictive /opt/claims-fixtures/readonly/xattr.txt"
T26_R_RC=$RUN_RC; T26_R_VALUE="$(xattr_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/xattr.txt)"

run_sbx "$RESTRICTIVE_NAME" T27-restrictive "mv /opt/claims-fixtures/readonly/cross-rename.txt /work/cross-renamed-t27.txt"
T27_R_RC=$RUN_RC
if exists "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/cross-rename.txt; then T27_R_OLD=yes; else T27_R_OLD=no; fi
if exists "$RESTRICTIVE_NAME" /work/cross-renamed-t27.txt; then T27_R_NEW=yes; else T27_R_NEW=no; fi

T28_R_SOURCE="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/copy-out.txt)"
run_sbx "$RESTRICTIVE_NAME" T28-restrictive "cp /opt/claims-fixtures/readonly/copy-out.txt /work/copied-t28.txt"
T28_R_RC=$RUN_RC; T28_R_DEST="$(hash_of "$RESTRICTIVE_NAME" /work/copied-t28.txt)"

run_sbx "$RESTRICTIVE_NAME" T29-restrictive "cat /opt/claims-fixtures/readonly/hidden-link-t29"
T29_R_RC=$RUN_RC; T29_R_OUT=$RUN_OUTPUT

T30_R_BEFORE="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/symlink-write.txt)"
run_sbx "$RESTRICTIVE_NAME" T30-restrictive "ln -s /opt/claims-fixtures/readonly/symlink-write.txt /work/t30-link && echo VIA_SYMLINK >> /work/t30-link"
T30_R_RC=$RUN_RC; T30_R_AFTER="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/symlink-write.txt)"

T31_R_BEFORE="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/mmap.txt)"
run_sbx "$RESTRICTIVE_NAME" T31-restrictive "python3 -c 'import mmap; p=\"/opt/claims-fixtures/readonly/mmap.txt\"; f=open(p,\"r+b\"); m=mmap.mmap(f.fileno(),0); m[0:1]=b\"X\"; m.flush(); m.close(); f.close()'"
T31_R_RC=$RUN_RC; T31_R_AFTER="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/mmap.txt)"

T32_R_BEFORE="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/rdonly-truncate.txt)"
run_sbx "$RESTRICTIVE_NAME" T32-restrictive "python3 -c 'import os; fd=os.open(\"/opt/claims-fixtures/readonly/rdonly-truncate.txt\", os.O_RDONLY|os.O_TRUNC); os.close(fd)'"
T32_R_RC=$RUN_RC; T32_R_AFTER="$(hash_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/rdonly-truncate.txt)"; T32_R_SIZE="$(size_of "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/rdonly-truncate.txt)"

run_sbx "$RESTRICTIVE_NAME" T33-restrictive "python3 -c 'import socket; s=socket.socket(socket.AF_UNIX); s.bind(\"/opt/claims-fixtures/readonly/socket-t33\"); s.close()'"
T33_R_RC=$RUN_RC; if exists "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/socket-t33; then T33_R_EXISTS=yes; else T33_R_EXISTS=no; fi

run_sbx "$RESTRICTIVE_NAME" T34-restrictive "mkfifo /opt/claims-fixtures/readonly/fifo-t34"
T34_R_RC=$RUN_RC; if exists "$RESTRICTIVE_NAME" /opt/claims-fixtures/readonly/fifo-t34; then T34_R_EXISTS=yes; else T34_R_EXISTS=no; fi

run_sbx "$RESTRICTIVE_NAME" T35-restrictive "/opt/claims-fixtures/readonly/execute-t35.sh"
T35_R_RC=$RUN_RC; T35_R_OUT=$RUN_OUTPUT

run_sbx "$RESTRICTIVE_NAME" T36-restrictive "stat -c '%n:%s:%a' /opt/claims-fixtures/hidden/read.txt"
T36_R_RC=$RUN_RC; T36_R_OUT=$RUN_OUTPUT

if [[ -f "$OBS_ERROR_FILE" ]] || ! sandbox_is_healthy "$PERMISSIVE_NAME" || ! sandbox_is_healthy "$RESTRICTIVE_NAME"; then
  printf 'Infrastructure or observation failure detected. No enforcement verdicts will be inferred from generic command errors.\n' >&2
  exit 2
fi

if [[ $T07_C_RC -ne 0 || "$T07_C_OUT" != *HIDDEN_MARKER_T07* ]]; then
  T07_VERDICT=INCONCLUSIVE; T07_DETAIL="Permissive read control failed"
elif [[ $T07_R_RC -ne 0 && "$T07_R_OUT" != *HIDDEN_MARKER_T07* ]]; then
  T07_VERDICT=PASS; T07_DETAIL="Control revealed marker; restrictive read did not"
else
  T07_VERDICT=FAIL; T07_DETAIL="Restrictive read revealed the hidden marker"
fi

if [[ $T08_C_RC -ne 0 || "$T08_C_BEFORE" == "$T08_C_AFTER" ]]; then
  T08_VERDICT=INCONCLUSIVE; T08_DETAIL="Permissive append control did not change content"
elif [[ $T08_R_RC -ne 0 && "$T08_R_BEFORE" == "$T08_R_AFTER" ]]; then
  T08_VERDICT=PASS; T08_DETAIL="Restrictive append denied; hash unchanged"
else
  T08_VERDICT=FAIL; T08_DETAIL="Restrictive append rc=$T08_R_RC; before=$T08_R_BEFORE after=$T08_R_AFTER"
fi

if [[ $T09_C_RC -ne 0 || "$T09_C_SIZE" != "0" ]]; then
  T09_VERDICT=INCONCLUSIVE; T09_DETAIL="Permissive truncate control failed"
elif [[ $T09_R_RC -ne 0 && "$T09_R_BEFORE" == "$T09_R_AFTER" && "$T09_R_SIZE" != "0" ]]; then
  T09_VERDICT=PASS; T09_DETAIL="Restrictive truncate denied; size/hash unchanged"
else
  T09_VERDICT=FAIL; T09_DETAIL="Restrictive truncate rc=$T09_R_RC; size=$T09_R_SIZE; hash changed=$([[ "$T09_R_BEFORE" != "$T09_R_AFTER" ]] && echo yes || echo no)"
fi

if [[ $T10_C_RC -ne 0 || "$T10_C_EXISTS" != "no" ]]; then
  T10_VERDICT=INCONCLUSIVE; T10_DETAIL="Permissive delete control failed"
elif [[ $T10_R_RC -ne 0 && "$T10_R_EXISTS" == "yes" ]]; then
  T10_VERDICT=PASS; T10_DETAIL="Restrictive delete denied; file remains"
else
  T10_VERDICT=FAIL; T10_DETAIL="Restrictive delete rc=$T10_R_RC; file_exists=$T10_R_EXISTS"
fi

if [[ $T11_C_RC -ne 0 || "$T11_C_SIZE" != 0 ]]; then
  T11_VERDICT=INCONCLUSIVE; T11_DETAIL="Permissive shell-truncate control failed"
elif [[ $T11_R_RC -ne 0 && "$T11_R_BEFORE" == "$T11_R_AFTER" && "$T11_R_SIZE" != 0 ]]; then
  T11_VERDICT=PASS; T11_DETAIL="Shell redirection truncate denied; content unchanged"
else
  T11_VERDICT=FAIL; T11_DETAIL="Shell truncate rc=$T11_R_RC; size=$T11_R_SIZE; hash changed=$([[ "$T11_R_BEFORE" != "$T11_R_AFTER" ]] && echo yes || echo no)"
fi

if [[ $T12_C_RC -ne 0 || "$T12_C_SIZE" != 0 ]]; then
  T12_VERDICT=INCONCLUSIVE; T12_DETAIL="Permissive Python open(w) control failed"
elif [[ $T12_R_RC -ne 0 && "$T12_R_BEFORE" == "$T12_R_AFTER" && "$T12_R_SIZE" != 0 ]]; then
  T12_VERDICT=PASS; T12_DETAIL="Python open(w) denied; content unchanged"
else
  T12_VERDICT=FAIL; T12_DETAIL="Python open(w) rc=$T12_R_RC; size=$T12_R_SIZE; hash changed=$([[ "$T12_R_BEFORE" != "$T12_R_AFTER" ]] && echo yes || echo no)"
fi

if [[ $T13_C_RC -ne 0 || "$T13_C_BEFORE" == "$T13_C_AFTER" ]]; then
  T13_VERDICT=INCONCLUSIVE; T13_DETAIL="Permissive in-place overwrite control failed"
elif [[ $T13_R_RC -ne 0 && "$T13_R_BEFORE" == "$T13_R_AFTER" ]]; then
  T13_VERDICT=PASS; T13_DETAIL="In-place overwrite denied; hash unchanged"
else
  T13_VERDICT=FAIL; T13_DETAIL="In-place overwrite rc=$T13_R_RC; hash changed=$([[ "$T13_R_BEFORE" != "$T13_R_AFTER" ]] && echo yes || echo no)"
fi

if [[ $T14_C_RC -ne 0 || "$T14_C_OLD" != no || "$T14_C_NEW" != yes ]]; then
  T14_VERDICT=INCONCLUSIVE; T14_DETAIL="Permissive rename control failed"
elif [[ $T14_R_RC -ne 0 && "$T14_R_OLD" == yes && "$T14_R_NEW" == no ]]; then
  T14_VERDICT=PASS; T14_DETAIL="Rename denied; original remains and destination absent"
else
  T14_VERDICT=FAIL; T14_DETAIL="Rename rc=$T14_R_RC; old=$T14_R_OLD new=$T14_R_NEW"
fi

if [[ $T15_C_RC -ne 0 || "$T15_C_EXISTS" != yes ]]; then
  T15_VERDICT=INCONCLUSIVE; T15_DETAIL="Permissive file-creation control failed"
elif [[ $T15_R_RC -ne 0 && "$T15_R_EXISTS" == no ]]; then
  T15_VERDICT=PASS; T15_DETAIL="New file creation denied"
else
  T15_VERDICT=FAIL; T15_DETAIL="Creation rc=$T15_R_RC; file_exists=$T15_R_EXISTS"
fi

if [[ $T16_C_RC -ne 0 || "$T16_C_AFTER" != 600 || -z "$T16_R_BEFORE" || -z "$T16_R_AFTER" ]]; then
  T16_VERDICT=INCONCLUSIVE; T16_DETAIL="Permissive chmod control failed"
elif [[ "$T16_R_BEFORE" == "$T16_R_AFTER" ]]; then
  T16_VERDICT=PASS; T16_DETAIL="chmod did not change mode; rc=$T16_R_RC"
elif [[ "$T16_R_AFTER" == 600 ]]; then
  T16_VERDICT=KNOWN-LIMITATION; T16_DETAIL="chmod changed metadata as Landlock does not mediate chmod; rc=$T16_R_RC before=$T16_R_BEFORE after=$T16_R_AFTER"
else
  T16_VERDICT=FAIL; T16_DETAIL="chmod produced an unexpected mode; rc=$T16_R_RC before=$T16_R_BEFORE after=$T16_R_AFTER"
fi

if [[ $T21_C_RC -ne 0 || "$T21_C_EXISTS" != yes ]]; then
  T21_VERDICT=INCONCLUSIVE; T21_DETAIL="Permissive hard-link control failed"
elif [[ $T21_R_RC -ne 0 && "$T21_R_EXISTS" == no ]]; then
  T21_VERDICT=PASS; T21_DETAIL="Hard-link creation in read_only directory denied"
else
  T21_VERDICT=FAIL; T21_DETAIL="Hard-link rc=$T21_R_RC; created=$T21_R_EXISTS"
fi

if [[ $T22_C_RC -ne 0 || "$T22_C_EXISTS" != yes ]]; then
  T22_VERDICT=INCONCLUSIVE; T22_DETAIL="Permissive symlink-creation control failed"
elif [[ $T22_R_RC -ne 0 && "$T22_R_EXISTS" == no ]]; then
  T22_VERDICT=PASS; T22_DETAIL="Symlink creation in read_only directory denied"
else
  T22_VERDICT=FAIL; T22_DETAIL="Symlink creation rc=$T22_R_RC; created=$T22_R_EXISTS"
fi

if [[ $T23_C_RC -ne 0 || "$T23_C_EXISTS" != yes ]]; then
  T23_VERDICT=INCONCLUSIVE; T23_DETAIL="Permissive mkdir control failed"
elif [[ $T23_R_RC -ne 0 && "$T23_R_EXISTS" == no ]]; then
  T23_VERDICT=PASS; T23_DETAIL="Directory creation under read_only denied"
else
  T23_VERDICT=FAIL; T23_DETAIL="mkdir rc=$T23_R_RC; created=$T23_R_EXISTS"
fi

if [[ $T24_C_RC -ne 0 || "$T24_C_EXISTS" != no ]]; then
  T24_VERDICT=INCONCLUSIVE; T24_DETAIL="Permissive rmdir control failed"
elif [[ $T24_R_RC -ne 0 && "$T24_R_EXISTS" == yes ]]; then
  T24_VERDICT=PASS; T24_DETAIL="Removal of directory under read_only denied"
else
  T24_VERDICT=FAIL; T24_DETAIL="rmdir rc=$T24_R_RC; directory_exists=$T24_R_EXISTS"
fi

if [[ $T25_C_RC -ne 0 || "$T25_C_BEFORE" == "$T25_C_AFTER" || -z "$T25_R_BEFORE" || -z "$T25_R_AFTER" ]]; then
  T25_VERDICT=INCONCLUSIVE; T25_DETAIL="Permissive timestamp control failed"
elif [[ "$T25_R_BEFORE" == "$T25_R_AFTER" ]]; then
  T25_VERDICT=PASS; T25_DETAIL="Timestamp did not change; rc=$T25_R_RC"
elif [[ "$T25_R_AFTER" == 1000000000 ]]; then
  T25_VERDICT=KNOWN-LIMITATION; T25_DETAIL="utime metadata changed; Landlock does not mediate utime; rc=$T25_R_RC before=$T25_R_BEFORE after=$T25_R_AFTER"
else
  T25_VERDICT=FAIL; T25_DETAIL="utime produced an unexpected timestamp; rc=$T25_R_RC before=$T25_R_BEFORE after=$T25_R_AFTER"
fi

if [[ $T26_C_RC -ne 0 || "$T26_C_VALUE" != control ]]; then
  T26_VERDICT=INCONCLUSIVE; T26_DETAIL="Permissive xattr control failed"
elif [[ -z "$T26_R_VALUE" ]]; then
  T26_VERDICT=PASS; T26_DETAIL="Extended attribute did not change; rc=$T26_R_RC"
elif [[ "$T26_R_VALUE" == restrictive ]]; then
  T26_VERDICT=KNOWN-LIMITATION; T26_DETAIL="user xattr changed; Landlock does not mediate setxattr; rc=$T26_R_RC value=$T26_R_VALUE"
else
  T26_VERDICT=FAIL; T26_DETAIL="setxattr produced an unexpected value; rc=$T26_R_RC value=$T26_R_VALUE"
fi

if [[ $T27_C_RC -ne 0 || "$T27_C_OLD" != no || "$T27_C_NEW" != yes ]]; then
  T27_VERDICT=INCONCLUSIVE; T27_DETAIL="Permissive cross-directory rename control failed"
elif [[ $T27_R_RC -ne 0 && "$T27_R_OLD" == yes && "$T27_R_NEW" == no ]]; then
  T27_VERDICT=PASS; T27_DETAIL="Rename from read_only into writable directory denied"
else
  T27_VERDICT=FAIL; T27_DETAIL="Cross-rename rc=$T27_R_RC; source=$T27_R_OLD destination=$T27_R_NEW"
fi

if [[ $T28_C_RC -ne 0 || -z "$T28_C_SOURCE" || "$T28_C_SOURCE" != "$T28_C_DEST" ]]; then
  T28_VERDICT=INCONCLUSIVE; T28_DETAIL="Permissive copy-out control failed"
elif [[ $T28_R_RC -eq 0 && -n "$T28_R_SOURCE" && "$T28_R_SOURCE" == "$T28_R_DEST" ]]; then
  T28_VERDICT=PASS; T28_DETAIL="Positive control: read_only content copied into writable /work"
else
  T28_VERDICT=FAIL; T28_DETAIL="Allowed copy-out was blocked or corrupted; rc=$T28_R_RC"
fi

if [[ $T29_C_RC -ne 0 || "$T29_C_OUT" != *HIDDEN_MARKER_T07* ]]; then
  T29_VERDICT=INCONCLUSIVE; T29_DETAIL="Permissive symlink-read control failed"
elif [[ $T29_R_RC -ne 0 && "$T29_R_OUT" != *HIDDEN_MARKER_T07* ]]; then
  T29_VERDICT=PASS; T29_DETAIL="Symlink did not bypass target-path read restriction"
else
  T29_VERDICT=FAIL; T29_DETAIL="Symlink exposed content from an ungranted target"
fi

if [[ $T30_C_RC -ne 0 || "$T30_C_BEFORE" == "$T30_C_AFTER" ]]; then
  T30_VERDICT=INCONCLUSIVE; T30_DETAIL="Permissive write-through-symlink control failed"
elif [[ $T30_R_RC -ne 0 && "$T30_R_BEFORE" == "$T30_R_AFTER" ]]; then
  T30_VERDICT=PASS; T30_DETAIL="Writable-directory symlink did not bypass read_only target"
else
  T30_VERDICT=FAIL; T30_DETAIL="Symlink write rc=$T30_R_RC; content_changed=$([[ "$T30_R_BEFORE" != "$T30_R_AFTER" ]] && echo yes || echo no)"
fi

if [[ $T31_C_RC -ne 0 || "$T31_C_BEFORE" == "$T31_C_AFTER" ]]; then
  T31_VERDICT=INCONCLUSIVE; T31_DETAIL="Permissive mmap control failed"
elif [[ $T31_R_RC -ne 0 && "$T31_R_BEFORE" == "$T31_R_AFTER" ]]; then
  T31_VERDICT=PASS; T31_DETAIL="Writable mmap attempt denied; content unchanged"
else
  T31_VERDICT=FAIL; T31_DETAIL="mmap rc=$T31_R_RC; content_changed=$([[ "$T31_R_BEFORE" != "$T31_R_AFTER" ]] && echo yes || echo no)"
fi

if [[ $T32_C_RC -ne 0 || "$T32_C_SIZE" != 0 ]]; then
  T32_VERDICT=INCONCLUSIVE; T32_DETAIL="Permissive O_RDONLY|O_TRUNC control failed"
elif [[ $T32_R_RC -ne 0 && "$T32_R_BEFORE" == "$T32_R_AFTER" && "$T32_R_SIZE" != 0 ]]; then
  T32_VERDICT=PASS; T32_DETAIL="O_RDONLY|O_TRUNC denied; content unchanged"
else
  T32_VERDICT=FAIL; T32_DETAIL="O_RDONLY|O_TRUNC changed content under the applied read_only policy; rc=$T32_R_RC size=$T32_R_SIZE"
fi

if [[ $T33_C_RC -ne 0 || "$T33_C_EXISTS" != yes ]]; then
  T33_VERDICT=INCONCLUSIVE; T33_DETAIL="Permissive UNIX-socket control failed"
elif [[ $T33_R_RC -ne 0 && "$T33_R_EXISTS" == no ]]; then
  T33_VERDICT=PASS; T33_DETAIL="UNIX socket creation under read_only denied"
else
  T33_VERDICT=FAIL; T33_DETAIL="UNIX socket bind rc=$T33_R_RC; created=$T33_R_EXISTS"
fi

if [[ $T34_C_RC -ne 0 || "$T34_C_EXISTS" != yes ]]; then
  T34_VERDICT=INCONCLUSIVE; T34_DETAIL="Permissive FIFO control failed"
elif [[ $T34_R_RC -ne 0 && "$T34_R_EXISTS" == no ]]; then
  T34_VERDICT=PASS; T34_DETAIL="FIFO creation under read_only denied"
else
  T34_VERDICT=FAIL; T34_DETAIL="mkfifo rc=$T34_R_RC; created=$T34_R_EXISTS"
fi

if [[ $T35_C_RC -ne 0 || "$T35_C_OUT" != *EXEC_MARKER_T35* ]]; then
  T35_VERDICT=INCONCLUSIVE; T35_DETAIL="Permissive execution control failed"
elif [[ $T35_R_RC -eq 0 && "$T35_R_OUT" == *EXEC_MARKER_T35* ]]; then
  T35_VERDICT=EXPECTED; T35_DETAIL="Execution from read_only is intentionally allowed; file content remained protected"
else
  T35_VERDICT=FAIL; T35_DETAIL="Execution from read_only was unexpectedly blocked; rc=$T35_R_RC"
fi

if [[ $T36_C_RC -ne 0 || -z "$T36_C_OUT" ]]; then
  T36_VERDICT=INCONCLUSIVE; T36_DETAIL="Permissive stat control failed"
elif [[ $T36_R_RC -ne 0 && -z "$T36_R_OUT" ]]; then
  T36_VERDICT=PASS; T36_DETAIL="Metadata lookup on ungranted path denied"
elif [[ $T36_R_RC -eq 0 && -n "$T36_R_OUT" ]]; then
  T36_VERDICT=KNOWN-LIMITATION; T36_DETAIL="stat exposed path metadata; Landlock does not mediate stat"
else
  T36_VERDICT=INCONCLUSIVE; T36_DETAIL="stat returned inconsistent status/output; rc=$T36_R_RC"
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
  for id in T07 T08 T09 T10 T11 T12 T13 T14 T15 T16 T21 T22 T23 T24 T25 T26 T27 T28 T29 T30 T31 T32 T33 T34 T35 T36; do
    verdict_var="${id}_VERDICT"; detail_var="${id}_DETAIL"
    printf '| %s | %s | %s |\n' "$id" "${!verdict_var}" "${!detail_var}"
  done
  printf '\nA `FAIL` here means the measured test expectation failed; it is not, by itself, a confirmed vulnerability claim.\n\n'
  printf '## Detailed measurements\n\n'
  printf '| Test | Permissive control | Restrictive run |\n|---|---|---|\n'
  printf '| T07 | rc=%s, marker_seen=%s | rc=%s, marker_seen=%s |\n' \
    "$T07_C_RC" "$([[ "$T07_C_OUT" == *HIDDEN_MARKER_T07* ]] && echo yes || echo no)" \
    "$T07_R_RC" "$([[ "$T07_R_OUT" == *HIDDEN_MARKER_T07* ]] && echo yes || echo no)"
  printf '| T08 | rc=%s, before=%s, after=%s | rc=%s, before=%s, after=%s |\n' \
    "$T08_C_RC" "$T08_C_BEFORE" "$T08_C_AFTER" "$T08_R_RC" "$T08_R_BEFORE" "$T08_R_AFTER"
  printf '| T09 | rc=%s, final_size=%s | rc=%s, before=%s, after=%s, final_size=%s |\n' \
    "$T09_C_RC" "$T09_C_SIZE" "$T09_R_RC" "$T09_R_BEFORE" "$T09_R_AFTER" "$T09_R_SIZE"
  printf '| T10 | rc=%s, file_exists=%s | rc=%s, file_exists=%s |\n' \
    "$T10_C_RC" "$T10_C_EXISTS" "$T10_R_RC" "$T10_R_EXISTS"
  printf '| T11 | rc=%s, final_size=%s | rc=%s, final_size=%s |\n' "$T11_C_RC" "$T11_C_SIZE" "$T11_R_RC" "$T11_R_SIZE"
  printf '| T12 | rc=%s, final_size=%s | rc=%s, final_size=%s |\n' "$T12_C_RC" "$T12_C_SIZE" "$T12_R_RC" "$T12_R_SIZE"
  printf '| T13 | rc=%s, hash_changed=%s | rc=%s, hash_changed=%s |\n' "$T13_C_RC" "$([[ "$T13_C_BEFORE" != "$T13_C_AFTER" ]] && echo yes || echo no)" "$T13_R_RC" "$([[ "$T13_R_BEFORE" != "$T13_R_AFTER" ]] && echo yes || echo no)"
  printf '| T14 | rc=%s, old=%s, new=%s | rc=%s, old=%s, new=%s |\n' "$T14_C_RC" "$T14_C_OLD" "$T14_C_NEW" "$T14_R_RC" "$T14_R_OLD" "$T14_R_NEW"
  printf '| T15 | rc=%s, created=%s | rc=%s, created=%s |\n' "$T15_C_RC" "$T15_C_EXISTS" "$T15_R_RC" "$T15_R_EXISTS"
  printf '| T16 | rc=%s, before=%s, after=%s | rc=%s, before=%s, after=%s |\n' "$T16_C_RC" "$T16_C_BEFORE" "$T16_C_AFTER" "$T16_R_RC" "$T16_R_BEFORE" "$T16_R_AFTER"
  printf '| T21 | rc=%s, created=%s | rc=%s, created=%s |\n' "$T21_C_RC" "$T21_C_EXISTS" "$T21_R_RC" "$T21_R_EXISTS"
  printf '| T22 | rc=%s, created=%s | rc=%s, created=%s |\n' "$T22_C_RC" "$T22_C_EXISTS" "$T22_R_RC" "$T22_R_EXISTS"
  printf '| T23 | rc=%s, created=%s | rc=%s, created=%s |\n' "$T23_C_RC" "$T23_C_EXISTS" "$T23_R_RC" "$T23_R_EXISTS"
  printf '| T24 | rc=%s, remains=%s | rc=%s, remains=%s |\n' "$T24_C_RC" "$T24_C_EXISTS" "$T24_R_RC" "$T24_R_EXISTS"
  printf '| T25 | rc=%s, before=%s, after=%s | rc=%s, before=%s, after=%s |\n' "$T25_C_RC" "$T25_C_BEFORE" "$T25_C_AFTER" "$T25_R_RC" "$T25_R_BEFORE" "$T25_R_AFTER"
  printf '| T26 | rc=%s, value=%s | rc=%s, value=%s |\n' "$T26_C_RC" "$T26_C_VALUE" "$T26_R_RC" "$T26_R_VALUE"
  printf '| T27 | rc=%s, source=%s, destination=%s | rc=%s, source=%s, destination=%s |\n' "$T27_C_RC" "$T27_C_OLD" "$T27_C_NEW" "$T27_R_RC" "$T27_R_OLD" "$T27_R_NEW"
  printf '| T28 | rc=%s, hashes_equal=%s | rc=%s, hashes_equal=%s |\n' "$T28_C_RC" "$([[ "$T28_C_SOURCE" == "$T28_C_DEST" ]] && echo yes || echo no)" "$T28_R_RC" "$([[ "$T28_R_SOURCE" == "$T28_R_DEST" ]] && echo yes || echo no)"
  printf '| T29 | rc=%s, marker_seen=%s | rc=%s, marker_seen=%s |\n' "$T29_C_RC" "$([[ "$T29_C_OUT" == *HIDDEN_MARKER_T07* ]] && echo yes || echo no)" "$T29_R_RC" "$([[ "$T29_R_OUT" == *HIDDEN_MARKER_T07* ]] && echo yes || echo no)"
  printf '| T30 | rc=%s, hash_changed=%s | rc=%s, hash_changed=%s |\n' "$T30_C_RC" "$([[ "$T30_C_BEFORE" != "$T30_C_AFTER" ]] && echo yes || echo no)" "$T30_R_RC" "$([[ "$T30_R_BEFORE" != "$T30_R_AFTER" ]] && echo yes || echo no)"
  printf '| T31 | rc=%s, hash_changed=%s | rc=%s, hash_changed=%s |\n' "$T31_C_RC" "$([[ "$T31_C_BEFORE" != "$T31_C_AFTER" ]] && echo yes || echo no)" "$T31_R_RC" "$([[ "$T31_R_BEFORE" != "$T31_R_AFTER" ]] && echo yes || echo no)"
  printf '| T32 | rc=%s, final_size=%s | rc=%s, final_size=%s, hash_changed=%s |\n' "$T32_C_RC" "$T32_C_SIZE" "$T32_R_RC" "$T32_R_SIZE" "$([[ "$T32_R_BEFORE" != "$T32_R_AFTER" ]] && echo yes || echo no)"
  printf '| T33 | rc=%s, created=%s | rc=%s, created=%s |\n' "$T33_C_RC" "$T33_C_EXISTS" "$T33_R_RC" "$T33_R_EXISTS"
  printf '| T34 | rc=%s, created=%s | rc=%s, created=%s |\n' "$T34_C_RC" "$T34_C_EXISTS" "$T34_R_RC" "$T34_R_EXISTS"
  printf '| T35 | rc=%s, marker_seen=%s | rc=%s, marker_seen=%s |\n' "$T35_C_RC" "$([[ "$T35_C_OUT" == *EXEC_MARKER_T35* ]] && echo yes || echo no)" "$T35_R_RC" "$([[ "$T35_R_OUT" == *EXEC_MARKER_T35* ]] && echo yes || echo no)"
  printf '| T36 | rc=%s, metadata_seen=%s | rc=%s, metadata_seen=%s |\n' "$T36_C_RC" "$([[ -n "$T36_C_OUT" ]] && echo yes || echo no)" "$T36_R_RC" "$([[ -n "$T36_R_OUT" ]] && echo yes || echo no)"
  printf '\n## Applied-policy snapshots\n\n'
  printf '### Restrictive\n\n```text\n%s\n```\n\n' "$POLICY_RESTRICTIVE"
  printf '### Permissive\n\n```text\n%s\n```\n\n' "$POLICY_PERMISSIVE"
  printf '## Landlock-related log lines\n\n```text\n%s\n```\n' "${LANDLOCK_LINES:-No Landlock lines found}"
} >"$REPORT"

printf '\nResults:\n'
for id in T07 T08 T09 T10 T11 T12 T13 T14 T15 T16 T21 T22 T23 T24 T25 T26 T27 T28 T29 T30 T31 T32 T33 T34 T35 T36; do
  verdict_var="${id}_VERDICT"; detail_var="${id}_DETAIL"
  printf '  %-3s %-12s %s\n' "$id" "${!verdict_var}" "${!detail_var}"
done
printf 'Report: %s\nRaw log: %s\n' "$REPORT" "$RAWLOG"

HAS_FAIL=0
HAS_INCONCLUSIVE=0
for id in T07 T08 T09 T10 T11 T12 T13 T14 T15 T16 T21 T22 T23 T24 T25 T26 T27 T28 T29 T30 T31 T32 T33 T34 T35 T36; do
  verdict_var="${id}_VERDICT"
  [[ "${!verdict_var}" == FAIL ]] && HAS_FAIL=1
  [[ "${!verdict_var}" == INCONCLUSIVE ]] && HAS_INCONCLUSIVE=1
done
[[ "$HAS_INCONCLUSIVE" -eq 0 ]] || exit 2
[[ "$EVIDENCE_COMPLETE" == yes ]] || exit 2
[[ "$HAS_FAIL" -eq 0 ]] || exit 1
exit 0
