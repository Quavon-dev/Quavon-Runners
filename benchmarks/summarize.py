#!/usr/bin/env python3
import json
import re
import sys
from statistics import median


def stats(values):
    if not values:
        return None
    return {"median_s": median(values), "min_s": min(values), "max_s": max(values), "n": len(values)}


def summarize(results):
    totals, hardware = {}, {}
    for run in results["runs"]:
        kind = re.sub(r"\d+$", "", run["round"])
        for job in run["jobs"]:
            if job["conclusion"] != "success":
                continue
            totals.setdefault(job["workload"], {}).setdefault(job["side"], {}).setdefault(kind, []).append(job["total_s"])
            probe = job["probe"]
            side = hardware.setdefault(job["side"], {"cpu_models": set(), "vcpus": set(), "mem_mb": set(), "cgroup_mem_max": set()})
            side["cpu_models"].add(probe["cpu_model"])
            side["vcpus"].add(probe["gomaxprocs"] or str(probe["nproc"]))
            side["mem_mb"].add(probe["mem_mb"])
            side["cgroup_mem_max"].add(probe["cgroup_mem_max"])

    workloads = {}
    for workload, sides in sorted(totals.items()):
        entry = {side: {kind: stats(values) for kind, values in kinds.items()} for side, kinds in sides.items()}
        entry["speedup"] = {
            kind: round(entry["hosted"][kind]["median_s"] / entry["self-hosted"][kind]["median_s"], 2)
            for kind in entry["hosted"]
            if kind in entry["self-hosted"]
        }
        workloads[workload] = entry

    return {
        "date": results.get("date"),
        "repository": results["repository"],
        "hardware": {side: {key: sorted(values) for key, values in info.items()} for side, info in hardware.items()},
        "workloads": workloads,
    }


def main():
    rounds = {}
    for item in sys.argv[1:]:
        name, path = item.split("=", 1)
        rounds[name] = summarize(json.load(open(path)))
    json.dump({
        "speedup_definition": "hosted median / self-hosted median, above 1 means self-hosted is faster",
        "rounds": rounds,
    }, sys.stdout, indent=1)
    print()


if __name__ == "__main__":
    main()
