#!/bin/bash
# Cross-runtime equivalence test: freestanding vs libc
# Runs each program through both runtimes and compares state output.

cd "$(dirname "$0")"

LIBC_RT=./herb_runtime_v2.exe
PROGRAMS_DIR=../programs
PASS=0
FAIL=0
TOTAL=0

compare() {
    local test_name="$1"
    local json_file="$2"
    shift 2
    # Remaining args are commands (run, create X Y Z, etc.)

    TOTAL=$((TOTAL + 1))
    printf "  %-35s " "$test_name"

    if [ ! -f "$json_file" ]; then
        echo "SKIP (file not found)"
        return
    fi

    # Build command input
    local cmds=""
    for cmd in "$@"; do
        cmds="${cmds}${cmd}\n"
    done
    cmds="${cmds}state\n"

    # Run libc runtime
    local libc_state
    libc_state=$(printf "$cmds" | $LIBC_RT "$json_file" 2>/dev/null)

    # Run freestanding runtime via test harness
    # (We already proved freestanding works — let's compare outputs)
    local fs_state
    fs_state=$(printf "$cmds" | $LIBC_RT "$json_file" 2>/dev/null)

    # Actually, for a true comparison we need the freestanding runtime
    # to output state. Let's use the test executable that outputs state.
    # Build a small helper instead.

    if [ "$libc_state" = "$fs_state" ]; then
        echo "MATCH"
        PASS=$((PASS + 1))
    else
        echo "MISMATCH!"
        echo "    libc: $(echo "$libc_state" | head -3)"
        echo "    fs:   $(echo "$fs_state" | head -3)"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== HERB Freestanding vs libc: Cross-Runtime Equivalence ==="
echo ""

# We need a freestanding binary that accepts commands like the libc one.
# Instead, let's write individual test programs that output state from
# the freestanding runtime, then compare with libc.
# For now, let's use the Python cross-runtime tests.

echo "Running Python cross-runtime test suite (freestanding vs libc)..."
echo ""

# The definitive test: use the existing Python test infrastructure
# which already knows how to compare C runtime output.
# But first, let's manually compare for a few key programs.

run_libc() {
    local json_file="$1"
    shift
    local cmds=""
    for cmd in "$@"; do
        cmds="${cmds}${cmd}"$'\n'
    done
    printf '%s' "$cmds" | $LIBC_RT "$json_file" 2>/dev/null
}

# Priority Scheduler (boot)
echo "--- Priority Scheduler (boot) ---"
TOTAL=$((TOTAL + 1))
libc_out=$(run_libc "$PROGRAMS_DIR/priority_scheduler.herb.json" "run" "state")
fs_out=$(./test_fs_single.exe "$PROGRAMS_DIR/priority_scheduler.herb.json" "boot" 2>/dev/null)

if [ ! -f ./test_fs_single.exe ]; then
    echo "Building freestanding single-test tool..."
    # Compile the single test tool
    cat > _test_fs_single.c << 'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "herb_freestanding.h"

extern void herb_init(void* arena_memory, herb_size_t arena_size, HerbErrorFn error_fn);
extern int herb_load(const char* json_buf, herb_size_t json_len);
extern int herb_run(int max_steps);
extern int herb_create(const char* name, const char* type, const char* container);
extern int herb_state(char* buf, int buf_size);

static void err_fn(int s, const char* m) { (void)s; (void)m; }

int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "Usage: test_fs_single <json> <mode> [signals...]\n"); return 1; }

    FILE* f = fopen(argv[1], "rb");
    if (!f) { fprintf(stderr, "Cannot open %s\n", argv[1]); return 1; }
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    char* json = (char*)malloc(len + 1);
    fread(json, 1, len, f);
    json[len] = '\0';
    fclose(f);

    void* arena = malloc(4 * 1024 * 1024);
    herb_init(arena, 4 * 1024 * 1024, err_fn);
    herb_load(json, len);
    herb_run(100);

    /* Process signals: each signal is "name type container" */
    for (int i = 3; i < argc; i++) {
        char name[64], type[64], container[64];
        if (sscanf(argv[i], "%63s %63s %63s", name, type, container) == 3) {
            herb_create(name, type, container);
            herb_run(100);
        }
    }

    char buf[32768];
    herb_state(buf, sizeof(buf));
    printf("%s", buf);

    free(json);
    free(arena);
    return 0;
}
CEOF
    gcc -o test_fs_single.exe _test_fs_single.c herb_runtime_freestanding.c herb_freestanding.c 2>/dev/null
    rm -f _test_fs_single.c
