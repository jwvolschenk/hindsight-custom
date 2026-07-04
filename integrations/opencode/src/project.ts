/**
 * Project detection: CWD → git root → bank name.
 *
 * Same logic as core/project.py — ensures conformity across all agents.
 * - Inside a git repo → bank is the sanitised repo directory name
 * - Inside $HOME git repo → falls through to 'system'
 * - Outside a git repo → 'system'
 */

import { resolve, basename, dirname, join } from "node:path";
import { existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";

export const SHARED_BANK = "system";

/**
 * Derive a project name from a directory by walking up to find .git.
 */
export function detectProject(directory: string): string {
    const resolved = resolve(directory);
    const home = resolve(homedir());

    let current = resolved;
    while (true) {
        if (existsSync(join(current, ".git"))) {
            // Skip if git root is $HOME (dotfiles repo)
            if (current === home) {
                const parent = dirname(current);
                if (parent === current) break;
                current = parent;
                continue;
            }
            return sanitise(basename(current));
        }
        const parent = dirname(current);
        if (parent === current) break;
        current = parent;
    }

    return SHARED_BANK;
}

/**
 * Resolve the main worktree root for a directory inside a git repository.
 * All linked worktrees of the same repo share one memory bank.
 */
export function getGitProjectRoot(directory: string): string | null {
    if (!directory) return null;
    try {
        const commonDir = execFileSync(
            "git",
            ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            { cwd: directory, encoding: "utf-8", stdio: ["ignore", "pipe", "ignore"], timeout: 1000 }
        ).trim();
        if (!commonDir) return null;
        return dirname(commonDir);
    } catch {
        return null;
    }
}

/**
 * Sanitise a string for use as a bank ID.
 */
export function sanitise(value: string): string {
    if (!value) return "";
    let out = "";
    let prevDash = false;
    for (const ch of value) {
        if (/[a-zA-Z0-9\-_]/.test(ch)) {
            out += ch;
            prevDash = false;
        } else if (!prevDash) {
            out += "-";
            prevDash = true;
        }
    }
    return out.replace(/^[-_]+|[-_]+$/g, "").toLowerCase();
}
