from pathlib import Path
import re
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: prepare-v210-geometry-runner.py INPUT_RUNNER OUTPUT_RUNNER")

src = Path(sys.argv[1]).read_text(encoding="utf-8")

src = src.replace('NAME="v200-warp-service-${STAMP}"', 'NAME="v210-geometry-${STAMP}"')
src = src.replace('BACKUP_FILE="$SOURCE_FILE.v200-backup-$STAMP"', 'BACKUP_FILE="$SOURCE_FILE.v210-backup-$STAMP"')
src = src.replace('BUILD_ROOT="$SOURCE_ROOT/build-v200-warp-service"', 'BUILD_ROOT="$SOURCE_ROOT/build-v210-geometry"')
src = src.replace(
    'PUBLISHER_URL="https://raw.githubusercontent.com/iPepew/PepePow_Miner/experiment/v2.0.0-warp-service/tools/publish-test-results.sh"',
    'PUBLISHER_URL="https://raw.githubusercontent.com/iPepew/PepePow_Miner/experiment/v2.1.0-geometry/tools/publish-test-results.sh"',
)

old_setup = '''mkdir -p "$STAGE"/{profiles,nvidia,source,stress,sanitizer}
cp -f "$SOURCE_FILE" "$BACKUP_FILE"
cp -f "$SOURCE_FILE" "$STAGE/source/header80_backend_v060.original.cu"
cp -f "$P080" "$P081" "$PZERO" "$PSERVICE" "$STAGE/source/"
restore(){ [[ -f "$BACKUP_FILE" ]] && { cp -f "$BACKUP_FILE" "$SOURCE_FILE"; rm -f "$BACKUP_FILE"; }; }
trap restore EXIT INT TERM
'''
new_setup = '''mkdir -p "$STAGE"/{profiles,nvidia,source,stress,sanitizer}
CMAKE_FILE="$SOURCE_ROOT/native/CMakeLists.txt"
CMAKE_BACKUP="$CMAKE_FILE.v210-backup-$STAMP"
cp -f "$SOURCE_FILE" "$BACKUP_FILE"
cp -f "$CMAKE_FILE" "$CMAKE_BACKUP"
cp -f "$SOURCE_FILE" "$STAGE/source/header80_backend_v060.original.cu"
cp -f "$CMAKE_FILE" "$STAGE/source/CMakeLists.original.txt"
cp -f "$P080" "$P081" "$PZERO" "$PSERVICE" "$STAGE/source/"
python3 - "$CMAKE_FILE" <<'PY'
from pathlib import Path
import re, sys
p=Path(sys.argv[1]); t=p.read_text()
t=t.replace(
    'PEPEPOW_CUDA_THREADS must be 64, 96, 128, 160, 192, 256, 320 or 384',
    'PEPEPOW_CUDA_THREADS must be a warp multiple from 64 through 768')
t,n=re.subn(r'if\s*\(NOT PEPEPOW_CUDA_THREADS MATCHES "[^\"]+"\)',
            'if(NOT PEPEPOW_CUDA_THREADS MATCHES "^(64|96|128|160|192|224|256|288|320|352|384|416|448|480|512|544|576|608|640|672|704|736|768)$")',
            t, count=1)
if n != 1:
    raise SystemExit('ERROR: CUDA thread validation predicate not found')
p.write_text(t)
PY
restore(){
  [[ -f "$BACKUP_FILE" ]] && { cp -f "$BACKUP_FILE" "$SOURCE_FILE"; rm -f "$BACKUP_FILE"; }
  [[ -f "$CMAKE_BACKUP" ]] && { cp -f "$CMAKE_BACKUP" "$CMAKE_FILE"; rm -f "$CMAKE_BACKUP"; }
}
trap restore EXIT INT TERM
'''
if old_setup not in src:
    raise SystemExit("ERROR: setup block not found")
src = src.replace(old_setup, new_setup, 1)

array_start = src.find("IDS=(\n")
array_end = src.find('TOTAL="${#IDS[@]}"', array_start)
if array_start < 0 or array_end < 0:
    raise SystemExit("ERROR: profile arrays not found")
array_end += len('TOTAL="${#IDS[@]}"')
threads = [256, 288, 320, 352, 384, 416, 448, 480, 512, 544, 576, 608, 640, 672, 704, 736, 768]
ids = [f"service{t}" for t in threads]
arrays = "IDS=(\n " + "\n ".join(ids) + "\n)\n"
arrays += "COLD=(\n " + " ".join(["combined"] * len(ids)) + "\n)\n"
arrays += "SERVICE=(\n " + " ".join(["service"] * len(ids)) + "\n)\n"
arrays += "ZERO=(\n " + " ".join(["0"] * len(ids)) + "\n)\n"
arrays += "THREADS=(\n " + " ".join(map(str, threads)) + "\n)\n"
arrays += "BLOCKS=(\n " + " ".join(["1"] * len(ids)) + "\n)\n"
arrays += 'TOTAL="${#IDS[@]}"'
src = src[:array_start] + arrays + src[array_end:]

src = src.replace('baseline=selector-combined-base', 'baseline=service256')
src = src.replace('architecture=block_compacted_cold_service_warp', 'architecture=service_warp_geometry_sweep_256_to_768')
src = src.replace("r['profile']=='selector-combined-base'", "r['profile']=='service256'")

Path(sys.argv[2]).write_text(src, encoding="utf-8")
