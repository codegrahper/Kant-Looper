"""run_service.py — run 목록/상세 조합 로직 (API.md §1 매핑).

read_run_state 가 실패(degrade)해도 최소 정보(run_id, task)를 flat 파일에서
복원해 목록에 포함시킨다. 절대 500 으로 죽지 않는다.
"""
import re
from pathlib import Path
from typing import Optional

from ..config import repo_state_dir
from . import state_service


def _read_txt(path: Path) -> Optional[str]:
    try:
        text = path.read_text(errors="replace").strip()
    except OSError:
        return None
    return text if text else None


def _derive_task_from_flat(state_dir: Path) -> Optional[str]:
    """run-state.json 이 없을 때 task.md 첫 줄에서 task 추출 (state_writer.py:199-205 와 동일)."""
    task_md = state_dir / "task.md"
    try:
        first = task_md.read_text(errors="replace").splitlines()[0]
    except (OSError, IndexError):
        return None
    return re.sub(r"^#\s*", "", first).strip() or None


def list_runs() -> list[dict]:
    """GET /api/runs — run 목록 (mtime 내림차순).

    각 항목은 {run_id, task, status, stage, started_at, updated_at} 형태.
    run-state.json 이 없거나 깨지면 flat 파일로 degrade (error 필드 추가).
    """
    repo_dir = repo_state_dir()
    out: list[dict] = []
    for run_dir in state_service.list_run_dirs(repo_dir):
        try:
            data, err = state_service.read_run_state(run_dir)
        except Exception as exc:  # 개별 run 보호 — 목록 전체는 살아있는다
            out.append({
                "run_id": run_dir.name,
                "task": _derive_task_from_flat(run_dir),
                "status": None,
                "stage": None,
                "started_at": None,
                "updated_at": None,
                "error": f"unexpected: {exc}",
            })
            continue

        if data is not None:
            out.append({
                "run_id": data.get("run_id") or run_dir.name,
                "task": data.get("task"),
                "status": data.get("status"),
                "stage": data.get("stage"),
                "started_at": data.get("started_at"),
                "updated_at": data.get("updated_at"),
            })
        else:
            # degrade — run-state.json 없음(not_found) 또는 깨짐(malformed)
            out.append({
                "run_id": _read_txt(run_dir / "run-id.txt") or run_dir.name,
                "task": _derive_task_from_flat(run_dir),
                "status": None,
                "stage": None,
                "started_at": _read_txt(run_dir / "started-at.txt"),
                "updated_at": None,
                **({"error": err} if err else {}),
            })
    return out


def get_run(run_id: str) -> tuple[Optional[dict], Optional[str], bool]:
    """GET /api/runs/{run_id} 용.

    반환: (state | None, error | None, exists)
      - 정상: (dict, None, True)
      - 없음(404): (None, "not_found", False)
      - run-state.json 없음(degrade): (None, None, True)
      - 깨짐: (None, "malformed: ...", True)
    """
    run_dir = repo_state_dir() / run_id
    if not run_dir.is_dir():
        return None, "not_found", False
    try:
        data, err = state_service.read_run_state(run_dir)
    except Exception as exc:
        return None, f"unexpected: {exc}", True
    return data, err, True


def get_events(run_id: str) -> Optional[list[dict]]:
    """GET /api/runs/{run_id}/events 용. run 디렉터리가 없으면 None."""
    run_dir = repo_state_dir() / run_id
    if not run_dir.is_dir():
        return None
    try:
        return state_service.read_events(run_dir)
    except Exception:
        return []


def run_dir_for(run_id: str) -> Optional[Path]:
    run_dir = repo_state_dir() / run_id
    return run_dir if run_dir.is_dir() else None
