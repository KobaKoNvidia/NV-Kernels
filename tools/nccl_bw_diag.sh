#!/bin/bash
# nccl_bw_diag.sh — NCCL/RoCE bandwidth bottleneck diagnostic
#
# Auto-detects RDMA devices, active ports, GID indices, and available tools.
# No manual configuration needed. Run as root (or sudo).
#
# Usage:
#   sudo ./nccl_bw_diag.sh               # baseline capture (60s)
#   sudo ./nccl_bw_diag.sh --watch       # continuous watch mode (poll every 5s)
#   sudo ./nccl_bw_diag.sh --hotplug     # capture before/after hotplug (waits for keypress)
#   sudo ./nccl_bw_diag.sh --pid <PID>   # attach to running NCCL process
#   sudo ./nccl_bw_diag.sh --selftest    # run ib_send_bw loopback + trace

set -euo pipefail

# ── color output ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; CYN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YEL}[WARN]${NC}  $*"; }
ok()    { echo -e "${GRN}[ OK ]${NC}  $*"; }
err()   { echo -e "${RED}[ERR ]${NC}  $*" >&2; }
hdr()   { echo -e "\n${CYN}══════════════════════════════════════════${NC}"; echo -e "${CYN}  $*${NC}"; echo -e "${CYN}══════════════════════════════════════════${NC}"; }

# ── argument parsing ──────────────────────────────────────────────────────────
MODE="baseline"
TARGET_PID=""
DURATION=60

while [[ $# -gt 0 ]]; do
    case $1 in
        --watch)    MODE="watch" ;;
        --hotplug)  MODE="hotplug" ;;
        --selftest) MODE="selftest" ;;
        --pid)      MODE="attach"; TARGET_PID="$2"; shift ;;
        --duration) DURATION="$2"; shift ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

[[ $EUID -ne 0 ]] && { err "Run as root (sudo $0 $*)"; exit 1; }

OUT=/tmp/nccl_diag_$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT"
info "Output dir: $OUT"

# ── auto-detect: RDMA devices ─────────────────────────────────────────────────
hdr "Auto-detecting RDMA environment"

