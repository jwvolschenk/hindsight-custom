# Hindsight-Custom — Improvement Document

**Date**: 2026-07-06
**Source**: Full agent audit of 26 banks across all repos
**Severity**: 🔴 High | 🟡 Medium | 🟢 Low

---

## Issue 1: Silent Empty Results from Tag Filtering 🔴 HIGH

**Problem**: When an agent calls `hindsight_recall` with an untagged query against a bank that uses strict tag matching, the result is 0 results with no error or hint. The agent interprets this as "bank has no relevant data" and falls back to manual exploration.

**Reproduction**: Set project to `sql`, call `hindsight_recall(query="What databases exist?")` — returns 0 results because the bank's facts are tagged with `["credo","sqlproj","architecture","databases"]` and the default `tags_match=any_strict` requires tag overlap.

**Root cause**: The recall endpoint defaults to `tags_match=any_strict` when the bank has tagged facts. Untagged queries never match.

**Proposed fix**:
1. Default `hindsight_recall` to `tags_match=any` (include untagged memories alongside tagged ones)
2. Keep `tags_match=any_strict` for `hindsight_reflect` (synthesis should be more focused)
3. When recall returns 0 results, include a hint: "No results found. This bank has N tagged memories. Try adding context or calling with broader tags."

**Files affected**: `core/client.py`, `mcp_server/server.py`

---

## Issue 2: Data Duplication in Recall ✅ FIXED

**Problem**: The same fact appeared multiple times in recall results with slightly different phrasing. Example: "RTX 3080 (10GB, bus 08:00.0, sm_86)" appeared 8 times in a single recall of 90 results for the system bank GPU query.

**Impact**: Wastes the agent's context window budget. A 800-char recall budget filled with duplicates provides less useful information than 800 chars of unique facts.

**Root cause**: Facts are retained from multiple sessions without deduplication. The same information gets stored as world, experience, and observation types with slightly different wording.

**Fix applied** (2026-07-06):
1. Added `recall_deduplicate: bool = True` config option (default ON)
2. `_call_recall()` deduplicates within each bank using `SequenceMatcher` (threshold 0.85)
3. `recall()` deduplicates across project + shared bank via `_deduplicate_cross_bank()`
4. Normalised comparison: lowercase, collapse whitespace, strip trailing punctuation
5. When near-duplicates found, keeps the longest/most detailed variant

**Config**: Set `recall_deduplicate: false` in `~/.config/hindsight-custom/config.json` to disable.

**Files changed**: `core/client.py`, `core/config.py`

---

## Issue 3: Mental Model Synthesis Timeouts 🟡 MEDIUM

**Problem**: Mental model refresh operations time out after 300 seconds when using a local 12B model. Two llama-cpp-turboquant models timed out and retry once before giving up.

**Impact**: Mental models remain empty or contain "I'm sorry, I cannot provide information..." indefinitely.

**Root cause**: The local LLM (gemma-4-12b-qat) lacks the reasoning depth for complex multi-fact synthesis within 300s. The source queries are too broad for the model's capacity.

**Proposed fix**:
1. Allow per-bank LLM model configuration (use a larger model for synthesis, smaller for extraction)
2. Add a "simplified query" fallback — if the full source_query times out, retry with a shorter version
3. Allow mental model refresh to be queued for off-peak hours (cron-style)
4. Increase default timeout to 600s for mental model operations

**Files affected**: Mental model refresh pipeline, bank config

---

## Issue 4: Stale/Conflicting Facts Not Superseded 🟡 MEDIUM

**Problem**: After the RTX 5060 Ti was installed, the llama-cpp-turboquant bank still had facts saying "plans to add a 5060 Ti" alongside newer facts saying "5060 Ti installed." Both were returned in recall, creating confusion.

**Impact**: Agent gets contradictory information (planned vs installed) and must ask the user to clarify.

**Root cause**: Consolidation doesn't detect temporal contradictions. Old facts aren't marked as superseded when newer facts with overlapping entities are retained.

**Proposed fix**:
1. During consolidation, detect facts with overlapping entities and temporal ordering
2. Mark older facts as `superseded_by` the newer fact
3. Exclude superseded facts from recall by default (add `include_superseded=true` to include them)

**Files affected**: Consolidation engine

---

## Issue 5: MCP Tools Unavailable in Delegated Sessions 🟡 MEDIUM

**Problem**: Subagents spawned via `delegate_task` do NOT have access to `hindsight_project`, `hindsight_recall`, or other Hindsight MCP tools. They must fall back to raw curl against the HTTP API.

**Impact**: Subagents need to know the API URL and auth token, and can't use the intended tool interface. This breaks the "agent-agnostic" design goal.

**Root cause**: MCP server tools are session-scoped and not propagated to delegated subagent sessions.

**Proposed fix**:
1. Ensure MCP tools are available in delegated sessions (propagate MCP connection)
2. Provide a lightweight Python client wrapper that subagents can import
3. Document the curl-based fallback as a supported alternative

**Files affected**: Agent integration layer, MCP server

---

## Issue 6: Empty Mental Models Persist Indefinitely 🟢 LOW

**Problem**: 13 mental models across 6 banks had placeholder content (24-25 chars — just "I'm sorry, I cannot provide...") that persisted from initial creation until manually refreshed.

**Impact**: Agents see unhelpful content instead of useful mental model documents.

**Root cause**: Initial mental model creation failed (likely timeout or model error) and the failed result was persisted. No automatic retry mechanism exists.

**Proposed fix**:
1. Add a health check that detects mental models with content <100 chars
2. Automatically retry failed mental models during off-peak consolidation
3. Don't persist "I'm sorry" responses — treat them as failures

**Files affected**: Mental model refresh pipeline

---

## Issue 7: Bank Template System Undocumented 🟢 LOW

**Problem**: The bank-template-system mental model in hindsight-custom failed to generate content because the bank has no facts about the template API, manifest format, or import/export endpoints.

**Impact**: Agents working on hindsight-custom itself can't learn about the template system from memory.

**Proposed fix**:
1. Retain facts about the bank template API from the OpenAPI spec
2. Add a "self-documenting" mode that auto-generates mental models from the API schema
3. Consider a bootstrap process that retains key API facts when a new bank is created

**Files affected**: Bank creation pipeline, template import

---

## Priority Matrix

| Issue | Severity | Effort | Impact |
|-------|----------|--------|--------|
| Silent empty results | 🔴 HIGH | LOW | HIGH — prevents agents from using banks |
| Data duplication | ✅ FIXED | LOW | HIGH — saves context tokens |
| Synthesis timeouts | 🟡 MEDIUM | HIGH | MEDIUM — blocks mental model generation |
| Stale facts | 🟡 MEDIUM | MEDIUM | MEDIUM — causes agent confusion |
| MCP in subagents | 🟡 MEDIUM | HIGH | MEDIUM — breaks delegation pattern |
| Empty mental models | 🟢 LOW | LOW | LOW — cosmetic issue |
| Template undocumented | 🟢 LOW | LOW | LOW — edge case |

---

## Files to Review

- `core/client.py` — recall default parameters, deduplication
- `mcp_server/server.py` — MCP tool defaults, tag_match handling
- Consolidation engine — conflict detection, superseded facts
- Mental model refresh pipeline — timeout handling, retry logic
- Bank creation pipeline — bootstrap facts, self-documenting