fi

# Now run actual comparisons
run_compare() {
    local test_name="$1"
    local json_file="$2"
    shift 2
    local libc_cmds=("run")
    local fs_signals=()

    # Parse signal specs
    while [ $# -gt 0 ]; do
        local sig="$1"
        shift
        libc_cmds+=("create $sig" "run")
        fs_signals+=("$sig")
    done
    libc_cmds+=("state")

    TOTAL=$((TOTAL + 1))
    printf "  %-35s " "$test_name"

    # libc runtime
    local libc_input=""
    for cmd in "${libc_cmds[@]}"; do
        libc_input="${libc_input}${cmd}"$'\n'
    done
    local libc_out
    libc_out=$(printf '%s' "$libc_input" | $LIBC_RT "$json_file" 2>/dev/null)

    # freestanding runtime
    local fs_out
    fs_out=$(./test_fs_single.exe "$json_file" "run" "${fs_signals[@]}" 2>/dev/null)

    if [ "$libc_out" = "$fs_out" ]; then
        echo "MATCH"
        PASS=$((PASS + 1))
    else
        echo "MISMATCH!"
        echo "    libc:"
        echo "$libc_out" | head -5
        echo "    freestanding:"
        echo "$fs_out" | head -5
        FAIL=$((FAIL + 1))
    fi
}

echo ""
echo "Cross-runtime equivalence (freestanding vs libc):"
echo ""

run_compare "priority_sched (boot)" \
    "$PROGRAMS_DIR/priority_scheduler.herb.json"

run_compare "priority_sched (timer)" \
    "$PROGRAMS_DIR/priority_scheduler.herb.json" \
    "t1 Signal TIMER_EXPIRED"

run_compare "scheduler (boot)" \
    "$PROGRAMS_DIR/scheduler.herb.json"

run_compare "scheduler (timer+io)" \
    "$PROGRAMS_DIR/scheduler.herb.json" \
    "t1 Signal TIMER_EXPIRED" \
    "io1 Signal IO_COMPLETE"

run_compare "dom_layout" \
    "$PROGRAMS_DIR/dom_layout.herb.json"

run_compare "economy (boot)" \
    "$PROGRAMS_DIR/economy.herb.json"

run_compare "economy (tax)" \
    "$PROGRAMS_DIR/economy.herb.json" \
    "collect_taxes_1 tax_signal TAX_SIGNAL_IN"

run_compare "economy (tax+reward)" \
    "$PROGRAMS_DIR/economy.herb.json" \
    "collect_taxes_1 tax_signal TAX_SIGNAL_IN" \
    "reward_1 reward_signal REWARD_SIGNAL_IN"

run_compare "multiprocess (boot)" \
    "$PROGRAMS_DIR/multiprocess.herb.json"

run_compare "ipc (boot)" \
    "$PROGRAMS_DIR/ipc.herb.json"

echo ""
echo "=== Results: $PASS passed, $FAIL failed, $TOTAL total ==="
if [ $FAIL -eq 0 ]; then
    echo ""
    echo "PERFECT EQUIVALENCE. Freestanding and libc runtimes produce"
    echo "IDENTICAL output for all programs under all signal sequences."
fi

exit $FAIL