discover_active_port() {
    # Returns: "<rdma_dev> <port> <netdev> <gid_index>"
    # Prefers: PORT_ACTIVE, highest GID index for RoCEv2/IPv4
    local best_dev="" best_port="" best_netdev="" best_gid=""

    while IFS= read -r line; do
        dev=$(echo "$line" | awk '{print $2}' | cut -d/ -f1)
        port=$(echo "$line" | awk '{print $2}' | cut -d/ -f2)
        state=$(echo "$line" | grep -o 'state [A-Z_]*' | awk '{print $2}')
        netdev=$(echo "$line" | grep -o 'netdev [^ ]*' | awk '{print $2}')

        [[ "$state" != "ACTIVE" ]] && continue
        [[ -z "$netdev" ]] && continue

        # Find best RoCEv2/IPv4 GID index for this port
        gid_dir="/sys/class/infiniband/${dev}/ports/${port}/gid_attrs/types"
        gid_idx=""
        if [[ -d "$gid_dir" ]]; then
            # Prefer RoCEv2 with IPv4 (most compatible with NCCL)
            for f in "$gid_dir"/*; do
                idx=$(basename "$f")
                type=$(cat "$f" 2>/dev/null)
                [[ "$type" == "RoCE v2" ]] && gid_idx="$idx"
            done
            # Fallback: any RoCE v1
            if [[ -z "$gid_idx" ]]; then
                for f in "$gid_dir"/*; do
                    idx=$(basename "$f")
                    type=$(cat "$f" 2>/dev/null)
                    [[ "$type" == "IB/RoCE v1" || "$type" == "RoCE v1" ]] && gid_idx="$idx"
                done
            fi
        fi
        [[ -z "$gid_idx" ]] && gid_idx=0

        best_dev="$dev"; best_port="$port"
        best_netdev="$netdev"; best_gid="$gid_idx"
        break  # take first active port
    done < <(rdma link show 2>/dev/null)

    echo "$best_dev $best_port $best_netdev $best_gid"
}

read -r RDMA_DEV RDMA_PORT NETDEV GID_IDX <<< "$(discover_active_port)"

if [[ -z "$RDMA_DEV" ]]; then
    warn "No active RDMA port found — showing all ports:"
    rdma link show
    err "Cannot proceed without an active RDMA port."
    exit 1
fi

ok "Active RDMA port : ${RDMA_DEV}/${RDMA_PORT}"
ok "Netdev           : ${NETDEV}"
ok "GID index        : ${GID_IDX}"

# ── check / fix MTU ───────────────────────────────────────────────────────────
MTU=$(ip link show "$NETDEV" | grep -o 'mtu [0-9]*' | awk '{print $2}')
info "Current MTU on $NETDEV: $MTU"
if [[ $MTU -lt 4096 ]]; then
    warn "MTU $MTU is too small for RoCE — setting to 9000"
    ip link set "$NETDEV" mtu 9000
    ok "MTU set to 9000"
fi

# ── detect tracing tools ──────────────────────────────────────────────────────
HAS_BPFTRACE=0; HAS_OFFCPUTIME=0; HAS_FUNCLATENCY=0
command -v bpftrace &>/dev/null && HAS_BPFTRACE=1
[[ -x /usr/share/bcc/tools/offcputime ]] && HAS_OFFCPUTIME=1
[[ -x /usr/share/bcc/tools/funclatency ]] && HAS_FUNCLATENCY=1

info "Tools: bpftrace=$HAS_BPFTRACE offcputime=$HAS_OFFCPUTIME funclatency=$HAS_FUNCLATENCY"

# BTF check (required for bpftrace kprobes on module symbols)
if [[ $HAS_BPFTRACE -eq 1 ]] && [[ ! -f /sys/kernel/btf/vmlinux ]]; then
    warn "BTF not found — kprobes may not work. Try: apt install linux-image-\$(uname -r)-dbg"
fi

# ── snapshot: link state + error counters ─────────────────────────────────────
snapshot_counters() {
    local tag=$1
    local snap="$OUT/counters_${tag}.txt"
    {
        echo "=== $(date) — $tag ==="
        echo ""
        echo "--- rdma link ---"
        rdma link show

        echo ""
        echo "--- link speed / state ---"
        ethtool "$NETDEV" 2>/dev/null | grep -E "Speed|Duplex|Link detected|Auto-negot"

        echo ""
        echo "--- ethtool stats (errors / RoCE / pause) ---"
        ethtool -S "$NETDEV" 2>/dev/null | grep -E \
            "rx_out_of_buf|tx_timeout|rx_discards|tx_errors|roce|pause|cnp|ecn|pfc|rx_err|tx_err" || true

        echo ""
        echo "--- RDMA stats ---"
        rdma stat show 2>/dev/null || true

        echo ""
        echo "--- QP states (any in error?) ---"
        ls /sys/class/infiniband/"$RDMA_DEV"/ports/"$RDMA_PORT"/qp_state 2>/dev/null || true

        echo ""
        echo "--- GID table ---"
        show_gids 2>/dev/null | grep "$RDMA_DEV" || true

    } | tee "$snap"
    info "Counters saved: $snap"
}

# ── bpftrace: link event tracer ───────────────────────────────────────────────
# Traces QSFP hotplug events, link up/down, and mlx5 firmware commands.
# These ARE kernel functions — fires on every module/link event.
write_hotplug_bt() {
    cat > "$OUT/hotplug_trace.bt" << 'BTEOF'
/*
 * hotplug_trace.bt — trace mlx5 link/module events
 * Fires on QSFP insert/remove and link state changes.
 */

kprobe:mlx5_port_module_event
{
    printf("[%llu] mlx5_port_module_event: dev=%s\n",
        nsecs / 1000000, comm);
}

kprobe:mlx5e_link_up,
kprobe:mlx5e_link_down
{
    printf("[%llu] %s: netdev event on cpu=%d comm=%s\n",
        nsecs / 1000000, probe, cpu, comm);
}

/* Catch firmware commands — useful to see if NIC re-inits QPs after hotplug */
kprobe:mlx5_cmd_exec
{
    printf("[%llu] mlx5_cmd_exec: opcode=0x%x comm=%s\n",
        nsecs / 1000000, arg2, comm);
}

/* Track QP transitions — stale QPs after hotplug show up here */
kprobe:mlx5_ib_modify_qp
{
    printf("[%llu] mlx5_ib_modify_qp: comm=%s\n",
        nsecs / 1000000, comm);
}

BEGIN { printf("Tracing mlx5 link/hotplug events... Ctrl-C to stop.\n\n"); }
BTEOF
}

