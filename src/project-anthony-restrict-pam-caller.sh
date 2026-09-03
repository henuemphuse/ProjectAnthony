#!/bin/sh
# Only the root TTY3 helper may use project-anthony PAM services.
# pam_exec runs as a child of the PAM client; PPID is that client.
# Do not include common-auth/faillock: this gate replaces a public oracle
# without locking the desktop account or the rescue USB break-glass.

AUTH_BIN="/usr/local/bin/project-anthony-auth"
ppid="${PPID:-0}"

[ "$ppid" -gt 1 ] 2>/dev/null || exit 1
[ -r "/proc/${ppid}/status" ] || exit 1
[ -r "/proc/${ppid}/exe" ] || exit 1

# Field 3 is the effective UID.
euid=$(awk '/^Uid:/{print $3; exit}' "/proc/${ppid}/status")
[ "$euid" = "0" ] || exit 1

exe=$(readlink "/proc/${ppid}/exe" 2>/dev/null) || exit 1
exe=${exe% (deleted)}

if [ "$exe" = "$AUTH_BIN" ]; then
    exit 0
fi

# Python fallback: shebang makes /proc/pid/exe the interpreter.
case "$exe" in
    */python|*/python[0-9]|*/python3|*/python3.*)
        ;;
    *)
        exit 1
        ;;
esac

arg1=$(tr '\0' '\n' < "/proc/${ppid}/cmdline" | sed -n '1p')
arg2=$(tr '\0' '\n' < "/proc/${ppid}/cmdline" | sed -n '2p')
[ "$arg1" = "$AUTH_BIN" ] || [ "$arg2" = "$AUTH_BIN" ] || exit 1
exit 0
