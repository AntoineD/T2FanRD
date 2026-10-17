#!/usr/bin/env bash
# Functional test for T2FanRD on a real T2 Mac.
#
#   tests/real-hardware.sh
#
# Builds as you, then re-runs itself with sudo.  Runs the debug build, which
# reads ./t2fand.conf and writes ./t2fand.pid in its working directory, so
# /etc/t2fand.conf is never touched.  The t2fanrd service is stopped for the
# test and started again afterwards (if it was running).
#
# GPU sensor tests use a fake /sys/class/drm, mounted in a private mount
# namespace, so the real GPU is never removed.
#
# The fan spins up to at most 2000 RPM for a few seconds during the test.

set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SELF="$REPO/tests/real-hardware.sh"

# --- Output --------------------------------------------------------------

PASS=0
FAIL=0
pass() { printf '  \e[32mPASS\e[0m %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \e[31mFAIL\e[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
check() { # check "description" command...
    local desc=$1; shift
    if "$@"; then pass "$desc"; else fail "$desc"; fi
}
section() { printf '\n\e[1m== %s\e[0m\n' "$*"; }
die() { printf '\e[31merror:\e[0m %s\n' "$*" >&2; exit 2; }

# Runs a command every 0.2s until it succeeds, for at most $1 seconds.
wait_for() {
    local secs=$1; shift
    local i
    for ((i = 0; i < secs * 5; i++)); do
        "$@" && return 0
        sleep 0.2
    done
    return 1
}

# --- Fan helpers ---------------------------------------------------------

find_fan_dir() {
    local d
    for d in /sys/devices/pci*/*/*/*/APP0001:00 /sys/bus/acpi/devices/APP0001:00; do
        [[ -e $d/fan1_input ]] && { echo "$d"; return 0; }
    done
    return 1
}

fan_count() { local f=("$FAN_DIR"/fan*_input); echo "${#f[@]}"; }

fan_is() { [[ $(cat "$FAN_DIR/fan1_$1") == "$2" ]]; }

# expect_fan "description" secs attribute expected
# Waits up to <secs> seconds for $FAN_DIR/fan1_<attribute> to read <expected>.
# Reports the value seen on failure, and how long it took on success, since
# the SMC can apply changes with a delay.
expect_fan() {
    local desc=$1 secs=$2 start=$SECONDS
    if wait_for "$secs" fan_is "$3" "$4"; then
        local took=$((SECONDS - start))
        if ((took > 0)); then pass "$desc (after ~${took}s)"; else pass "$desc"; fi
    else
        fail "$desc (fan1_$3 = $(cat "$FAN_DIR/fan1_$3") after ${secs}s)"
    fi
}

# Writes ./t2fand.conf with one section per fan.  Extra lines go in each.
write_config() {
    local i n
    n=$(fan_count)
    : >t2fand.conf
    for ((i = 1; i <= n; i++)); do
        {
            echo "[Fan$i]"
            echo "low_temp=60"
            echo "high_temp=90"
            echo "speed_curve=linear"
            echo "always_full_speed=false"
            printf '%s\n' "$@"
            echo
        } >>t2fand.conf
    done
}

# Runs the daemon for $1 seconds (then SIGTERM), output in ./out.log.
# Returns the daemon's exit status.
run_daemon() {
    timeout --preserve-status -s TERM "$1" "$BIN" >out.log 2>&1
}

# Starts a fresh test directory and cds into it.
new_case() {
    local dir="$WORK/$1"
    mkdir -p "$dir" || die "cannot create $dir"
    cd "$dir" || die "cannot cd to $dir"
}

log_has() { grep -qaF -- "$1" out.log; }
log_lacks() { ! grep -qaF -- "$1" out.log; }
gpu_found_twice() { [ "$(grep -cF "Found GPU temperature sensor" out.log)" -ge 2 ]; }

# --- Tests ---------------------------------------------------------------

test_max_speed_override() {
    section "max_speed override"
    new_case max-override
    write_config "max_speed=3600"
    run_daemon 3
    local st=$?
    check "exits cleanly on SIGTERM (status $st)" [ $st -eq 0 ]
    check "config has max_speed: Some(3600)" grep -qzP 'max_speed: Some\(\s*3600,\s*\)' out.log
    check "fan uses max_speed 3600" grep -qxF '    max_speed: 3600,' out.log
    expect_fan "fan handed back to SMC" 5 manual 0
}

test_max_speed_empty() {
    section "empty max_speed falls back to fan1_max"
    new_case max-empty
    local hw_max
    hw_max=$(cat "$FAN_DIR/fan1_max")
    write_config "max_speed="
    run_daemon 3
    local st=$?
    check "exits cleanly (status $st)" [ $st -eq 0 ]
    check "config has max_speed: None" log_has "max_speed: None,"
    check "fan uses fan1_max ($hw_max)" grep -qxF "    max_speed: $hw_max," out.log
}

test_clamp() {
    section "min_speed = max_speed pins the fan"
    new_case clamp
    write_config "min_speed=1500" "max_speed=1500"
    start_daemon
    expect_fan "fan pinned at 1500" 5 output 1500
    expect_fan "fan in manual mode while running" 5 manual 1
    stop_daemon
    check "exits cleanly (status $DAEMON_STATUS)" [ "$DAEMON_STATUS" -eq 0 ]
    expect_fan "fan handed back to SMC" 5 manual 0
}

test_min_above_max() {
    section "min_speed above max_speed is rejected"
    new_case min-above-max
    write_config "min_speed=4000" "max_speed=3600"
    run_daemon 5
    local st=$?
    check "exits with failure (status $st)" [ $st -ne 0 ]
    check "explains the bad range" \
        log_has "Minimum fan speed (4000) is above maximum fan speed (3600)"
    expect_fan "fan left to SMC" 5 manual 0
}

test_invalid_value() {
    section "non-numeric min_speed is rejected"
    new_case min-invalid
    write_config "min_speed=abc"
    run_daemon 5
    local st=$?
    check "exits with failure (status $st)" [ $st -ne 0 ]
    check "names the bad key" log_has "Invalid min_speed in config file"
}

test_real_gpu() {
    section "real GPU sensor found on any card; no status line off a terminal"
    new_case real-gpu
    write_config
    run_daemon 3
    local expected
    expected=$(compgen -G '/sys/class/drm/card*/device/hwmon/hwmon*/temp1_input' | head -n1)
    if [[ -z $expected ]]; then
        fail "no GPU sensor on this machine to compare against"
        return
    fi
    check "logs Found GPU temperature sensor: $expected" \
        log_has "Found GPU temperature sensor: $expected"
    # out.log is a file, not a terminal.
    check "no 'Setting fan speed' in log" log_lacks "Setting fan speed"
    check "no escape codes in log" log_lacks $'\e'
}

test_tty() {
    section "status line on a terminal"
    new_case tty
    write_config
    cat >pty.py <<'EOF'
import os, pty, select, signal, sys, time
binary, secs = sys.argv[1], float(sys.argv[2])
pid, fd = pty.fork()
if pid == 0:
    os.execv(binary, [binary])
out, end, killed = b"", time.time() + secs, False
while True:
    if not killed and time.time() > end:
        os.kill(pid, signal.SIGTERM)
        killed = True
    if select.select([fd], [], [], 0.2)[0]:
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            break
        out += data
_, status = os.waitpid(pid, 0)
sys.stdout.buffer.write(out)
sys.exit(os.waitstatus_to_exitcode(status))
EOF
    python3 -I pty.py "$BIN" 3 >out.log 2>&1
    local st=$?
    check "exits cleanly (status $st)" [ $st -eq 0 ]
    check "shows 'Setting fan speed to N'" grep -qaP 'Setting fan speed to \d+' out.log
    # Text right after the status line must start with the erase sequence,
    # not be glued onto it.
    check "next message is not glued onto the status line" \
        bash -c '! grep -qaP "Setting fan speed to \d+(?!\d|\e\[2K\r)." out.log'
    check "shutdown message erases the status line first" \
        log_has $'\e[2K\rT2 Fan Daemon is shutting down'
}

# Runs inside a private mount namespace (see test_fake_gpu).
fake_gpu_in_namespace() {
    local drm=/sys/class/drm
    mount -t tmpfs t2fanrd-test "$drm" || die "cannot mount tmpfs on $drm"
    # card0 without a sensor, like simpledrm before amdgpu takes over.
    mkdir -p "$drm/card0/device"

    new_case fake-gpu
    write_config "max_speed=2000"
    start_daemon

    check "starts without a GPU sensor" wait_for 5 log_has "No GPU temperature sensor yet"

    local sensor="$drm/card1/device/hwmon/hwmon9/temp1_input"
    mkdir -p "$(dirname "$sensor")"
    echo 30000 >"$sensor"
    check "finds a GPU sensor that appears later, on card1 (<= 10s)" \
        wait_for 15 log_has "Found GPU temperature sensor: $sensor"

    echo garbage >"$sensor"
    check "notices the sensor is lost" \
        wait_for 5 log_has "GPU temperature sensor lost"
    check "keeps running after losing it" kill -0 "$DAEMON"

    # GPU back, and hotter than high_temp: the fan must go to max_speed.
    echo 95000 >"$sensor"
    check "finds the sensor again (<= 10s)" \
        wait_for 15 gpu_found_twice
    expect_fan "hot GPU drives fan to max_speed 2000" 20 output 2000

    stop_daemon
    check "exits cleanly (status $DAEMON_STATUS)" [ "$DAEMON_STATUS" -eq 0 ]
    expect_fan "fan handed back to SMC" 5 manual 0
    echo "$PASS $FAIL" >"$WORK/ns-result"
}

test_fake_gpu() {
    section "GPU sensor appears late, is lost, comes back (fake /sys/class/drm)"
    unshare -m --propagation private "$SELF" --namespace "$BIN" "$WORK"
    local p f
    if read -r p f <"$WORK/ns-result" 2>/dev/null; then
        PASS=$((PASS + p)); FAIL=$((FAIL + f))
    else
        fail "namespace test did not finish"
    fi
}

# --- Daemon lifecycle ----------------------------------------------------

DAEMON=
DAEMON_STATUS=
# Starts the daemon in the background, output in ./out.log.
start_daemon() {
    "$BIN" >out.log 2>&1 &
    DAEMON=$!
}

stop_daemon() {
    [[ -n $DAEMON ]] || return
    kill -TERM "$DAEMON" 2>/dev/null
    wait "$DAEMON"
    DAEMON_STATUS=$?
    DAEMON=
}

# --- Entry points --------------------------------------------------------

as_user() {
    [[ $EUID -ne 0 ]] || die "run as your user, not root (it builds first, then uses sudo)"
    section "build"
    (cd "$REPO" && cargo build && cargo clippy --all-targets -- -D warnings) ||
        die "build or clippy failed"
    exec sudo -- "$SELF" --root "$REPO/target/debug/t2fanrd"
}

as_root() {
    BIN=$1
    [[ $EUID -eq 0 ]] || die "--root needs root"
    [[ -x $BIN ]] || die "no binary at $BIN"
    FAN_DIR=$(find_fan_dir) || die "no T2 fan found (APP0001:00/fan1_input)"
    command -v python3 >/dev/null || die "python3 is needed for the terminal test"

    WORK=$(mktemp -d /tmp/t2fanrd-test.XXXXXX)
    SERVICE_WAS_ACTIVE=false
    if systemctl is-active --quiet t2fanrd; then
        SERVICE_WAS_ACTIVE=true
        echo "Stopping t2fanrd.service for the test"
        systemctl stop t2fanrd
    fi
    if pgrep -x 't2fanrd(-dev)?' >/dev/null; then
        die "a t2fanrd process is still running; stop it first"
    fi

    cleanup() {
        stop_daemon
        echo 0 >"$FAN_DIR/fan1_manual" 2>/dev/null
        if $SERVICE_WAS_ACTIVE; then
            echo "Starting t2fanrd.service again"
            systemctl start t2fanrd
        fi
        if ((FAIL == 0)); then
            rm -rf "$WORK"
        else
            # Readable by whoever ran sudo, not only root.
            [[ -n ${SUDO_USER:-} ]] && chown -R "$SUDO_USER" "$WORK"
            echo "Logs kept in $WORK"
        fi
    }
    trap cleanup EXIT
    trap 'exit 130' INT TERM

    echo "Fan: $FAN_DIR ($(fan_count) fan(s))"
    echo "Binary: $BIN"

    test_max_speed_override
    test_max_speed_empty
    test_clamp
    test_min_above_max
    test_invalid_value
    test_real_gpu
    test_tty
    test_fake_gpu

    printf '\n\e[1m%d passed, %d failed\e[0m\n' "$PASS" "$FAIL"
    ((FAIL == 0))
}

case ${1:-} in
    --root) as_root "$2" ;;
    --namespace)
        BIN=$2 WORK=$3
        FAN_DIR=$(find_fan_dir) || die "no fan"
        trap stop_daemon EXIT
        fake_gpu_in_namespace
        ;;
    "") as_user ;;
    *) die "usage: $0" ;;
esac
