#!/usr/bin/env python3
"""Rigorous analytic error bounds for the historical 98,304-cell dual LUT.

This proof isolates interpolation error only. It does not claim full HooHash
consensus equivalence; that still requires an interval guard through the state
machine and CPU<->CUDA differential testing.

For linear interpolation on an interval of angular width h, the classical
bound is |f-L| <= h^2/8 * max|f''|.

Functions:
  f(theta) = exp(sin(theta)+cos(theta))
  g(theta) = sin(theta)^2

Analytic derivative bounds used below:
  q = sin+cos, |q| <= sqrt(2), |q'| <= sqrt(2), q''=-q
  f'' = f * ((q')^2 + q'')
  |f''| <= exp(sqrt(2)) * (2 + sqrt(2))
  g'' = 2*cos(2*theta), so |g''| <= 2
"""

from __future__ import annotations

import math

LUT_INTERVALS = 98_304
MAX_NIBBLE = 15.0
SCALE = 1234.0


def main() -> int:
    h = 2.0 * math.pi / LUT_INTERVALS
    max_f2 = math.exp(math.sqrt(2.0)) * (2.0 + math.sqrt(2.0))
    max_g2 = 2.0

    exp_interp = (h * h / 8.0) * max_f2
    sin2_interp = (h * h / 8.0) * max_g2

    # Worst contribution error after HooHash's * value * 1234 factor.
    exp_contrib = exp_interp * MAX_NIBBLE * SCALE
    sin2_contrib = sin2_interp * MAX_NIBBLE * SCALE

    # Conservative row bound if every one of 64 cells took the same cold path.
    exp_row_all_cold = exp_contrib * 64.0
    sin2_row_all_cold = sin2_contrib * 64.0

    print(f"lut_intervals={LUT_INTERVALS}")
    print(f"angular_cell_width={h:.17g}")
    print(f"max_abs_f2_exp_sincos={max_f2:.17g}")
    print(f"max_abs_f2_sin2={max_g2:.17g}")
    print(f"exp_sincos_interp_abs_bound={exp_interp:.17g}")
    print(f"sin2_interp_abs_bound={sin2_interp:.17g}")
    print(f"exp_sincos_max_contribution_error={exp_contrib:.17g}")
    print(f"sin2_max_contribution_error={sin2_contrib:.17g}")
    print(f"exp_sincos_64cell_row_error_if_all_cold={exp_row_all_cold:.17g}")
    print(f"sin2_64cell_row_error_if_all_cold={sin2_row_all_cold:.17g}")

    # These are deliberately strict sanity gates. The important criterion is
    # that an individual LUT call contributes far below one unit of product,
    # leaving room for an interval guard around integer/1024 boundaries.
    if exp_interp >= 1e-7:
        print("RESULT=FAIL exp(sin+cos) interpolation bound too large")
        return 2
    if sin2_interp >= 1e-8:
        print("RESULT=FAIL sin^2 interpolation bound too large")
        return 3
    if exp_contrib >= 1e-3:
        print("RESULT=FAIL scaled exp contribution bound too large")
        return 4
    if sin2_contrib >= 1e-3:
        print("RESULT=FAIL scaled sin2 contribution bound too large")
        return 5

    print("RESULT=PASS historical dual-LUT grid is sufficiently fine for guarded interval work")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
