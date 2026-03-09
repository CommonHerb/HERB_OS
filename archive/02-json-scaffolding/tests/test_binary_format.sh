#!/bin/bash
# Cross-format equivalence: .herb.json vs .herb binary
# Same program loaded from both formats must produce identical state.

cd "$(dirname "$0")"

TOOL=./test_binary_equiv.exe
PROG=../programs
PASS=0
FAIL=0
TOTAL=0

compare() {
    local name="$1"
    local json="$2"
    local bin="$3"
    shift 3

    TOTAL=$((TOTAL + 1))
    printf "  %-40s " "$name"

    json_out=$($TOOL "$json" "$@" 2>/dev/null)
    bin_out=$($TOOL "$bin" "$@" 2>/dev/null)

    if [ "$json_out" = "$bin_out" ]; then
        echo "MATCH"
        PASS=$((PASS + 1))
    else
        echo "MISMATCH!"
        echo "    JSON: $(echo "$json_out" | head -3)"
        echo "    BIN:  $(echo "$bin_out" | head -3)"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== HERB Binary Format Equivalence ==="
echo ""

# Priority Scheduler
compare "priority_sched (boot)" \
    "$PROG/priority_scheduler.herb.json" "$PROG/priority_scheduler.herb"
compare "priority_sched (timer)" \
    "$PROG/priority_scheduler.herb.json" "$PROG/priority_scheduler.herb" \
    "t1 Signal TIMER_EXPIRED"

# FIFO Scheduler
compare "scheduler (boot)" \
    "$PROG/scheduler.herb.json" "$PROG/scheduler.herb"
compare "scheduler (timer+io)" \
    "$PROG/scheduler.herb.json" "$PROG/scheduler.herb" \
    "t1 Signal TIMER_EXPIRED" "io1 Signal IO_COMPLETE"

# DOM Layout
compare "dom_layout (boot)" \
    "$PROG/dom_layout.herb.json" "$PROG/dom_layout.herb"

# Economy
compare "economy (boot)" \
    "$PROG/economy.herb.json" "$PROG/economy.herb"

# Multiprocess
compare "multiprocess (boot)" \
    "$PROG/multiprocess.herb.json" "$PROG/multiprocess.herb"

# IPC
compare "ipc (boot)" \
    "$PROG/ipc.herb.json" "$PROG/ipc.herb"

# Interactive OS
compare "interactive_os (boot)" \
    "$PROG/interactive_os.herb.json" "$PROG/interactive_os.herb"
compare "interactive_os (timer)" \
    "$PROG/interactive_os.herb.json" "$PROG/interactive_os.herb" \
    "t1 Signal TIMER_EXPIRED"
compare "interactive_os (kill)" \
    "$PROG/interactive_os.herb.json" "$PROG/interactive_os.herb" \
    "k1 Signal KILL_SIG"
compare "interactive_os (block+unblock)" \
    "$PROG/interactive_os.herb.json" "$PROG/interactive_os.herb" \
    "b1 Signal BLOCK_SIG" "u1 Signal UNBLOCK_SIG"

# Process Dimensions
compare "process_dimensions (boot)" \
    "$PROG/process_dimensions.herb.json" "$PROG/process_dimensions.herb"

echo ""
echo "=== Results: $PASS/$TOTAL passed ==="
if [ $FAIL -eq 0 ]; then
    echo "PERFECT EQUIVALENCE. Binary and JSON produce identical states."
fi
exit $FAIL
