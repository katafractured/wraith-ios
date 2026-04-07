#!/usr/bin/env python3
"""Check Xcode Cloud build status for WraithVPN."""
import jwt, time, requests, sys

KEY_ID     = "8ASCZ4CMK8"
ISSUER_ID  = "cc920828-bbbd-40ca-9135-fb1a5c30dacd"
KEY_PATH   = "/Users/christianflores/.appstoreconnect/private_keys/AuthKey_8ASCZ4CMK8.p8"
PRODUCT_ID = "044EC9AF-C09E-418D-A9DD-0D85E3F55EE1"
WORKFLOWS  = {
    "9524E3E9-4C37-4492-B54A-FCC6FC287E5B": "Deploy",
    "F27DCAD5-F3FE-4D0E-B641-697BD7964F9C": "Default",
    "8C741733-3769-453A-8C0E-85BDEFDFC72E": "Untitled Workflow",
}

with open(KEY_PATH) as f:
    private_key = f.read()

payload = {"iss": ISSUER_ID, "iat": int(time.time()), "exp": int(time.time()) + 1200, "aud": "appstoreconnect-v1"}
token = jwt.encode(payload, private_key, algorithm="ES256", headers={"kid": KEY_ID})
headers = {"Authorization": f"Bearer {token}"}

any_found = False
for wf_id, wf_name in WORKFLOWS.items():
    r = requests.get(
        f"https://api.appstoreconnect.apple.com/v1/ciWorkflows/{wf_id}/buildRuns",
        params={"limit": 5},
        headers=headers,
    )
    if r.status_code != 200:
        print(f"{wf_name}: API error {r.status_code}")
        continue
    runs = r.json().get("data", [])
    if not runs:
        print(f"{wf_name}: no runs yet")
        continue
    print(f"\n── {wf_name} ──")
    any_found = True
    for run in runs:
        a = run["attributes"]
        status   = a.get("completionStatus") or "RUNNING"
        progress = a.get("executionProgress", "")
        commit   = (a.get("sourceCommit") or {}).get("message", "")[:60]
        created  = a.get("createdDate", "")[:16]
        icon = {"SUCCEEDED": "✓", "FAILED": "✗", "CANCELED": "–"}.get(status, "⟳")
        print(f"  {icon} {status:15} {created}  {commit}")
        if progress and status not in ("SUCCEEDED", "FAILED", "CANCELED"):
            print(f"    progress: {progress}")

if not any_found:
    print("\nNo builds found. Xcode Cloud may not have triggered yet.")
    print("Check that workflows are set to trigger on branch push in App Store Connect.")
