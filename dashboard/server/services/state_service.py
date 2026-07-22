"""state_service.py — 파일 시스템 접근 레이어.

핵심 원칙:
  - malformed run-state.json / events.jsonl 이 있어도 전체·목록 응답이 죽지 않는다.
  - 개별 run 파싱은 try/except 로 보호하고, 깨진 run 은 error 로 격리한다.
  - events.jsonl 의 깨진 줄은 skip 하고 정상 줄만 반환한다.
  - 파일은 읽기만 한다. 절대 쓰지 않는다 (이 서버는 읽기전용).
"""
import json
from pathlib import Path
from typing import Optional


def _read_text(path: Path) -> Optional[str]:
    try:
        return path.read_text(errors="replace")
    except OSError:
        return None


def read_run_state(state_dir: Path) -> tuple[Optional[dict], Optional[str]]:
    """run-state.json 을 파싱한다.

    반환: (state_dict | None, error | None)
      - 정상: (dict, None)
      - 파일 없음: (None, None)  → flat 파일 degrade 대상
      - 깨짐: (None, "malformed: ...")  → error 표시
    """
    path = state_dir / "run-state.json"
    if not path.is_file():
        return None, None
    try:
        return json.loads(path.read_text()), None
    except json.JSONDecodeError as exc:
        return None, f"malformed: {exc}"
    except OSError as exc:
        return None, f"io: {exc}"


def read_events(state_dir: Path) -> list[dict]:
    """events.jsonl 을 줄 단위로 파싱. 깨진 줄은 skip 한다."""
    path = state_dir / "events.jsonl"
    text = _read_text(path)
    if text is None:
        return []
    events: list[dict] = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue  # 깨진 줄 skip — 서버는 죽지 않는다
        if isinstance(obj, dict):
            events.append(obj)
    return events


def list_run_dirs(repo_dir: Path) -> list[Path]:
    """repo state 디렉터리 하위의 run 디렉터리들을 mtime 내림차순으로 반환.

    디렉터리가 없거나 읽을 수 없으면 빈 리스트. 절대 예외를 밖으로 던지지 않는다.
    """
    if not repo_dir.is_dir():
        return []
    runs: list[Path] = []
    try:
        for entry in repo_dir.iterdir():
            try:
                if entry.is_dir() and not entry.name.startswith("."):
                    runs.append(entry)
            except OSError:
                continue
    except OSError:
        return []
    try:
        runs.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    except OSError:
        pass
    return runs


def events_path(state_dir: Path) -> Path:
    return state_dir / "events.jsonl"
