/**
 * Hindsight API client for OpenCode plugin.
 *
 * Uses the same API paths as the Python hindsight_client SDK:
 *   - Recall:  POST /v1/default/banks/{bank_id}/memories/recall
 *   - Retain:  POST /v1/default/banks/{bank_id}/memories
 *   - Reflect: POST /v1/default/banks/{bank_id}/reflect
 *   - Bank:    GET  /v1/default/banks/{bank_id}
 */

export interface HindsightConfig {
    apiUrl: string;
    apiKey: string;
    budget: string;
    searchShared: boolean;
    recallMaxTokens: number;
}

export interface RecallResult {
    text?: string;
    [key: string]: unknown;
}

export interface RecallResponse {
    results?: RecallResult[];
    [key: string]: unknown;
}

export interface ReflectResponse {
    text?: string;
    [key: string]: unknown;
}

export class HindsightClient {
    private apiUrl: string;
    private apiKey: string;
    private budget: string;

    constructor(config: HindsightConfig) {
        this.apiUrl = config.apiUrl.replace(/\/$/, "");
        this.apiKey = config.apiKey;
        this.budget = config.budget || "mid";
    }

    async retain(bankId: string, content: string, options?: {
        context?: string;
        tags?: string[];
        metadata?: Record<string, string>;
    }): Promise<void> {
        const body = {
            items: [{ content, context: options?.context, tags: options?.tags, metadata: options?.metadata }],
        };
        await this.post(`/v1/default/banks/${encodeURIComponent(bankId)}/memories`, body);
    }

    async recall(bankId: string, query: string, options?: {
        budget?: string;
        maxTokens?: number;
    }): Promise<RecallResponse> {
        const body = {
            query,
            budget: options?.budget || this.budget,
            max_tokens: options?.maxTokens || 4096,
        };
        return this.post(`/v1/default/banks/${encodeURIComponent(bankId)}/memories/recall`, body) as Promise<RecallResponse>;
    }

    async reflect(bankId: string, query: string): Promise<ReflectResponse> {
        const body = {
            query,
            budget: this.budget,
        };
        return this.post(`/v1/default/banks/${encodeURIComponent(bankId)}/reflect`, body) as Promise<ReflectResponse>;
    }

    async ensureBank(bankId: string): Promise<void> {
        try {
            await this.get(`/v1/default/banks/${encodeURIComponent(bankId)}`);
        } catch {
            try {
                await this.post("/v1/default/banks", { bank_id: bankId, name: bankId });
            } catch {
                // Bank may already exist
            }
        }
    }

    private async get(path: string): Promise<unknown> {
        const resp = await fetch(`${this.apiUrl}${path}`, {
            headers: this.headers(),
        });
        if (!resp.ok) throw new Error(`GET ${path}: ${resp.status}`);
        return resp.json();
    }

    private async post(path: string, body: unknown): Promise<unknown> {
        const resp = await fetch(`${this.apiUrl}${path}`, {
            method: "POST",
            headers: { ...this.headers(), "Content-Type": "application/json" },
            body: JSON.stringify(body),
        });
        if (!resp.ok) throw new Error(`POST ${path}: ${resp.status}`);
        return resp.json();
    }

    private headers(): Record<string, string> {
        const h: Record<string, string> = {};
        if (this.apiKey) h["Authorization"] = `Bearer ${this.apiKey}`;
        return h;
    }
}
