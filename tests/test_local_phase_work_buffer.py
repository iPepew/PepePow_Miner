#!/usr/bin/env python3
"""Host-only allocation preprocessor regression; no CUDA or GPU execution."""
import itertools
import pathlib
import subprocess
import unittest

class WorkBufferAllocation(unittest.TestCase):
    def test_configuration_matrix(self):
        source = (pathlib.Path(__file__).resolve().parents[1] /
                  "native/src/cuda/v1/header80_backend_part07.inc").read_text()
        begin = source.index("// Only the global resident variant")
        fragment = source[begin:source.index("sizeof(std::uint32_t)", begin)]
        keys = ["PEPEPOW_CUDA_LOCAL_RESIDENCY", "PEPEPOW_CUDA_HOTRUN8",
                "PEPEPOW_CUDA_HOTRUN8_FUSION_MODE",
                "PEPEPOW_CUDA_RUNTIME_LOCAL_PHASE_CACHE"]
        for values in itertools.product([None, 0, 1], [None, 0, 1],
                                        [None, 0, 1, 2], [None, 0, 1]):
            with self.subTest(flags=values):
                command = ["cpp", "-P", "-"] + [
                    f"-D{k}={v}" for k, v in zip(keys, values) if v is not None]
                result = subprocess.run(command, input=fragment, text=True,
                    capture_output=True, check=True, timeout=2).stdout.strip()
                local, hot, fusion, phase = values
                # Only fusion2 local-phase avoids the second global region.
                expected = 8 if not local or (hot == 1 and fusion == 2 and phase == 1) else 16
                self.assertEqual(result, f"{expected}U *")

if __name__ == "__main__":
    unittest.main()