# ── bpftrace: RX/TX path latency ─────────────────────────────────────────────
# NOTE: ibv_poll_cq userspace path bypasses the kernel mlx5_ib_poll_cq —
# so we trace the kernel mlx5e RX completion path instead, which measures
# the NIC→software latency even for RDMA traffic that uses kernel-path QPs.
write_rxpath_bt() {
    cat > "$OUT/rxpath_latency.bt" << 'BTEOF'
/*
 * rxpath_latency.bt — mlx5 RX completion latency histogram
 *
 * mlx5e_handle_rx_cqe is called for every kernel-path RX completion.
 * RDMA userspace data bypasses this, but control path and error
 * completions do not — so spikes here = driver problem, not app.
 */

kprobe:mlx5e_handle_rx_cqe
{
    @rx_start[tid] = nsecs;
}

kretprobe:mlx5e_handle_rx_cqe
/@rx_start[tid]/
{
    $us = (nsecs - @rx_start[tid]) / 1000;
    @rx_lat_us = hist($us);
    delete(@rx_start[tid]);
}

/* Track mlx5 send completions — slow = backpressure or congestion */
kprobe:mlx5e_poll_tx_cq
{
    @tx_start[tid] = nsecs;
}

kretprobe:mlx5e_poll_tx_cq
/@tx_start[tid]/
{
    $us = (nsecs - @tx_start[tid]) / 1000;
    @tx_poll_lat_us = hist($us);
    delete(@tx_start[tid]);
}

interval:s:10
{
    printf("\n[%s] === RX completion latency (usecs) ===\n", strftime("%H:%M:%S", nsecs));
    print(@rx_lat_us);
    printf("\n[%s] === TX poll latency (usecs) ===\n", strftime("%H:%M:%S", nsecs));
    print(@tx_poll_lat_us);
    clear(@rx_lat_us);
    clear(@tx_poll_lat_us);
}

END
{
    printf("\n=== Final RX latency histogram ===\n");
    print(@rx_lat_us);
    printf("\n=== Final TX poll latency histogram ===\n");
    print(@tx_poll_lat_us);
}
BTEOF
}

# ── bpftrace: off-CPU for NCCL process ───────────────────────────────────────
write_offcpu_bt() {
    local pid=$1
    cat > "$OUT/offcpu.bt" << BTEOF
/*
 * offcpu.bt — where is PID $pid sleeping?
 * Captures kernel stack whenever the process goes off-CPU.
 * Wide stacks in the flamegraph = time lost waiting on HW/driver.
 */

tracepoint:sched:sched_switch
/args->prev_pid == $pid/
{
    @offcpu_start = nsecs;
    @offcpu_stack = kstack;
}

tracepoint:sched:sched_switch
/args->next_pid == $pid && @offcpu_start/
{
    \$us = (nsecs - @offcpu_start) / 1000;
    @offcpu_us[kstack] = sum(\$us);
    delete(@offcpu_start);
}

interval:s:10
{
    printf("[%s] === Off-CPU stacks (usecs total) ===\n",
        strftime("%H:%M:%S", nsecs));
    print(@offcpu_us);
    clear(@offcpu_us);
}
BTEOF
}

