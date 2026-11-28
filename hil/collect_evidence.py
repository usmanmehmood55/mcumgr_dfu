"""Summarize Flutter SMP cases and correlate requested resets with DUT UART."""
import datetime
import json
import re
import sys
from pathlib import Path

EXPECTED_REBOOTS = {
    "corrupt": 1, "interrupted": 1, "fragmented_echo": 0,
    "fragment_failure": 0, "rollback": 2, "success": 2,
    "probe": 0, "upload": 0, "reconnect": 1,
}


def timestamp(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def read_events(path):
    for line in path.read_text(errors="replace").splitlines():
        # Flutter may prefix stdout with the test timestamp and count.
        match = re.search(r'(\{"time":.*\})\s*$', line)
        if match:
            yield json.loads(match[1])


def summarize(report, side, flutter_status):
    event_log = report / "events.jsonl"
    events = list(read_events(event_log if event_log.exists() else report / "flutter.log"))
    uart = (report / "uart.log").read_text(errors="replace").splitlines()
    boots = [
        timestamp(line.split(" ", 1)[0])
        for line in uart
        if "*** Booting MCUboot" in line
    ]
    integrity_refusals = [
        timestamp(line.split(" ", 1)[0])
        for line in uart
        if "Image in the secondary slot is not valid" in line
    ]
    cases = {case: {"outcome": "not_run", "resets": []} for case in EXPECTED_REBOOTS}
    current = None
    opened = None
    for event in events:
        kind = event["event"]
        if kind == "case_start":
            current = cases[event["case"]]
            current["outcome"] = "incomplete"
        elif kind in ("case_pass", "case_fail"):
            current = cases[event["case"]]
            current["outcome"] = "passed" if kind == "case_pass" else "failed"
            if "error" in event:
                current["error"] = event["error"]
        elif current is not None:
            if kind == "reset_requested":
                opened = {"requested": event["time"]}
                current["resets"].append(opened)
            elif kind == "remote_disconnected" and opened is not None:
                opened["remote_disconnect"] = event["time"]
            elif kind == "identity" and opened is not None:
                start = timestamp(opened["requested"])
                end = timestamp(event["time"])
                observed = next((boot for boot in boots if start <= boot <= end), None)
                opened["uart_boot"] = observed.isoformat() if observed else None
                if current is cases["corrupt"]:
                    refusal = next((time for time in integrity_refusals if start <= time <= end), None)
                    opened["uart_image_refusal"] = refusal.isoformat() if refusal else None
                opened = None

    for case, result in cases.items():
        resets = result["resets"]
        has_reboot_evidence = len(resets) == EXPECTED_REBOOTS[case] and all(
            reset.get("remote_disconnect") and reset.get("uart_boot")
            for reset in resets
        )
        if case == "corrupt":
            has_reboot_evidence = has_reboot_evidence and any(
                reset.get("uart_image_refusal") for reset in resets
            )
        if result["outcome"] == "passed" and not has_reboot_evidence:
            result["outcome"] = "incomplete"
    result = {
        "side": side,
        "flutter_exit_status": flutter_status,
        "cases": cases,
        "events": events,
    }
    (report / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    for case, outcome in cases.items():
        print(f"{side} {case}: {outcome['outcome']}")
    return flutter_status == 0 and any(case["outcome"] == "passed" for case in cases.values()) and all(
        case["outcome"] in ("passed", "not_run") for case in cases.values()
    )


if __name__ == "__main__":
    sys.exit(not summarize(Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])))
