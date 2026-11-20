#!/usr/bin/env python3
"""Serialize promotion and packaging snapshots of the vendored desktop runtime."""

from contextlib import contextmanager
import ctypes
import fcntl
import os
from pathlib import Path
import shutil
import sys


RUNTIME_FILES = (
    'bin/agent-desktop',
    'bin/agent-desktop-macos-helper',
    'lib/libagent_desktop_ffi.dylib',
    'lib/agent-desktop-macos-helper',
    'include/agent_desktop.h',
    'LICENSE',
    'VERSION',
)


@contextmanager
def vendor_lock(installed, mode):
    # The parent directory survives runtime swaps and does not need a lock file.
    descriptor = os.open(installed.parent, os.O_RDONLY)
    try:
        fcntl.flock(descriptor, mode)
        yield
    finally:
        os.close(descriptor)


def validate_runtime(directory):
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError('Expected an ordinary desktop runtime directory.')
    for relative in RUNTIME_FILES:
        path = directory / relative
        if path.is_symlink() or path.parent.is_symlink() or not path.is_file() or path.stat().st_size == 0:
            raise ValueError('Missing or invalid desktop runtime file: ' + relative)


def promote(installed, staged):
    validate_runtime(staged)
    with vendor_lock(installed, fcntl.LOCK_EX):
        if installed.is_symlink():
            raise ValueError('Expected a managed vendor directory, not a symlink.')
        if not installed.exists():
            staged.rename(installed)
            return
        if not installed.is_dir():
            raise ValueError('Expected a managed vendor directory.')
        # Exchange in one filesystem operation. The old runtime moves into the
        # temporary directory for cleanup once all readers of it have finished.
        swap = ctypes.CDLL(None, use_errno=True).renamex_np
        swap.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        swap.restype = ctypes.c_int
        rename_swap = 0x00000002
        if swap(os.fsencode(staged), os.fsencode(installed), rename_swap) != 0:
            raise OSError(os.strerror(ctypes.get_errno()))


def snapshot(installed, destination):
    if not installed.parent.exists():
        return
    with vendor_lock(installed, fcntl.LOCK_SH):
        if not installed.exists() and not installed.is_symlink():
            return
        validate_runtime(installed)
        for relative in RUNTIME_FILES:
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(installed / relative, target)


if __name__ == '__main__':
    action, installed, other = sys.argv[1:]
    try:
        {'promote': promote, 'snapshot': snapshot}[action](Path(installed), Path(other))
    except (OSError, ValueError) as error:
        sys.exit('Desktop runtime: ' + str(error))
