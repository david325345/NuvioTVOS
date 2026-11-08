# Simulates tvOS taking a suspended app's listening sockets away: duplicates the
# process' listening sockets (pidfd_getfd) and shuts them down; the process is not told.
import ctypes, os, socket, sys
pid = int(sys.argv[1]); ports = {int(p) for p in sys.argv[2:]}
inodes = {}
for line in open('/proc/net/tcp').read().splitlines()[1:]:
    f = line.split()
    port = int(f[1].split(':')[1], 16)
    if f[3] == '0A' and port in ports:
        inodes[f[9]] = port
libc = ctypes.CDLL(None, use_errno=True)
pidfd = os.pidfd_open(pid)
for fd in os.listdir(f'/proc/{pid}/fd'):
    try:
        target = os.readlink(f'/proc/{pid}/fd/{fd}')
    except OSError:
        continue
    if target.startswith('socket:[') and target[8:-1] in inodes:
        local = libc.syscall(438, pidfd, int(fd), 0)  # pidfd_getfd
        if local < 0:
            print('pidfd_getfd failed', ctypes.get_errno()); continue
        s = socket.socket(fileno=local)
        s.shutdown(socket.SHUT_RDWR)
        print(f'port {inodes[target[8:-1]]}: shut down')
        s.detach(); os.close(local)
