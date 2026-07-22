"""schema.py — Pydantic 모델.

모든 필드는 docs/dashboard/STATE-CONTRACT.md 의 스키마를 그대로 반영한다.
run-state.json / events.jsonl 은 다양한 추가 필드를 가질 수 있으므로
모델은 extra 필드를 허용(config=ConfigDict(extra="allow"))한다.
서버 응답은 가능하면 원본 딕셔너리를 그대로 반환하고, 모델은 검증·문서화용으로만 쓴다.
"""
from typing import Any, Optional

from pydantic import BaseModel, ConfigDict, Field


class Agent(BaseModel):
    """STATE-CONTRACT.md §1 agents[] 항목."""
    model_config = ConfigDict(extra="allow")

    role: Optional[str] = None
    tool: Optional[str] = None
    model: Optional[str] = None
    status: Optional[str] = None
    verdict: Optional[str] = None


class Failure(BaseModel):
    """run-state.json failure 객체."""
    model_config = ConfigDict(extra="allow")

    code: Optional[str] = None
    message: Optional[str] = None


class RunState(BaseModel):
    """run-state.json 전체 (STATE-CONTRACT.md §1)."""
    model_config = ConfigDict(extra="allow")

    schema_version: int = 1
    run_id: Optional[str] = None
    repo: Optional[str] = None
    task: Optional[str] = None
    mode: Optional[str] = None
    status: Optional[str] = None
    stage: Optional[str] = None
    started_at: Optional[str] = None
    updated_at: Optional[str] = None
    branch: Optional[str] = None
    worktree: Optional[str] = None
    agents: list[Agent] = Field(default_factory=list)
    result: Optional[str] = None
    failure: Optional[Failure] = None
    commit: Optional[str] = None


class Event(BaseModel):
    """events.jsonl 한 줄 (STATE-CONTRACT.md §2).

    type 별로 verdict / code 같은 추가 필드가 붙을 수 있어 extra 를 허용한다.
    """
    model_config = ConfigDict(extra="allow")

    schema_version: int = 1
    seq: Optional[int] = None
    time: Optional[str] = None
    type: Optional[str] = None
    stage: Optional[str] = None
    agent: Optional[str] = None
    model: Optional[str] = None
    message: Optional[str] = None


class RunSummary(BaseModel):
    """GET /api/runs 항목 (API.md §1 Runs 목록)."""
    model_config = ConfigDict(extra="allow")

    run_id: Optional[str] = None
    task: Optional[str] = None
    status: Optional[str] = None
    stage: Optional[str] = None
    started_at: Optional[str] = None
    updated_at: Optional[str] = None
    error: Optional[str] = None


class HealthResponse(BaseModel):
    """GET /api/health 응답."""
    status: str
    state_root: str
    version: str
