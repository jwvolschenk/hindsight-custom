"""Hindsight client wrapper with project-aware bank routing.

Wraps the hindsight_client library to add:
- Automatic project detection from CWD
- Bank routing (project bank + shared system bank)
- Bank auto-creation
- Async support via a background event loop
"""

from __future__ import annotations

import asyncio
import logging
import threading
from pathlib import Path
from typing import Any, Dict, List, Optional

from core.config import Config
from core.project import SHARED_BANK, detect_project, resolve_working_dir

logger = logging.getLogger(__name__)


class HindsightClient:
    """Hindsight API client with automatic project-based bank routing."""

    def __init__(self, config: Config):
        self._config = config
        self._client = None
        self._project: str = ""
        self._project_bank: str = ""

        # Async event loop (shared, background thread)
        self._loop: asyncio.AbstractEventLoop | None = None
        self._loop_thread: threading.Thread | None = None
        self._loop_lock = threading.Lock()

    @property
    def project(self) -> str:
        return self._project

    @property
    def project_bank(self) -> str:
        return self._project_bank

    @property
    def shared_bank(self) -> str:
        return SHARED_BANK

    def connect(self, cwd: Path | None = None) -> None:
        """Detect project and initialise the Hindsight API client.

        Args:
            cwd: Working directory for project detection. Defaults to os.getcwd().
        """
        self._project = detect_project(cwd)
        self._project_bank = self._project
        self._client = self._make_client()
        self._ensure_bank(self._project_bank)

        logger.info(
            "HindsightClient connected: project=%s, bank=%s, shared=%s",
            self._project,
            self._project_bank,
            SHARED_BANK,
        )

    def set_project(self, project: str) -> str:
        """Override the active project. Returns the new bank name."""
        from core.project import sanitise

        self._project = sanitise(project)
        self._project_bank = self._project
        self._ensure_bank(self._project_bank)
        return self._project_bank

    # -- Core operations ------------------------------------------------------

    def retain(
        self,
        content: str,
        *,
        bank: str = "",
        context: str | None = None,
        tags: list[str] | None = None,
        entities: list[dict[str, str]] | None = None,
        document_id: str | None = None,
        metadata: dict | None = None,
        retain_async: bool = True,
    ) -> dict:
        """Store a memory in the specified bank (default: project bank)."""
        target = bank or self._project_bank
        item: Dict[str, Any] = {"content": content}
        if context:
            item["context"] = context
        if tags:
            item["tags"] = tags
        if entities:
            item["entities"] = entities
        if metadata:
            item["metadata"] = metadata

        try:
            self._run_async(
                self._client.aretain_batch(
                    bank_id=target,
                    items=[item],
                    document_id=document_id,
                    retain_async=retain_async,
                ),
                timeout=self._config.timeout,
            )
            return {"result": f"Memory stored in bank '{target}'."}
        except Exception as e:
            logger.warning("Retain failed: %s", e)
            return {"error": f"Failed to store memory: {e}"}

    def recall(
        self,
        query: str,
        *,
        bank: str = "",
    ) -> dict:
        """Search memories. Default: search project bank + shared bank."""
        try:
            results = []

            if bank:
                # Search specific bank
                resp = self._call_recall(bank, query)
                if resp:
                    results.append(resp)
            else:
                # Search project bank
                resp = self._call_recall(self._project_bank, query)
                if resp:
                    results.append(f"[Project: {self._project}]\n{resp}")

                # Search shared bank (if different from project)
                if self._config.search_shared and self._project_bank != SHARED_BANK:
                    resp = self._call_recall(SHARED_BANK, query)
                    if resp:
                        results.append(f"[Shared]\n{resp}")

            if results:
                return {"result": "\n\n".join(results)}
            return {"result": "No relevant memories found."}
        except Exception as e:
            logger.warning("Recall failed: %s", e)
            return {"error": f"Failed to search memory: {e}"}

    def reflect(
        self,
        query: str,
        *,
        bank: str = "",
    ) -> dict:
        """Reason across memories for a coherent answer."""
        target = bank or self._project_bank
        try:
            resp = self._run_async(
                self._client.areflect(
                    bank_id=target,
                    query=query,
                    budget=self._config.budget,
                ),
                timeout=self._config.timeout,
            )
            return {"result": resp.text or "No relevant memories found."}
        except Exception as e:
            logger.warning("Reflect failed: %s", e)
            return {"error": f"Failed to reflect: {e}"}

    def list_banks(self) -> dict:
        """List all banks."""
        try:
            resp = self._client.banks.list_banks()
            banks = []
            items = resp.banks if hasattr(resp, "banks") else (resp if isinstance(resp, list) else [])
            for b in items:
                banks.append({
                    "bank_id": b.bank_id if hasattr(b, "bank_id") else str(b.get("bank_id", "")),
                    "name": b.name if hasattr(b, "name") else str(b.get("name", "")),
                    "fact_count": b.fact_count if hasattr(b, "fact_count") else b.get("fact_count", 0),
                })
            return {
                "banks": banks,
                "active_project": self._project,
                "active_bank": self._project_bank,
            }
        except Exception as e:
            return {"error": str(e)}

    def create_bank(self, bank_id: str, name: str = "") -> dict:
        """Create a new bank."""
        try:
            self._run_async(
                self._client.acreate_bank(bank_id=bank_id, name=name or bank_id),
                timeout=10,
            )
            return {"result": f"Bank '{bank_id}' created."}
        except Exception as e:
            return {"error": str(e)}

    def delete_bank(self, bank_id: str) -> dict:
        """Delete a bank."""
        try:
            self._run_async(self._client.adelete_bank(bank_id), timeout=10)
            return {"result": f"Bank '{bank_id}' deleted."}
        except Exception as e:
            return {"error": str(e)}

    def bank_stats(self, bank_id: str = "") -> dict:
        """Get bank statistics."""
        target = bank_id or self._project_bank
        try:
            resp = self._run_async(self._client.aget_bank_config(target), timeout=10)
            return {"bank_id": target, "config": str(resp)[:500]}
        except Exception as e:
            return {"error": str(e)}

    def project_info(self) -> dict:
        """Return current project routing info."""
        return {
            "project": self._project,
            "project_bank": self._project_bank,
            "shared_bank": SHARED_BANK,
            "cwd": str(resolve_working_dir()),
            "search_shared": self._config.search_shared,
        }

    # -- Internal helpers -----------------------------------------------------

    def _make_client(self):
        """Create a Hindsight API client."""
        from hindsight_client import Hindsight

        return Hindsight(base_url=self._config.api_url, api_key=self._config.api_key)

    def _ensure_bank(self, bank_id: str) -> None:
        """Create the bank if it doesn't exist."""
        try:
            self._run_async(self._client.aget_bank_config(bank_id), timeout=10)
            logger.debug("Bank %s already exists", bank_id)
        except Exception:
            try:
                self._run_async(
                    self._client.acreate_bank(bank_id=bank_id, name=bank_id),
                    timeout=10,
                )
                logger.info("Created bank: %s", bank_id)
            except Exception as e:
                logger.debug("Bank %s creation note: %s", bank_id, e)

    def _call_recall(self, bank_id: str, query: str) -> str:
        """Call recall on a bank and return formatted results."""
        try:
            resp = self._run_async(
                self._client.arecall(
                    bank_id=bank_id,
                    query=query,
                    budget=self._config.budget,
                    max_tokens=self._config.recall_max_tokens,
                ),
                timeout=self._config.timeout,
            )
            if resp.results:
                return "\n".join(f"- {r.text}" for r in resp.results if r.text)
        except Exception as e:
            logger.debug("Recall failed for bank %s: %s", bank_id, e)
        return ""

    # -- Async event loop -----------------------------------------------------

    def _get_loop(self) -> asyncio.AbstractEventLoop:
        """Get or create a background event loop."""
        with self._loop_lock:
            if self._loop is not None and self._loop.is_running():
                return self._loop
            self._loop = asyncio.new_event_loop()

            def _run():
                asyncio.set_event_loop(self._loop)
                self._loop.run_forever()

            self._loop_thread = threading.Thread(
                target=_run, daemon=True, name="hindsight-loop"
            )
            self._loop_thread.start()
            return self._loop

    def _run_async(self, coro, timeout: float = 120):
        """Schedule coro on the background loop and block until done."""
        loop = self._get_loop()
        future = asyncio.run_coroutine_threadsafe(coro, loop)
        return future.result(timeout=timeout)

    def shutdown(self) -> None:
        """Clean up the event loop."""
        if self._loop and self._loop.is_running():
            self._loop.call_soon_threadsafe(self._loop.stop)