# ── ethtool counter delta function ───────────────────────────────────────────
watch_counters() {
    local interval=${1:-5}
    info "Polling $NETDEV error counters every ${interval}s (Ctrl-C to stop)"
    declare -A prev

    while true; do
        while IFS=: read -r key val; do
            key=$(echo "$key" | xargs)
            val=$(echo "$val" | xargs)
            [[ -z "$key" || -z "$val" ]] && continue
            delta=$(( val - ${prev[$key]:-0} ))
            [[ $delta -gt 0 ]] && printf "  %-45s %+d (total: %d)\n" "$key" "$delta" "$val"
            prev[$key]=$val
        done < <(ethtool -S "$NETDEV" 2>/dev/null | grep -E \
            "rx_out_of_buf|tx_timeout|rx_discards|tx_errors|roce|pause|cnp|ecn|pfc")
        sleep "$interval"
    done
}

# ── selftest: ib_send_bw loopback + bpftrace ─────────────────────────────────
run_selftest() {
    if ! command -v ib_send_bw &>/dev/null; then
        warn "perftest not installed — installing..."
        apt-get install -y perftest &>/dev/null || { err "apt install perftest failed"; exit 1; }
    fi

    # Get local IP for the loopback
    LOCAL_IP=$(ip -4 addr show "$NETDEV" | grep -oP '(?<=inet )\d+\.\d+\.\d+\.\d+' | head -1)
    if [[ -z "$LOCAL_IP" ]]; then
        err "No IPv4 address on $NETDEV — cannot run RoCEv2 loopback"
        exit 1
    fi
    info "Loopback IP: $LOCAL_IP"

    # Write and start bpftrace
    write_rxpath_bt
    bpftrace "$OUT/rxpath_latency.bt" > "$OUT/bpftrace_rxpath.txt" 2>&1 &
    BPFT_PID=$!
    info "bpftrace started (PID $BPFT_PID)"
    sleep 3  # wait for attach

    # Server
    ib_send_bw -d "$RDMA_DEV" -i "$RDMA_PORT" -x "$GID_IDX" \
        --report_gbits -D 20 > "$OUT/ib_server.txt" 2>&1 &
    SRV_PID=$!
    sleep 1

    # Client
    info "Running ib_send_bw loopback (20s)..."
    ib_send_bw -d "$RDMA_DEV" -i "$RDMA_PORT" -x "$GID_IDX" \
        --report_gbits -D 20 "$LOCAL_IP" | tee "$OUT/ib_client.txt"

    wait $SRV_PID 2>/dev/null || true
    sleep 12  # let bpftrace print final interval

    kill $BPFT_PID 2>/dev/null; wait $BPFT_PID 2>/dev/null || true

    hdr "Results"
    echo ""
    echo "--- BW result ---"
    grep -E "Gb/sec|MB/sec|MsgRate" "$OUT/ib_client.txt" || cat "$OUT/ib_client.txt"

    echo ""
    echo "--- bpftrace latency ---"
    cat "$OUT/bpftrace_rxpath.txt"
}

