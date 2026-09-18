#!/usr/bin/env python3
"""Paired same-evidence evaluation. --live explicitly calls the local model."""
import argparse
import copy
import hashlib
import json
import math
import time
from pathlib import Path

import main as agent


def run(live=False, limit=None):
    base = Path(__file__).parent
    source = agent.strict_json((base / "example-public.json").read_text())
    cases_path = base / "eval_cases.json"
    all_cases = agent.strict_json(cases_path.read_text())
    cases = all_cases if limit is None else all_cases[:limit]
    rows = []
    started = time.monotonic()
    for case in cases:
        job = copy.deepcopy(source)
        job["record"] = case["record"]
        if "candidates" in case:
            job["candidates"] = case["candidates"]
        if "mutate_first" in case:
            job["candidates"][0].update(case["mutate_first"])
            job["candidates"][0]["content_sha256"] = agent.candidate_hash(job["candidates"][0])
        agent.validate(job)
        evidence_before = hashlib.sha256(agent.canonical(job)).hexdigest()
        baseline = agent.baseline(job)
        inferred = agent.review(job) if live else None
        evidence_after = hashlib.sha256(agent.canonical(job)).hexdigest()
        assert evidence_before == evidence_after
        expected = case["expected"]
        def correct(result):
            return result is not None and result["error_code"] is None and all(result[key] == value for key, value in expected.items())
        rows.append({"case_id": case["id"], "case_kind": "authored-case-synthetic-input-not-independent-adjudication",
                     "input_and_evidence_sha256": evidence_before, "evidence_unchanged": True,
                     "expected": expected, "baseline": baseline, "ai": inferred,
                     "baseline_correct": correct(baseline), "ai_correct": correct(inferred) if live else None})
    def counts(which):
        values = [row[which] for row in rows if row[which] is not None]
        times = sorted(v["usage"]["wall_ms"] for v in values)
        return {"attempted": len(values), "correct": sum(row[which + "_correct"] is True for row in rows),
                "operational_failures": sum(v["error_code"] is not None for v in values),
                "reasoned_abstentions": sum(v["status"] == "abstain" and v["error_code"] is None for v in values),
                "proposals": sum(v["status"] == "proposed" for v in values),
                "conflicts": sum(v["status"] == "conflict" for v in values),
                "wall_ms_sum": sum(times), "wall_ms_p95_nearest_rank": times[math.ceil(.95 * len(times)) - 1] if times else None}
    return {"schema_version": 1, "evaluation_kind": "local_model_authored_cases" if live else "deterministic_baseline_only",
            "model_name": agent.MODEL, "required_model_digest": agent.MODEL_DIGEST,
            "prompt_version": "counterparty-review-v1", "prompt_sha256": hashlib.sha256(agent.SYSTEM.encode()).hexdigest(),
            "agent_source_sha256": hashlib.sha256((base / "main.py").read_bytes()).hexdigest(),
            "wall_ms_resolution": 1, "case_file_sha256": hashlib.sha256(cases_path.read_bytes()).hexdigest(),
            "full_case_count": len(all_cases), "selected_case_count": len(cases), "all_failures_retained": True,
            "independently_adjudicated": False, "held_out_quality_claim": False,
            "limitations": ["Authored inputs and status mutations are not a representative operational benchmark.",
                            "No independent reviewer timing or achieved usefulness is measured.",
                            "Unit model doubles and real model runs are separate evidence types.",
                            "Tiny-sample p95 is descriptive only; baseline and model wall time includes all attempted cases."],
            "baseline": counts("baseline"), "ai": counts("ai"),
            "total_wall_ms": round((time.monotonic() - started) * 1000), "cases": rows}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--limit", type=int, choices=range(1, 9))
    args = parser.parse_args()
    print(json.dumps(run(args.live, args.limit), ensure_ascii=False, indent=2))
