#!/usr/bin/env python3
import json
import subprocess
import sys
from datetime import datetime


def gh(path, raw=False):
    out = subprocess.run(["gh", "api", path], check=True, capture_output=True, text=True).stdout
    return out if raw else json.loads(out)


def seconds(start, end):
    if not start or not end:
        return None
    parse = lambda s: datetime.fromisoformat(s.replace("Z", "+00:00"))
    return (parse(end) - parse(start)).total_seconds()


def probe(repo, job_id):
    for line in gh(f"repos/{repo}/actions/jobs/{job_id}/logs", raw=True).splitlines():
        marker = line.find("BENCH_PROBE {")
        if marker >= 0:
            return json.loads(line[marker + len("BENCH_PROBE "):])
    return None


def job_record(repo, job):
    workload, side = [part.strip() for part in job["name"].split("/")]
    return {
        "workload": workload,
        "side": side,
        "job_id": job["id"],
        "url": job["html_url"],
        "conclusion": job["conclusion"],
        "runner_name": job["runner_name"],
        "labels": job["labels"],
        "queue_s": seconds(job["created_at"], job["started_at"]),
        "total_s": seconds(job["started_at"], job["completed_at"]),
        "probe": probe(repo, job["id"]),
        "steps": [
            {"name": s["name"], "seconds": seconds(s["started_at"], s["completed_at"])}
            for s in job["steps"]
            if s["conclusion"] == "success"
        ],
    }


def main():
    repo, rounds = sys.argv[1], sys.argv[2:]
    runs = []
    for item in rounds:
        name, run_id = item.split("=", 1)
        run = gh(f"repos/{repo}/actions/runs/{run_id}")
        jobs = gh(f"repos/{repo}/actions/runs/{run_id}/jobs?per_page=100")["jobs"]
        runs.append({
            "round": name,
            "run_id": int(run_id),
            "url": run["html_url"],
            "branch": run["head_branch"],
            "created_at": run["created_at"],
            "jobs": [job_record(repo, job) for job in jobs],
        })
    json.dump({"repository": repo, "date": runs[0]["created_at"][:10], "runs": runs}, sys.stdout, indent=1)
    print()


if __name__ == "__main__":
    main()
