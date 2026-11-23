"""Does open(O_RDONLY|O_TRUNC) truncate a file under Landlock, with and without the TRUNCATE right handled?
Runs entirely in a temp dir; touches nothing else."""
import ctypes, os, struct, sys, tempfile

libc = ctypes.CDLL(None, use_errno=True)
SYS_CREATE, SYS_ADD, SYS_RESTRICT = 444, 445, 446
EXECUTE, WRITE_FILE, READ_FILE, READ_DIR = 1, 2, 4, 8
TRUNCATE = 1 << 14
ALL_V2 = (1 << 14) - 1          # bits 0..13 (ABI v1+v2 rights)
ALL_V3 = ALL_V2 | TRUNCATE      # plus truncate (ABI v3)


def run(handled, label):
    pid = os.fork()
    if pid:
        _, status = os.waitpid(pid, 0)
        return
    d = tempfile.mkdtemp()
    path = os.path.join(d, "f.txt")
    with open(path, "w") as f:
        f.write("ORIGINAL CONTENT\n")
    os.chmod(path, 0o666)
    attr = struct.pack("=Q", handled)
    rs = libc.syscall(SYS_CREATE, attr, len(attr), 0)
    assert rs >= 0, f"create_ruleset failed errno={ctypes.get_errno()}"
    dfd = os.open(d, os.O_PATH)
    rule = struct.pack("=Qi", READ_FILE | READ_DIR | EXECUTE, dfd)   # read-only on the directory
    assert libc.syscall(SYS_ADD, rs, 1, rule, 0) == 0, "add_rule failed"
    libc.prctl(38, 1, 0, 0, 0)
    assert libc.syscall(SYS_RESTRICT, rs, 0) == 0, "restrict_self failed"
    result = "open ok"
    try:
        fd = os.open(path, os.O_RDONLY | os.O_TRUNC)
        os.close(fd)
    except OSError as error:
        result = f"open failed: {error.strerror} (errno {error.errno})"
    print(f"{label}: {result}; size after = {os.stat(path).st_size} bytes (was 17)", flush=True)
    os._exit(0)


run(ALL_V2, "ABI v2 rights (no TRUNCATE handled)")
run(ALL_V3, "ABI v3 rights (TRUNCATE handled)   ")