# ── continuous RDMA traffic generator ────────────────────────────────────────
# Starts ib_send_bw in loopback mode and prints BW every second to a log file.
# Also writes a one-line BW summary to $OUT/bw_live.txt on each iteration so
# the main process can tail it for a live BW reading.
start_traffic() {
    if ! command -v ib_send_bw &>/dev/null; then
        warn "perftest not installed — installing..."
        apt-get install -y perftest &>/dev/null || { err "apt install perftest failed"; return 1; }
    fi

    LOCAL_IP=$(ip -4 addr show "$NETDEV" | grep -oP '(?<=inet )\d+\.\d+\.\d+\.\d+' | head -1)
    if [[ -z "$LOCAL_IP" ]]; then
        warn "No IPv4 on $NETDEV — skipping traffic generation (add IP first)"
        return 1
    fi

    info "Starting continuous ib_send_bw loopback on $LOCAL_IP (GID $GID_IDX)"

    # Server: runs indefinitely (-D 0 not supported — use very long duration)
    ib_send_bw -d "$RDMA_DEV" -i "$RDMA_PORT" -x "$GID_IDX" \
        --report_gbits -D 3600 \
        > "$OUT/traffic_server.txt" 2>&1 &
    TRAFFIC_SRV=$!

    sleep 1

    # Client: runs indefinitely, prints a result line every iteration
    # -D 3600 + --output bandwidth writes per-second BW to stdout
    ib_send_bw -d "$RDMA_DEV" -i "$RDMA_PORT" -x "$GID_IDX" \
        --report_gbits -D 3600 --output bandwidth \
        "$LOCAL_IP" > "$OUT/bw_live.txt" 2>&1 &
    TRAFFIC_CLT=$!

    # Give QPs time to connect and reach full speed
    sleep 3

    if ! kill -0 $TRAFFIC_CLT 2>/dev/null; then
        warn "ib_send_bw client exited early — traffic generation failed"
        warn "Server log: $(cat $OUT/traffic_server.txt)"
        return 1
    fi

    ok "Traffic running: server PID=$TRAFFIC_SRV client PID=$TRAFFIC_CLT"
    ok "Live BW log: $OUT/bw_live.txt"
    return 0
}

stop_traffic() {
    kill ${TRAFFIC_SRV:-} ${TRAFFIC_CLT:-} 2>/dev/null || true
    wait ${TRAFFIC_SRV:-} ${TRAFFIC_CLT:-} 2>/dev/null || true
}

# Reads the last BW sample from the live log
sample_bw() {
    tail -1 "$OUT/bw_live.txt" 2>/dev/null | grep -oP '[\d.]+(?=\s+Gb)' | head -1 || echo "N/A"
}

# ── hotplug mode: auto-traffic + capture before + after ──────────────────────
run_hotplug() {
    write_hotplug_bt
    write_rxpath_bt

    hdr "HOTPLUG MODE"
    TRAFFIC_SRV=""; TRAFFIC_CLT=""

    # 1. Start background RDMA traffic (loopback)
    info "Starting background RDMA traffic..."
    if start_traffic; then
        HAVE_TRAFFIC=1
        BW_BEFORE=$(sample_bw)
        ok "Baseline BW: ${BW_BEFORE} Gb/s"
    else
        HAVE_TRAFFIC=0
        warn "Proceeding without generated traffic — attach a running NCCL process instead"
        warn "Tip: start nccl-tests manually then re-run with --pid <PID>"
    fi

    # 2. Snapshot counters before hotplug
    snapshot_counters "before"

    # 3. Start kernel-level traces
    bpftrace "$OUT/hotplug_trace.bt" > "$OUT/hotplug_events.txt" 2>&1 &
    HOTPLUG_BPFT=$!
    bpftrace "$OUT/rxpath_latency.bt" > "$OUT/rxpath.txt" 2>&1 &
    RXPATH_BPFT=$!
    sleep 2  # wait for probes to attach
    info "Traces attached (PIDs: $HOTPLUG_BPFT, $RXPATH_BPFT)"

    # 4. Wait for user to hotplug
    echo ""
    echo -e "${YEL}  Current BW: $(sample_bw) Gb/s${NC}"
    echo -e "${YEL}>>> Hotplug the QSFP cable now, then press ENTER <<<${NC}"
    read -r

    # 5. Immediately snapshot — capture the degraded state
    HOTPLUG_TS=$(date +%s)
    info "Hotplug event at $(date) — capturing..."
    snapshot_counters "after_hotplug"

    # 6. Watch BW for 30s post-hotplug, sampling every 2s
    echo ""
    info "Monitoring BW for 30s post-hotplug..."
    printf "  %-8s  %s\n" "T+sec" "BW (Gb/s)"
    for i in $(seq 2 2 30); do
        sleep 2
        bw=$(sample_bw)
        printf "  %-8s  %s\n" "+${i}s" "$bw"
        echo "T+${i}s: ${bw} Gb/s" >> "$OUT/bw_timeline.txt"
    done

    # 7. Stop traffic and traces
    [[ $HAVE_TRAFFIC -eq 1 ]] && stop_traffic
    kill $HOTPLUG_BPFT $RXPATH_BPFT 2>/dev/null
    wait $HOTPLUG_BPFT $RXPATH_BPFT 2>/dev/null || true

    # 8. Report
    hdr "BW Timeline (before → after hotplug)"
    echo "  Before hotplug : ${BW_BEFORE:-N/A} Gb/s"
    echo ""
    cat "$OUT/bw_timeline.txt" 2>/dev/null || true

    hdr "Hotplug kernel event trace"
    cat "$OUT/hotplug_events.txt"

    hdr "RX/TX path latency (post-hotplug)"
    cat "$OUT/rxpath.txt"

    hdr "Counter delta (before → after hotplug)"
    diff "$OUT/counters_before.txt" "$OUT/counters_after_hotplug.txt" || true

    hdr "Output files"
    ls -lh "$OUT/"
}

