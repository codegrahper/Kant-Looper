"""config.py — 경로·포트·repo_hash 규칙.

state 경로 규칙은 kant-loop.sh:84-88 과 100% 동일하게 유지한다.
  STATE_ROOT  = $KANT_STATE_ROOT (기본 ~/.claude/state/nomad-kant-looper)
  repo_hash   = sha256(pwd)[:12]   ← `printf '%s' "$cwd" | shasum -a 256 | cut -c1-12`
  state dir   = STATE_ROOT/<repo_hash>/<run_id>/
"""
import hashlib
import os
from pathlib import Path

VERSION = "0.1"

# 절대 0.0.0.0 에 bind 하지 않는다 (보호 정책).
HOST = "127.0.0.1"
PORT = 7419

DEFAULT_STATE_ROOT = Path.home() / ".claude" / "state" / "nomad-kant-looper"


def state_root() -> Path:
    """KANT_STATE_ROOT 환경변수(없으면 기본값) — kant-loop.sh:44 와 동일."""
    env = os.environ.get("KANT_STATE_ROOT")
    if env:
        return Path(env).expanduser()
    return DEFAULT_STATE_ROOT


def repo_hash(cwd: str | None = None) -> str:
    """현재 작업 저장소 경로의 SHA-256 앞 12자.

    kant-loop.sh:84-88:
        cwd="$(pwd)"
        printf '%s' "$cwd" | shasum -a 256 | cut -c1-12

    python hashlib 로 동일 재현. shasum 은 newline 을 붙이지 않으므로
    `printf '%s'` 와 맞추기 위해 cwd 끝에 newline 을 넣지 않는다.
    """
    if cwd is None:
        cwd = os.getcwd()
    return hashlib.sha256(cwd.encode("utf-8")).hexdigest()[:12]


def repo_state_dir(cwd: str | None = None) -> Path:
    """현재 repo 의 state 디렉터리: STATE_ROOT/<repo_hash>/"""
    return state_root() / repo_hash(cwd)
