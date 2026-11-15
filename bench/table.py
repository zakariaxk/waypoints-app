#!/usr/bin/env python3
"""Print a markdown table of loadgen JSONL results: bench/table.py FILE..."""
import json
import sys


def ms(v):
    return f"{v:.0f} ms" if v >= 10 else f"{v:.1f} ms"


rows = [json.loads(l) for f in sys.argv[1:] for l in open(f) if l.strip()]
print("| Scenario | Conns | Deliveries/s | B/delivery | p50 | p99 | p99.9 | Gateway memory | KB/conn | Gateway CPU | Notes |")
print("|---|---|---|---|---|---|---|---|---|---|---|")
for r in rows:
    notes = []
    if r.get("stalled"):
        notes.append(f"{r['stalled']} stalled, healthy p99 {ms(r['healthy_p99_ms'])}, "
                     f"{r.get('stalled_closed', 0)} closed" + (f" by {r['stalled_close_s']:.1f} s" if r.get("stalled_close_s") else ""))
    if r.get("storm_dropped"):
        notes.append(f"storm: {r['storm_returned']}/{r['storm_dropped']} back, all live {r.get('storm_all_live_s', 0):.1f} s "
                     f"after the drop (p50 {r.get('storm_p50_live_s', 0):.1f} s)")
    if r.get("cross_node_p99_ms"):
        notes.append(f"cross-node p50/p99 {ms(r['cross_node_p50_ms'])}/{ms(r['cross_node_p99_ms'])}")
    if r.get("errors"):
        notes.append(f"{r['errors']} errors")
    if r.get("sched_lag_max_ms", 0) > 20:
        notes.append(f"timer lag max {r['sched_lag_max_ms']:.0f} ms")
    lat = r["deliveries"] > 0
    print(f"| {r['scenario']} | {r.get('connected', r['clients'])} | {r['deliveries_per_sec']:,.0f} | "
          f"{r['bytes_per_delivery'] if lat else '-'} | {ms(r['p50_ms']) if lat else '-'} | {ms(r['p99_ms']) if lat else '-'} | "
          f"{ms(r['p999_ms']) if lat else '-'} | {r.get('gateway_footprint_mb') or r.get('gateway_rss_mb', 0):.0f} MB | {r.get('kb_per_conn', 0):.1f} | "
          f"{r.get('gateway_cpu_pct', 0):.0f}% | {'; '.join(notes)} |")
