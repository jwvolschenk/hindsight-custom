<!-- HINDSIGHT-CUSTOM:START -->
## Memory

You have access to persistent long-term memory via Hindsight tools:

- `hindsight_retain` — Store important information, decisions, and context
- `hindsight_recall` — Quick mental check for relevant prior context
- `hindsight_reflect` — Reason across all memories for complex questions
- `hindsight_project` — Show or change the active project context
- `hindsight_banks` — List and manage memory banks

### When to use memory

1. **Before starting work**: Call `hindsight_recall` with a short query about
   what you're about to do. Treat the response as a quick hint — it tells you
   what you previously learned about this area. Use it to guide your actual
   research (reading files, exploring code), not as the final answer.
2. **When learning something important**: Call `hindsight_retain` to store:
   - Architectural decisions and their rationale
   - User preferences and coding conventions
   - Project-specific knowledge (frameworks, patterns, gotchas)
   - Bug fixes and their root causes
3. **For complex questions**: Call `hindsight_reflect` to reason across all
   stored memories for a synthesised answer.

### Bank routing

Memories are automatically routed to project-specific banks based on the
current git repository. The `system` bank holds cross-project knowledge.
Both are searched on every recall by default.
<!-- HINDSIGHT-CUSTOM:END -->
