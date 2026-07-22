"""main.py — FastAPI 앱 (읽기전용 GET 엔드포인트).

기동:
    uvicorn dashboard.server.main:app --host 127.0.0.1 --port 7419
또는:
    python3 -m dashboard.server.main

보호 정책: 127.0.0.1 에만 bind. 0.0.0.0 금지 (config.HOST 고정).
"""
import asyncio
import json
import os

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse, StreamingResponse

from . import config
from .services import run_service, state_service


def _valid_json_line(line: str) -> bool:
    """events.jsonl 한 줄이 유효한 JSON 객체인지 검사 (깨진 줄은 SSE 에서도 skip)."""
    line = line.strip()
    if not line:
        return False
    try:
        return isinstance(json.loads(line), dict)
    except (json.JSONDecodeError, ValueError):
        return False

app = FastAPI(
    title="Kant Dashboard",
    version=config.VERSION,
    description="읽기전용 로컬 관측 서버 (run-state.json / events.jsonl 기반)",
)


@app.get("/api/health")
def health():
    """200 { status, state_root, version }."""
    return {
        "status": "ok",
        "state_root": str(config.state_root()),
        "version": config.VERSION,
    }


@app.get("/api/runs")
def list_runs():
    """run 목록 (mtime 내림차순). run-state.json 없으면 flat 파일로 degrade."""
    try:
        return run_service.list_runs()
    except Exception as exc:  # 목록은 절대 500 으로 죽지 않는다
        return JSONResponse(
            status_code=500,
            content={"error": "list_failed", "detail": str(exc)},
        )


@app.get("/api/runs/{run_id}")
def run_detail(run_id: str):
    """run-state.json 전체. 없으면 404, 깨졌으면 error 표시(200)."""
    data, err, exists = run_service.get_run(run_id)
    if not exists:
        raise HTTPException(status_code=404, detail="run not found")
    if data is None:
        # run-state.json 없음(degrade) 또는 깨짐(malformed)
        body: dict = {"run_id": run_id}
        if err and err.startswith("malformed"):
            body["error"] = "malformed"
            body["detail"] = err
        else:
            body["error"] = "no_state"
            if err:
                body["detail"] = err
        return body
    return data


@app.get("/api/runs/{run_id}/events")
def run_events(run_id: str):
    """events.jsonl 파싱 배열. 깨진 줄은 skip. run 없으면 404."""
    events = run_service.get_events(run_id)
    if events is None:
        raise HTTPException(status_code=404, detail="run not found")
    return events


@app.get("/api/runs/{run_id}/stream")
async def run_stream(run_id: str):
    """SSE (text/event-stream). events.jsonl 을 tail 하며 새 이벤트를 push."""
    run_dir = run_service.run_dir_for(run_id)
    if run_dir is None:
        raise HTTPException(status_code=404, detail="run not found")
    events_path = state_service.events_path(run_dir)

    async def event_gen():
        offset = 0
        # 초기 backfill: 이미 존재하는 모든 이벤트를 먼저 내보낸다.
        # events.jsonl 의 깨진 줄은 /events 엔드포인트와 동일하게 skip 한다.
        try:
            if events_path.exists():
                with events_path.open("r", encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        if _valid_json_line(line):
                            yield f"data: {line.strip()}\n\n"
                    offset = fh.tell()
        except OSError:
            offset = 0

        # tail 루프 — 파일이 커지면 새 줄을 push.
        max_idle = int(os.environ.get("KANT_SSE_IDLE_ROUNDS", "0") or "0")  # 0 = 무한
        idle = 0
        while True:
            pushed = False
            try:
                size = events_path.stat().st_size if events_path.exists() else 0
            except OSError:
                size = 0
            if size > offset:
                try:
                    with events_path.open("r", encoding="utf-8", errors="replace") as fh:
                        fh.seek(offset)
                        for line in fh:
                            if _valid_json_line(line):
                                yield f"data: {line.strip()}\n\n"
                        offset = fh.tell()
                        pushed = True
                except OSError:
                    pass
            if pushed:
                idle = 0
            else:
                idle += 1
                if max_idle and idle >= max_idle:
                    yield ": done\n\n"
                    return
            await asyncio.sleep(1)

    return StreamingResponse(event_gen(), media_type="text/event-stream")


def main():
    """`python3 -m dashboard.server.main` 진입점. 127.0.0.1 전용 bind."""
    import uvicorn

    # HOST 를 config 로 고정 — CLI 인자나 환경변수로 0.0.0.0 으로 덮을 수 없게 한다.
    uvicorn.run(app, host=config.HOST, port=config.PORT, log_level="info")


if __name__ == "__main__":
    main()