# ── attach mode: profile running NCCL process ────────────────────────────────
run_attach() {
    [[ -z "$TARGET_PID" ]] && { err "--pid required for attach mode"; exit 1; }
    [[ ! -d /proc/$TARGET_PID ]] && { err "PID $TARGET_PID not found"; exit 1; }

    COMM=$(cat /proc/$TARGET_PID/comm)
    info "Attaching to PID $TARGET_PID ($COMM) for ${DURATION}s"

    write_offcpu_bt "$TARGET_PID"
    write_rxpath_bt

    bpftrace "$OUT/offcpu.bt" > "$OUT/offcpu_out.txt" 2>&1 &
    OFFCPU_PID=$!
    bpftrace "$OUT/rxpath_latency.bt" > "$OUT/rxpath_out.txt" 2>&1 &
    RXPATH_PID=$!

    snapshot_counters "start"
    sleep "$DURATION"
    snapshot_counters "end"

    kill $OFFCPU_PID $RXPATH_PID 2>/dev/null
    wait $OFFCPU_PID $RXPATH_PID 2>/dev/null || true

    hdr "Off-CPU stacks (where $COMM was sleeping)"
    cat "$OUT/offcpu_out.txt"

    hdr "RX/TX path latency"
    cat "$OUT/rxpath_out.txt"

    hdr "Counter delta"
    diff "$OUT/counters_start.txt" "$OUT/counters_end.txt" || true
}

# ── baseline mode: snapshot + passive trace ───────────────────────────────────
run_baseline() {
    write_rxpath_bt
    write_hotplug_bt

    snapshot_counters "baseline"

    info "Passive trace for ${DURATION}s..."
    bpftrace "$OUT/rxpath_latency.bt" > "$OUT/rxpath_baseline.txt" 2>&1 &
    BPFT_PID=$!

    sleep "$DURATION"

    kill $BPFT_PID 2>/dev/null; wait $BPFT_PID 2>/dev/null || true

    hdr "Baseline RX/TX latency"
    cat "$OUT/rxpath_baseline.txt"

    hdr "Summary"
    snapshot_counters "final"
}

# ── main dispatch ─────────────────────────────────────────────────────────────
case $MODE in
    baseline)  run_baseline ;;
    watch)     watch_counters 5 ;;
    hotplug)   run_hotplug ;;
    selftest)  run_selftest ;;
    attach)    run_attach ;;
esac

info "All output in: $OUT"
