#!/usr/bin/env python3
"""Hindsight Bank Deduplication Cleanup

Finds and removes duplicate memories from Hindsight banks.
Keeps the longest/most detailed variant when duplicates are found.

Usage:
    python3 dedup_banks.py                  # dry-run on all banks
    python3 dedup_banks.py --apply          # actually delete duplicates
    python3 dedup_banks.py --bank system    # target specific bank
    python3 dedup_banks.py --threshold 0.9  # stricter matching (default 0.85)
"""

import argparse
import json
import re
import subprocess
import sys
from difflib import SequenceMatcher

API_URL = "https://hindsight.thevisualvoid.co.za"
API_KEY = "hsk-6BVUVwfmqC4qs3VKee20-SsWWGylRhPMdv445pZW9wQ"


def api_get(path: str) -> dict:
    result = subprocess.run(
        ["curl", "-s", "-H", f"Authorization: Bearer {API_KEY}", f"{API_URL}{path}"],
        capture_output=True, text=True, timeout=60,
    )
    return json.loads(result.stdout, strict=False)


def api_delete(path: str) -> dict:
    result = subprocess.run(
        ["curl", "-s", "-X", "DELETE", "-H", f"Authorization: Bearer {API_KEY}", f"{API_URL}{path}"],
        capture_output=True, text=True, timeout=60,
    )
    if result.stdout.strip():
        return json.loads(result.stdout, strict=False)
    return {}


def normalise(text: str) -> str:
    t = text.lower().strip()
    t = re.sub(r"\s+", " ", t)
    t = re.sub(r"[|.,;:!?]+$", "", t).strip()
    return t


def find_duplicates(memories: list, threshold: float = 0.85) -> list:
    """Find duplicate memory groups. Returns list of (keep_id, delete_id, delete_text)."""
    norms = []
    for m in memories:
        text = m.get("text", "")
        norms.append((m["id"], text, normalise(text)))

    to_delete = []
    seen = {}  # norm -> (id, text, len)

    for mem_id, text, norm in norms:
        if not norm:
            continue
        matched = False
        for seen_norm, (seen_id, seen_text, seen_len) in list(seen.items()):
            ratio = SequenceMatcher(None, norm, seen_norm).ratio()
            if ratio >= threshold:
                matched = True
                if len(norm) > seen_len:
                    # Current is longer — mark the seen one for deletion
                    to_delete.append((seen_id, seen_text))
                    seen[seen_norm] = (mem_id, text, len(norm))
                else:
                    # Seen is longer — mark current for deletion
                    to_delete.append((mem_id, text))
                break
        if not matched:
            seen[norm] = (mem_id, text, len(norm))

    return to_delete


def get_banks() -> list:
    data = api_get("/v1/default/banks")
    return [b["bank_id"] for b in data.get("banks", [])]


def get_memories(bank_id: str) -> list:
    data = api_get(f"/v1/default/banks/{bank_id}/memories/list?limit=10000")
    return data.get("items", [])


def main():
    parser = argparse.ArgumentParser(description="Deduplicate Hindsight memories")
    parser.add_argument("--apply", action="store_true", help="Actually delete duplicates (default: dry-run)")
    parser.add_argument("--bank", default="", help="Target specific bank (default: all)")
    parser.add_argument("--threshold", type=float, default=0.85, help="Similarity threshold (default: 0.85)")
    args = parser.parse_args()

    banks = [args.bank] if args.bank else get_banks()
    total_deleted = 0
    total_kept = 0
    bank_results = []

    for bank_id in banks:
        try:
            memories = get_memories(bank_id)
        except Exception as e:
            print(f"  SKIP {bank_id}: {e}")
            continue

        if len(memories) < 2:
            continue

        duplicates = find_duplicates(memories, args.threshold)
        kept = len(memories) - len(duplicates)
        total_kept += kept

        if not duplicates:
            bank_results.append((bank_id, len(memories), 0, kept))
            continue

        bank_results.append((bank_id, len(memories), len(duplicates), kept))
        print(f"\n{bank_id}: {len(memories)} memories, {len(duplicates)} duplicates found")

        for del_id, del_text in duplicates:
            preview = del_text[:80].replace("\n", " ")
            if args.apply:
                try:
                    api_delete(f"/v1/default/banks/{bank_id}/memories/{del_id}")
                    print(f"  DELETED: {del_id[:12]}... {preview}")
                    total_deleted += 1
                except Exception as e:
                    print(f"  FAILED:  {del_id[:12]}... {e}")
            else:
                print(f"  WOULD DELETE: {del_id[:12]}... {preview}")
                total_deleted += 1

    # Summary table
    print(f"\n{'='*65}")
    mode = "APPLIED" if args.apply else "DRY RUN"
    print(f"[{mode}] Summary by bank:")
    print(f"{'Bank':25s} {'Total':>6s} {'Dupes':>6s} {'Kept':>6s}")
    print("-" * 50)
    for bank_id, total, dupes, kept in bank_results:
        flag = " *" if dupes > 0 else ""
        print(f"{bank_id:25s} {total:>6d} {dupes:>6d} {kept:>6d}{flag}")
    print("-" * 50)
    print(f"{'TOTAL':25s} {total_deleted+total_kept:>6d} {total_deleted:>6d} {total_kept:>6d}")
    print(f"\n[{mode}] {total_deleted} duplicates {'removed' if args.apply else 'would be removed'}")


if __name__ == "__main__":
    main()
