#!/usr/bin/env python3
import json
import sys
from html import escape
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "summary.json"
TARGET = ROOT.parent / "docs" / "assets" / "benchmark.svg"

FONT = "Outfit, Inter, -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"
SURFACE, BORDER, GRID = "#0A0A0A", "#242424", "#1C1C1C"
TEXT, MUTED, FAINT = "#FFFFFF", "#B2B2B2", "#878787"
MAIN, BEFORE = "r2", "r1"
BARS = [
    ("hosted", MAIN, "GitHub-hosted", "#5B8DEF", 1),
    ("self-hosted", MAIN, "Self-hosted", "#00A88A", 1),
    ("self-hosted", BEFORE, "Self-hosted, round 1", "#00A88A", 0.35),
]
ROUNDS = [
    ("cold", "Cold", "empty caches"),
    ("warm", "Warm, all jobs in parallel", "median of 3"),
    ("serial", "Warm, one job at a time", "median of 2"),
]
WORKLOADS = [("node", "Node"), ("go", "Go"), ("rust", "Rust"), ("docker", "Docker")]

WIDTH, LABEL_W, PAD = 1200, 92, 32
PANEL_GAP, BAR_H, BAR_GAP, ROW_GAP = 44, 14, 4, 22
TOP = 132


def text(x, y, value, size=13, fill=TEXT, weight=400, anchor="start"):
    return (f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" font-weight="{weight}" '
            f'fill="{fill}" text-anchor="{anchor}">{escape(value)}</text>')


def nice_max(value):
    step = 50
    return int(-(-value // step) * step)


def render(summary):
    rounds = {name: data["workloads"] for name, data in summary["rounds"].items()}
    date = summary["rounds"][MAIN]["date"]
    peak = max(
        stats["max_s"]
        for side, name, _, _, _ in BARS
        for entry in rounds[name].values()
        for stats in entry.get(side, {}).values()
    )
    scale_max = nice_max(peak)
    panel_w = (WIDTH - 2 * PAD - LABEL_W - PANEL_GAP * (len(ROUNDS) - 1)) / len(ROUNDS)
    row_h = len(BARS) * (BAR_H + BAR_GAP) - BAR_GAP + ROW_GAP
    plot_h = row_h * len(WORKLOADS) - ROW_GAP
    height = TOP + plot_h + 96

    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{height}" '
        f'viewBox="0 0 {WIDTH} {height}" font-family="{escape(FONT)}" role="img">',
        f"<title>Benchmark round 2, {escape(date)}: job time of GitHub-hosted and "
        "self-hosted runners in seconds, lower is better, with self-hosted round 1 for comparison</title>",
        f'<rect x="0.5" y="0.5" width="{WIDTH - 1}" height="{height - 1}" rx="16" fill="{SURFACE}" stroke="{BORDER}"/>',
        text(PAD, 46, "Job time in seconds, lower is better", 20, TEXT, 700),
        text(PAD, 70, f"Round 2, measured {date} on 2 vCPU per job. Self-hosted: one 6-core Ryzen 5 PRO 4650G "
             "shared by 4 runners. Faded: self-hosted in round 1, before the cache fixes.", 13, MUTED),
    ]

    legend_x = PAD
    for _, _, label, color, opacity in BARS:
        out.append(f'<rect x="{legend_x}" y="86" width="12" height="12" rx="3" fill="{color}" fill-opacity="{opacity}"/>')
        out.append(text(legend_x + 18, 97, label, 13, MUTED))
        legend_x += 18 + len(label) * 7.5 + 24

    for index, (round_key, title, note) in enumerate(ROUNDS):
        x0 = PAD + LABEL_W + index * (panel_w + PANEL_GAP)
        out.append(text(x0, TOP - 4, title, 13, TEXT, 600))
        out.append(text(x0 + panel_w, TOP - 4, note, 11, FAINT, 400, "end"))
        for tick in range(0, scale_max + 1, 100):
            tx = x0 + panel_w * tick / scale_max
            out.append(f'<line x1="{tx:.1f}" y1="{TOP + 8}" x2="{tx:.1f}" y2="{TOP + 8 + plot_h}" stroke="{GRID}"/>')
            out.append(text(tx, TOP + plot_h + 26, f"{tick} s", 11, FAINT, 400, "middle"))

        for row, (workload, _) in enumerate(WORKLOADS):
            for slot, (side, name, label, color, opacity) in enumerate(BARS):
                y = TOP + 8 + row * row_h + slot * (BAR_H + BAR_GAP)
                stats = rounds[name].get(workload, {}).get(side, {}).get(round_key)
                if not stats:
                    out.append(text(x0 + 4, y + BAR_H - 3, "failed, see notes", 11, FAINT))
                    continue
                w = max(panel_w * stats["median_s"] / scale_max, 2)
                tip = (f"{label}, {workload}, {round_key}: median {stats['median_s']:g} s "
                       f"(min {stats['min_s']:g}, max {stats['max_s']:g}, n={stats['n']})")
                out.append(f'<rect x="{x0:.1f}" y="{y:.1f}" width="{w:.1f}" height="{BAR_H}" rx="4" '
                           f'fill="{color}" fill-opacity="{opacity}"><title>{escape(tip)}</title></rect>')
                if stats["n"] > 1:
                    lo = x0 + panel_w * stats["min_s"] / scale_max
                    hi = x0 + panel_w * stats["max_s"] / scale_max
                    mid = y + BAR_H / 2
                    out.append(f'<line x1="{lo:.1f}" y1="{mid:.1f}" x2="{hi:.1f}" y2="{mid:.1f}" '
                               f'stroke="{TEXT}" stroke-opacity="{0.55 * opacity:.2f}" stroke-width="2"/>')
                label_x = max(x0 + w, x0 + panel_w * stats["max_s"] / scale_max) + 6
                out.append(text(label_x, y + BAR_H - 2.5, f"{stats['median_s']:g}", 11, MUTED if opacity == 1 else FAINT))

    for row, (_, name) in enumerate(WORKLOADS):
        y = TOP + 8 + row * row_h + (len(BARS) * (BAR_H + BAR_GAP) - BAR_GAP) / 2 + 5
        out.append(text(PAD, y, name, 14, TEXT, 600))

    out.append(text(PAD, height - 26, "Bars: median. Thin line: min to max. Source: benchmarks/summary.json, "
                    "generated by benchmarks/chart.py.", 11, FAINT))
    out.append("</svg>")
    return "\n".join(out) + "\n"


def main():
    source = Path(sys.argv[1]) if len(sys.argv) > 1 else SOURCE
    target = Path(sys.argv[2]) if len(sys.argv) > 2 else TARGET
    target.write_text(render(json.loads(source.read_text())))


if __name__ == "__main__":
    main()
