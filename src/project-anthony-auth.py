#!/usr/bin/env python3
"""Fallback PAM check when the C helper was not compiled. Same CLI as the C binary."""
import ctypes
import ctypes.util
import os
import sys

PAM_SUCCESS = 0
PAM_PROMPT_ECHO_OFF = 1
PAM_PROMPT_ECHO_ON = 2
PAM_BUF_ERR = 5


class PamHandle(ctypes.c_void_p):
    pass


class PamMessage(ctypes.Structure):
    _fields_ = [("msg_style", ctypes.c_int), ("msg", ctypes.c_char_p)]


class PamResponse(ctypes.Structure):
    _fields_ = [("resp", ctypes.c_char_p), ("resp_retcode", ctypes.c_int)]


CONV_FUNC = ctypes.CFUNCTYPE(
    ctypes.c_int,
    ctypes.c_int,
    ctypes.POINTER(ctypes.POINTER(PamMessage)),
    ctypes.POINTER(ctypes.POINTER(PamResponse)),
    ctypes.c_void_p,
)


class PamConv(ctypes.Structure):
    _fields_ = [("conv", CONV_FUNC), ("appdata_ptr", ctypes.c_void_p)]


def main() -> int:
    if os.geteuid() != 0:
        return 1
    if len(sys.argv) != 2 or not sys.argv[1]:
        return 2
    password = sys.stdin.readline().rstrip("\n")
    user = sys.argv[1].encode()
    pass_bytes = password.encode()
    libname = ctypes.util.find_library("pam") or "libpam.so.0"
    libpam = ctypes.CDLL(libname)
    libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6")
    libc.strdup.restype = ctypes.c_char_p
    libc.strdup.argtypes = [ctypes.c_char_p]
    libc.calloc.restype = ctypes.c_void_p
    libc.calloc.argtypes = [ctypes.c_size_t, ctypes.c_size_t]
    keep = []

    @CONV_FUNC
    def conv_cb(nmsg, msg, resp, _app):
        if nmsg <= 0:
            return PAM_BUF_ERR
        raw = libc.calloc(nmsg, ctypes.sizeof(PamResponse))
        if not raw:
            return PAM_BUF_ERR
        arr = ctypes.cast(raw, ctypes.POINTER(PamResponse))
        keep.append(arr)
        for i in range(nmsg):
            style = msg[i].contents.msg_style
            if style in (PAM_PROMPT_ECHO_OFF, PAM_PROMPT_ECHO_ON):
                arr[i].resp = libc.strdup(pass_bytes)
        resp[0] = arr
        return PAM_SUCCESS

    conv = PamConv(conv_cb, None)
    pamh = PamHandle()
    libpam.pam_start.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.POINTER(PamConv),
        ctypes.POINTER(PamHandle),
    ]
    libpam.pam_start.restype = ctypes.c_int
    libpam.pam_authenticate.argtypes = [PamHandle, ctypes.c_int]
    libpam.pam_authenticate.restype = ctypes.c_int
    libpam.pam_acct_mgmt.argtypes = [PamHandle, ctypes.c_int]
    libpam.pam_acct_mgmt.restype = ctypes.c_int
    libpam.pam_end.argtypes = [PamHandle, ctypes.c_int]
    libpam.pam_end.restype = ctypes.c_int
    rc = libpam.pam_start(b"project-anthony", user, ctypes.byref(conv), ctypes.byref(pamh))
    if rc == PAM_SUCCESS:
        rc = libpam.pam_authenticate(pamh, 0)
    if rc == PAM_SUCCESS:
        rc = libpam.pam_acct_mgmt(pamh, 0)
    if pamh:
        libpam.pam_end(pamh, rc)
    return 0 if rc == PAM_SUCCESS else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(1)
