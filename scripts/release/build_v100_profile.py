#!/usr/bin/env python3
"""Compile the pinned V100 profile; never execute CUDA tests or a miner.

Requires a clean checkout of the source in the integration manifest, CMake,
Ninja and CUDA. All subprocesses share one absolute deadline. Outputs are
preparation artifacts, not a GPU-validated release.
"""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def run(command, deadline, log=None):
    remaining = deadline - time.time()
    if remaining <= 0:
        raise RuntimeError("absolute deadline expired")
    with subprocess.Popen(command, stdout=log or subprocess.PIPE,
                          stderr=subprocess.STDOUT, start_new_session=True,
                          text=True) as process:
        try:
            output, _ = process.communicate(timeout=remaining)
        except BaseException:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise
        if process.returncode:
            raise RuntimeError(f"command failed ({process.returncode}): {command[0]}")
        return (output or "").strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--deadline-utc", required=True,
                        help="absolute YYYY-MM-DDTHH:MM:SSZ; 5–40 minutes remaining")
    args = parser.parse_args()
    deadline = dt.datetime.strptime(args.deadline_utc, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=dt.timezone.utc).timestamp()
    if not 300 <= deadline - time.time() <= 2400:
        raise RuntimeError("require 5–40 minutes before the absolute deadline")
    manifest = json.loads(args.manifest.read_text())
    source = args.source.resolve(strict=True)
    build = args.build.resolve()
    if build == source or source in build.parents:
        raise RuntimeError("build directory must be outside the source checkout")
    if build.exists():
        raise RuntimeError("use a new build directory; existing output is never overwritten")
    head = run(["git", "-C", str(source), "rev-parse", "HEAD"], deadline)
    if head != manifest["v100_source"]:
        raise RuntimeError("source commit does not match the pinned V100 profile")
    if run(["git", "-C", str(source), "status", "--porcelain", "--untracked-files=all"], deadline):
        raise RuntimeError("source checkout must be clean, including untracked files")
    build.mkdir(parents=True)
    evidence = {"source_commit": head, "status": "started",
                "gpu_tests_executed": False, "pool_tests_executed": False,
                "deadline_utc": args.deadline_utc,
                "historical_gpu_evidence_transferred": False}
    record = build / "PROFILE_BUILD.json"
    record.write_text(json.dumps(evidence, indent=2) + "\n")
    targets = ["pepepowminer", "pepepow_core_tests", "pepepow_cuda_tests",
               "pepepow_cuda_header80_validation", "pepepow_header80_benchmark",
               "pepepow_header80_differential"]
    try:
        with (build / "build.log").open("w") as log:
            run(["cmake", "-S", str(source / "native"), "-B", str(build),
                 "-G", "Ninja", *manifest["v100_cmake_arguments"]], deadline, log)
            run(["cmake", "--build", str(build), "--parallel", "4", "--target", *targets],
                deadline, log)
            run(["ctest", "--test-dir", str(build), "--output-on-failure",
                 "--no-tests=error", "-R", "^pepepow_core_tests$"], deadline, log)
        evidence["status"] = "compiled-cpu-tested-gpu-unverified"
    except BaseException:
        evidence["status"] = "failed-or-interrupted"
        raise
    finally:
        evidence["ended_utc"] = dt.datetime.now(dt.timezone.utc).isoformat()
        record.write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    main()
