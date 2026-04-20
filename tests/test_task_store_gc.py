from __future__ import annotations

import json
from pathlib import Path

from notion_local_ops_mcp.tasks import TaskStore


def _force_old_updated_at(store: TaskStore, task_id: str) -> None:
    meta_path = store._task_dir(task_id) / "meta.json"  # noqa: SLF001 - test helper
    payload = json.loads(meta_path.read_text(encoding="utf-8"))
    payload["updated_at"] = "2000-01-01T00:00:00+00:00"
    meta_path.write_text(json.dumps(payload), encoding="utf-8")


def test_purge_tasks_removes_old_entries(tmp_path: Path) -> None:
    store = TaskStore(tmp_path / "state")
    created = store.create(task="old", executor="shell", cwd=str(tmp_path))
    task_id = str(created["task_id"])
    _force_old_updated_at(store, task_id)

    result = store.purge_tasks(older_than_seconds=1.0, dry_run=False)

    assert result["success"] is True
    assert result["purged"] == 1
    assert task_id in result["task_ids"]
    assert (tmp_path / "state" / "tasks" / task_id).exists() is False


def test_purge_tasks_dry_run_keeps_files(tmp_path: Path) -> None:
    store = TaskStore(tmp_path / "state")
    created = store.create(task="old", executor="shell", cwd=str(tmp_path))
    task_id = str(created["task_id"])
    _force_old_updated_at(store, task_id)

    result = store.purge_tasks(older_than_seconds=1.0, dry_run=True)

    assert result["success"] is True
    assert result["purged"] == 1
    assert task_id in result["task_ids"]
    assert (tmp_path / "state" / "tasks" / task_id).exists() is True
