/**
 * Hindsight Custom — OpenCode Plugin
 *
 * Project-aware long-term memory for OpenCode agents.
 * Uses the same project detection logic as the MCP server and Hermes plugin
 * to ensure conformity across all agent integrations.
 *
 * Registers:
 *   - Tools: hindsight_retain, hindsight_recall, hindsight_reflect
 *   - Hooks: auto-retain on session.idle, memory injection on session.created
 *
 * @example
 * ```json
 * // opencode.json (project-level)
 * { "plugin": ["file:./path/to/hindsight-custom/integrations/opencode"] }
 *
 * // opencode.json (global ~)
 * { "plugin": ["file:~/.config/hindsight-custom/opencode-plugin"] }
 * ```
 */

import type { Plugin } from "@opencode-ai/plugin";
import { tool } from "@opencode-ai/plugin/tool";
import { HindsightClient } from "./client.js";
import { detectProject, SHARED_BANK } from "./project.js";

// ── Config ──────────────────────────────────────────────────────────────────

interface PluginConfig {
    apiUrl: string;
    apiKey: string;
    budget: string;
    searchShared: boolean;
    retainContext: string;
    recallMaxTokens: number;
}

function loadConfig(): PluginConfig {
    return {
        apiUrl: process.env.HINDSIGHT_API_URL || "https://api.hindsight.vectorize.io",
        apiKey: process.env.HINDSIGHT_API_KEY || "",
        budget: process.env.HINDSIGHT_BUDGET || "mid",
        searchShared: process.env.HINDSIGHT_SEARCH_SHARED !== "false",
        retainContext: process.env.HINDSIGHT_RETAIN_CONTEXT || "opencode session",
        recallMaxTokens: parseInt(process.env.HINDSIGHT_RECALL_MAX_TOKENS || "4096", 10),
    };
}

// ── Plugin ──────────────────────────────────────────────────────────────────

const HindsightPlugin: Plugin = async (input, _options) => {
    const config = loadConfig();
    const client = new HindsightClient(config);

    // Detect project from working directory
    const projectBank = detectProject(input.directory);
    await client.ensureBank(projectBank);

    // ── Tools ───────────────────────────────────────────────────────────────

    const hindsight_retain = tool({
        description:
            "Store information in long-term memory. Use this to remember important facts, " +
            "user preferences, project context, decisions, and anything worth recalling in " +
            "future sessions. Memories are automatically routed to the current project's bank.",
        args: {
            content: tool.schema.string().describe("The information to remember."),
            context: tool.schema.string().optional().describe("Short label (e.g. 'project decision')."),
            bank: tool.schema.string().optional().describe("Override bank (default: project bank). Use 'system' for cross-project."),
        },
        async execute(args) {
            const bank = args.bank || projectBank;
            await client.retain(bank, args.content, {
                context: args.context || config.retainContext,
            });
            return `Memory stored in bank '${bank}'.`;
        },
    });

    const hindsight_recall = tool({
        description:
            "Search long-term memory. Returns memories ranked by relevance. " +
            "Searches both the current project bank and the shared system bank by default.",
        args: {
            query: tool.schema.string().describe("What to search for."),
            bank: tool.schema.string().optional().describe("Override bank (default: project + system)."),
        },
        async execute(args) {
            const results: string[] = [];

            if (args.bank) {
                const resp = await client.recall(args.bank, args.query, { maxTokens: config.recallMaxTokens });
                if (resp.results?.length) {
                    results.push(resp.results.filter(r => r.text).map(r => `- ${r.text}`).join("\n"));
                }
            } else {
                // Search project bank
                const resp = await client.recall(projectBank, args.query, { maxTokens: config.recallMaxTokens });
                if (resp.results?.length) {
                    results.push(`[Project: ${projectBank}]\n${resp.results.filter(r => r.text).map(r => `- ${r.text}`).join("\n")}`);
                }
                // Search shared bank
                if (config.searchShared && projectBank !== SHARED_BANK) {
                    const resp2 = await client.recall(SHARED_BANK, args.query, { maxTokens: config.recallMaxTokens });
                    if (resp2.results?.length) {
                        results.push(`[Shared]\n${resp2.results.filter(r => r.text).map(r => `- ${r.text}`).join("\n")}`);
                    }
                }
            }

            return results.length ? results.join("\n\n") : "No relevant memories found.";
        },
    });

    const hindsight_reflect = tool({
        description:
            "Synthesise a reasoned answer from long-term memories. Unlike recall, " +
            "this reasons across all stored memories to produce a coherent response.",
        args: {
            query: tool.schema.string().describe("The question to reflect on."),
            bank: tool.schema.string().optional().describe("Override bank (default: project bank)."),
        },
        async execute(args) {
            const bank = args.bank || projectBank;
            const resp = await client.reflect(bank, args.query);
            return resp.text || "No relevant memories found.";
        },
    });

    // ── Hooks ───────────────────────────────────────────────────────────────

    // Track state across sessions
    let turnCount = 0;
    let lastRecalledSession: string | null = null;

    return {
        tool: {
            hindsight_retain,
            hindsight_recall,
            hindsight_reflect,
        },

        // Auto-inject memories into system prompt on first message
        "system.transform": async (input: { sessionID?: string }) => {
            const sessionId = input.sessionID || "default";
            if (lastRecalledSession === sessionId) return { system: [] };
            lastRecalledSession = sessionId;

            try {
                const resp = await client.recall(projectBank, "project context and key decisions", {
                    maxTokens: config.recallMaxTokens,
                });
                const results = resp.results || [];
                if (!results.length) return { system: [] };

                const memories = results
                    .filter(r => r.text)
                    .map(r => `- ${r.text}`)
                    .join("\n");

                return {
                    system: [
                        `# Hindsight Memory (project: ${projectBank})`,
                        "Use this context from prior sessions:",
                        memories,
                    ],
                };
            } catch {
                return { system: [] };
            }
        },

        // Auto-retain when session becomes idle
        "session.idle": async () => {
            turnCount++;
            // Auto-retain every 3 turns
            if (turnCount % 3 !== 0) return;

            try {
                await client.retain(projectBank, `Session activity: ${turnCount} turns completed`, {
                    context: config.retainContext,
                    tags: ["auto-retain", "opencode"],
                });
            } catch {
                // Silent failure
            }
        },
    };
};

export default HindsightPlugin;
