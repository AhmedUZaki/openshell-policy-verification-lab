FROM ubuntu:24.04

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       attr bash ca-certificates coreutils curl iproute2 python3 \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 1500 tester \
    && useradd --uid 1500 --gid 1500 --create-home --shell /bin/bash tester \
    && mkdir -p /work /opt/claims-fixtures/hidden /opt/claims-fixtures/readonly /opt/claims-fixtures/readonly/empty-dir-t24 \
    && printf 'HIDDEN_MARKER_F1_1\n' > /opt/claims-fixtures/hidden/read.txt \
    && printf 'ORIGINAL_MODIFY_T08\n' > /opt/claims-fixtures/readonly/modify.txt \
    && printf 'ORIGINAL_TRUNCATE_T09\n' > /opt/claims-fixtures/readonly/truncate.txt \
    && printf 'ORIGINAL_DELETE_T10\n' > /opt/claims-fixtures/readonly/delete.txt \
    && printf 'ORIGINAL_SHELL_TRUNCATE_T11\n' > /opt/claims-fixtures/readonly/shell-truncate.txt \
    && printf 'ORIGINAL_PYTHON_OPEN_T12\n' > /opt/claims-fixtures/readonly/python-open.txt \
    && printf 'ORIGINAL_OVERWRITE_T13\n' > /opt/claims-fixtures/readonly/overwrite.txt \
    && printf 'ORIGINAL_RENAME_T14\n' > /opt/claims-fixtures/readonly/rename.txt \
    && printf 'ORIGINAL_CHMOD_T16\n' > /opt/claims-fixtures/readonly/chmod.txt \
    && printf 'ORIGINAL_HARDLINK_T21\n' > /opt/claims-fixtures/readonly/hardlink.txt \
    && printf 'ORIGINAL_SYMLINK_T22\n' > /opt/claims-fixtures/readonly/symlink-source.txt \
    && printf 'ORIGINAL_UTIME_T25\n' > /opt/claims-fixtures/readonly/utime.txt \
    && printf 'ORIGINAL_XATTR_T26\n' > /opt/claims-fixtures/readonly/xattr.txt \
    && printf 'ORIGINAL_CROSS_RENAME_T27\n' > /opt/claims-fixtures/readonly/cross-rename.txt \
    && printf 'ORIGINAL_COPY_T28\n' > /opt/claims-fixtures/readonly/copy-out.txt \
    && printf 'ORIGINAL_SYMLINK_WRITE_T30\n' > /opt/claims-fixtures/readonly/symlink-write.txt \
    && printf 'ORIGINAL_MMAP_T31\n' > /opt/claims-fixtures/readonly/mmap.txt \
    && printf 'ORIGINAL_RDONLY_TRUNC_T32\n' > /opt/claims-fixtures/readonly/rdonly-truncate.txt \
    && printf '#!/bin/sh\nprintf "EXEC_MARKER_F2_17\\n"\n' > /opt/claims-fixtures/readonly/execute-t35.sh \
    && ln -s ../hidden/read.txt /opt/claims-fixtures/readonly/hidden-link-t29 \
    && chown -R tester:tester /work /opt/claims-fixtures \
    && chmod 0777 /opt/claims-fixtures /opt/claims-fixtures/hidden /opt/claims-fixtures/readonly \
    && chmod 0666 /opt/claims-fixtures/hidden/read.txt /opt/claims-fixtures/readonly/*.txt \
    && chmod 0777 /opt/claims-fixtures/readonly/empty-dir-t24 /opt/claims-fixtures/readonly/execute-t35.sh

USER tester:tester
WORKDIR /work
CMD ["sleep", "infinity"]
