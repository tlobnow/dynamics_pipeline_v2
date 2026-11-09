"""Small shared helpers used across the pipeline stages."""

import os
import sys
import time
import traceback
from contextlib import contextmanager

import ray

UNATTRIBUTED = '__unattributed__'

# Where log() writes. Modes that print a machine-readable value on stdout (
# --print-r-path, consumed by `r_path=$(...)` in submit_node.sh) redirect this
# to stderr, so that stdout carries the value and nothing else.
_LOG_STREAM = sys.stdout


def set_log_stream(stream):
    global _LOG_STREAM
    _LOG_STREAM = stream


def log(message):
    """print() that actually shows up in the right order in a Slurm .out file."""
    print(message, file=_LOG_STREAM, flush=True)


def fmt_exc(e):
    return '{}: {}'.format(type(e).__name__, e)


@contextmanager
def ray_session(num_cpus):
    """Start a clean ray session and always tear it down, even on failure."""
    ray.shutdown()
    time.sleep(1)
    ray.init(num_cpus=num_cpus, ignore_reinit_error=True)
    try:
        yield
    finally:
        time.sleep(1)
        ray.shutdown()
        time.sleep(1)


def attribute(path, image_names):
    """Work out which image a derived file path belongs to.

    Stage helpers hand back flat lists of file paths rather than image names,
    so we recover the owning image from the path. Exact path-component match
    first, substring match as a fallback.
    """
    if path is None:
        return UNATTRIBUTED
    parts = set(os.path.normpath(str(path)).split(os.sep))
    for name in image_names:
        if name in parts:
            return name
    for name in image_names:
        if name and name in str(path):
            return name
    return UNATTRIBUTED


def gather(pairs):
    """Resolve (label, ray_ref_or_value) pairs into {label: (ok, error)}.

    Each ref is resolved individually rather than through a bulk ray.get, so a
    single failing task is attributed to its own image instead of taking the
    whole stage down. Plain (non-ray) values are passed through, which is what
    the synchronous median-blur step needs.
    """
    results = {}
    for label, ref in pairs:
        try:
            if isinstance(ref, ray.ObjectRef):
                ray.get(ref)
            ok, err = True, None
        except Exception as e:
            ok, err = False, fmt_exc(e)
            traceback.print_exc(file=sys.stdout)
        prev_ok, prev_err = results.get(label, (True, None))
        results[label] = (prev_ok and ok, prev_err or err)
    return results


def merge_results(base, extra):
    """Add `extra` into `base` without overwriting an already-recorded failure."""
    for key, value in extra.items():
        if key not in base:
            base[key] = value
        elif base[key][0] and not value[0]:
            base[key] = value
    return base