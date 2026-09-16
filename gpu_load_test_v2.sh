#!/bin/bash
#
# GPU Load + PCIe / Thermal Test Script  (v2)
# Uses dcgmproftester13 for high utilization on RTX PRO 6000 Blackwell
# himpickup@gmail.com

set -e

# ---------- Configuration ----------
SAMPLE_INTERVAL=1          # seconds between nvidia-smi samples
DCGM_TARGET=1004           # Compute / SM stress (high utilization)
DCGM_BIN="dcgmproftester13"

# ---------- Colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ---------- Helper ----------
timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# ---------- Pre-checks ----------
echo -e "${GREEN}=== GPU Load + PCIe Test (dcgmproftester) v2 ===${NC}"
echo

for cmd in nvidia-smi ipmitool; do
    if ! command -v $cmd &>/dev/null; then
        echo -e "${RED}Error: $cmd not found${NC}"
        exit 1
    fi
done

if ! command -v $DCGM_BIN &>/dev/null; then
    if command -v dcgmproftester &>/dev/null; then
        DCGM_BIN="dcgmproftester"
    else
        echo -e "${RED}Error: dcgmproftester13 (or dcgmproftester) not found${NC}"
        exit 1
    fi
fi

# ---------- Get Product Serial Number ----------
SN=$(ipmitool fru 2>/dev/null | grep 'Product Serial' | awk '{print $4}' | head -1)
if [ -z "$SN" ]; then
    SN="UNKNOWN_SN"
    echo -e "${YELLOW}Warning: Could not read Product Serial from IPMI. Using ${SN}${NC}"
fi
echo -e "System Serial : ${YELLOW}${SN}${NC}"
echo

# ---------- Log directory: /data/nvidia/$SN ----------
LOG_DIR="/data/nvidia/${SN}"
if [ -d "$LOG_DIR" ]; then
    echo -e "Log directory : ${YELLOW}${LOG_DIR}${NC} (already exists)"
else
    mkdir -p "$LOG_DIR"
    echo -e "Log directory : ${YELLOW}${LOG_DIR}${NC} (created)"
fi
echo

# ---------- Ask duration ----------
read -p "How many minutes should the test run? " MINUTES

if ! [[ "$MINUTES" =~ ^[0-9]+$ ]] || [ "$MINUTES" -le 0 ]; then
    echo -e "${RED}Error: Please enter a positive integer.${NC}"
    exit 1
fi

DURATION_SEC=$((MINUTES * 60))
echo -e "Test will run for ${YELLOW}${MINUTES} minute(s)${NC} (${DURATION_SEC} seconds)"
echo -e "DCGM target  : ${YELLOW}${DCGM_TARGET}${NC} (compute / SM stress)"
echo

# ---------- Prepare log files ----------
TS_FILE=$(date '+%Y%m%d_%H%M%S')
LOG_FILE="${LOG_DIR}/${SN}_${TS_FILE}_thermal.log"
SMI_LOG="${LOG_DIR}/${SN}_${TS_FILE}_thermal.csv"

echo "Main log      : $LOG_FILE"
echo "nvidia-smi log: $SMI_LOG"
echo

# ---------- CSV header ----------
echo "timestamp,index,pci.bus_id,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max,utilization.gpu [%],utilization.memory [%],memory.used [MiB],power.draw [W],power.limit [W],temperature.gpu,clocks.current.sm [MHz],clocks.current.memory [MHz],pstate" > "$SMI_LOG"

# ---------- Start DCGM stress (cwd = LOG_DIR so its own logs stay there) ----------
echo -e "${GREEN}Starting dcgmproftester (${DCGM_BIN}) ...${NC}"
(
    cd "$LOG_DIR"
    $DCGM_BIN --no-dcgm-validation --max-processes 0 -t $DCGM_TARGET -d $DURATION_SEC >> "$LOG_FILE" 2>&1
) &
LOAD_PID=$!
echo "Workload PID: $LOAD_PID"
echo "dcgmproftester.log + tensor_active_*.results will be written inside: $LOG_DIR"
echo

# Trap to clean up on Ctrl+C
cleanup() {
    echo
    echo -e "${YELLOW}Stopping workload (PID $LOAD_PID)...${NC}"
    kill $LOAD_PID 2>/dev/null || true
    wait $LOAD_PID 2>/dev/null || true
    echo -e "${GREEN}Test stopped. Logs saved.${NC}"
    echo "  Main log     : $LOG_FILE"
    echo "  nvidia-smi   : $SMI_LOG"
    echo "  DCGM files   : $LOG_DIR/dcgmproftester.log , tensor_active_*.results"
    exit 0
}
trap cleanup INT TERM

# ---------- Sampling loop ----------
echo -e "${GREEN}Sampling nvidia-smi every ${SAMPLE_INTERVAL}s ...${NC}"
echo "Press Ctrl+C to stop early."
echo

QUERY_FIELDS="index,pci.bus_id,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max,utilization.gpu,utilization.memory,memory.used,power.draw,power.limit,temperature.gpu,clocks.current.sm,clocks.current.memory,pstate"

START_TIME=$(date +%s)
END_TIME=$((START_TIME + DURATION_SEC))

while true; do
    NOW=$(date +%s)
    if [ "$NOW" -ge "$END_TIME" ]; then
        break
    fi

    # Exit early if workload already finished
    if ! kill -0 $LOAD_PID 2>/dev/null; then
        echo "Workload finished early."
        break
    fi

    TS=$(timestamp)

    # Capture sample into CSV
    nvidia-smi --query-gpu=${QUERY_FIELDS} --format=csv,noheader | while IFS= read -r line; do
        echo "$TS,$line" >> "$SMI_LOG"
    done

    # Live compact summary
    echo -n "[$TS] "
    nvidia-smi --query-gpu=index,pcie.link.gen.current,pcie.link.width.current,utilization.gpu,power.draw,temperature.gpu,pstate \
        --format=csv,noheader | tr '\n' ' | ' | sed 's/ | $/\n/'

    sleep "$SAMPLE_INTERVAL"
done

# ---------- Finished ----------
wait $LOAD_PID 2>/dev/null || true
echo
echo -e "${GREEN}Test completed.${NC}"
echo "  Main log     : $LOG_FILE"
echo "  nvidia-smi   : $SMI_LOG"
echo "  DCGM files   : $LOG_DIR/dcgmproftester.log , tensor_active_*.results"
