#!/usr/bin/env python3
# codex-app-server-client.py — Codex CLI app-server JSON-RPC 클라이언트 (v1)
#
# 표준 라이브러리만 사용. 외부 의존성 없음.
#
# 흐름:
#   1. Codex CLI를 app-server 모드로 실행 (stdin/stdout JSON-RPC)
#   2. initialize → initialized handshake
#   3. thread/start로 새 thread 생성 (또는 thread/resume로 기존 thread 이어가기)
#   4. turn/start로 prompt 전달
#   5. 비동기 이벤트 수신 (thread/started, item/*, turn/completed)
#   6. server-initiated approval 요청 자동 처리 (detached=auto-decline, foreground=queue)
#   7. turn/completed까지 대기 후 thread.id / turn.result 반환
#
# 사용법:
#   # 단발성 호출 (init → thread/start → turn/start → 결과)
#   codex-app-server-client.py run \
#       --cwd /path/to/worktree \
#       --model gpt-5.6-sol \
#       --prompt-file /path/to/prompt.md \
#       --output /path/to/response.txt
#
#   # foreground (interactive approval)
#   codex-app-server-client.py run --foreground ...
#
#   # 환경변수
#   KANT_DETACHED=1 → server-initiated approval 자동 decline
#   KANT_HEARTBEAT_SEC=5 → heartbeat 간격 (기본 5)
#
# 안전:
# - sandbox 파라미터 강제 (readOnly | workspaceWrite)
# - approval_policy 강제 (never | onRequest)
# - </dev/null stdin 차단으로 background hang 방지
# - SIGTERM graceful shutdown

import argparse
import json
import os
import queue
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

# JSON-RPC ID 카운터
_id_counter = 0
_id_lock = threading.Lock()


def next_id() -> int:
    global _id_counter
    with _id_lock:
        _id_counter += 1
        return _id_counter


class CodexAppServer:
    """단일 Codex app-server 프로세스에 대한 클라이언트."""

    def __init__(self, cwd: str, model: str, sandbox: str = "readOnly",
                 approval_policy: str = "never", heartbeat_sec: int = 5):
        self.cwd = cwd
        self.model = model
        self.sandbox = sandbox
        self.approval_policy = approval_policy
        self.heartbeat_sec = heartbeat_sec

        self.proc: subprocess.Popen | None = None
        self.pending: dict[int, queue.Queue] = {}
        self.events: queue.Queue = queue.Queue()
        self.thread_id: str | None = None
        self.last_turn_id: str | None = None
        self.last_message: str | None = None
        self.last_diff: str | None = None
        self.last_usage: dict | None = None
        self._reader_thread: threading.Thread | None = None
        self._heartbeat_thread: threading.Thread | None = None
        self._stopped = False

    # ---------------------------------------------------------------
    # Lifecycle
    # ---------------------------------------------------------------

    def start(self):
        """Codex CLI를 app-server 모드로 시작 + initialize handshake."""
        cmd = [
            "codex", "app-server",
            "--cwd", self.cwd,
            "--model", self.model,
        ]
        # stdin/stdout JSON-RPC, stderr 별도 (log로)
        self.proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=self.cwd,
            text=True,
            bufsize=1,
        )

        self._reader_thread = threading.Thread(
            target=self._reader_loop, daemon=True, name="app-server-reader"
        )
        self._reader_thread.start()

        # initialize → initialized
        self._request("initialize", {
            "clientInfo": {
                "name": "kant_looper",
                "title": "Kant Looper",
                "version": "0.1.0",
            }
        })
        self._notify("initialized", {})

        # heartbeat (필요 시)
        if self.heartbeat_sec > 0:
            self._heartbeat_thread = threading.Thread(
                target=self._heartbeat_loop, daemon=True, name="app-server-heartbeat"
            )
            self._heartbeat_thread.start()

    def stop(self, timeout: float = 5.0):
        """Codex 프로세스 종료. SIGTERM 먼저, SIGKILL fallback."""
        self._stopped = True
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
            except Exception:
                pass

    # ---------------------------------------------------------------
    # JSON-RPC primitives
    # ---------------------------------------------------------------

    def _request(self, method: str, params: dict, timeout: float = 30.0) -> dict:
        """request 전송 → response 대기 (동기)."""
        rid = next_id()
        msg = {"jsonrpc": "2.0", "id": rid, "method": method, "params": params}
        q: queue.Queue = queue.Queue(maxsize=1)
        self.pending[rid] = q
        self._send(msg)
        try:
            return q.get(timeout=timeout)
        except queue.Empty:
            self.pending.pop(rid, None)
            raise TimeoutError(f"app-server request timeout: {method}")

    def _notify(self, method: str, params: dict):
        """notification 전송 (응답 안 기다림)."""
        msg = {"jsonrpc": "2.0", "method": method, "params": params}
        self._send(msg)

    def _send(self, msg: dict):
        if not self.proc or not self.proc.stdin:
            raise RuntimeError("app-server not running")
        line = json.dumps(msg) + "\n"
        try:
            self.proc.stdin.write(line)
            self.proc.stdin.flush()
        except BrokenPipeError:
            raise RuntimeError("app-server stdin closed")

    def _respond_to_request(self, rid: int, result=None, error=None):
        """server-initiated request에 응답 (예: approval)."""
        if error is not None:
            msg = {"jsonrpc": "2.0", "id": rid, "error": error}
        else:
            msg = {"jsonrpc": "2.0", "id": rid, "result": result or {}}
        self._send(msg)

    # ---------------------------------------------------------------
    # Reader loop (stdout JSONL)
    # ---------------------------------------------------------------

    def _reader_loop(self):
        """stdout에서 newline-delimited JSON을 읽어 response/event로 분기."""
        assert self.proc and self.proc.stdout
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                # malformed JSON은 stderr로 흘려보내고 무시
                print(f"[app-server] malformed: {line[:200]}", file=sys.stderr)
                continue
            self._dispatch(msg)

    def _dispatch(self, msg: dict):
        """수신 메시지 분류: response / server-request / notification."""
        if "id" in msg and ("result" in msg or "error" in msg):
            # response to our request
            rid = msg["id"]
            q = self.pending.pop(rid, None)
            if q:
                q.put(msg)
            return

        method = msg.get("method", "")
        if "id" in msg:
            # server-initiated request (approval 등)
            self._handle_server_request(msg)
            return

        # notification (event)
        self._handle_event(msg)

    def _handle_server_request(self, msg: dict):
        """server-initiated request 처리 (approval 등). detached면 자동 decline."""
        method = msg.get("method", "")
        params = msg.get("params", {})
        rid = msg.get("id")

        if method.endswith("/requestApproval"):
            detached = os.environ.get("KANT_DETACHED", "0") == "1"
            if detached:
                # detached면 자동 decline. worktree 밖 접근 같은 요청 거부.
                self._respond_to_request(rid, {"decision": "decline"})
                return
            # foreground면 일단 decline (v1은 자동응답만 지원, v2에서 사용자 인터랙션 추가)
            self._respond_to_request(rid, {"decision": "decline"})
            return

        # unknown server request → 일단 OK 응답으로 넘김 (fail-open 위험은 낮음)
        self._respond_to_request(rid, {})

    def _handle_event(self, msg: dict):
        """notification (이벤트) 처리."""
        method = msg.get("method", "")
        params = msg.get("params", {})

        if method == "thread/started":
            self.thread_id = params.get("thread", {}).get("id") or self.thread_id
        elif method == "turn/started":
            self.last_turn_id = params.get("turn", {}).get("id")
        elif method == "turn/diff/updated":
            self.last_diff = params.get("diff", "")
        elif method == "item/agentMessage/delta":
            delta = params.get("delta", "")
            if delta:
                self.last_message = (self.last_message or "") + delta
        elif method == "thread/tokenUsage/updated":
            self.last_usage = params.get("usage", {})
        elif method == "turn/completed":
            turn = params.get("turn", {})
            self.last_turn_id = turn.get("id", self.last_turn_id)
            # usage 갱신
            if "usage" in turn:
                self.last_usage = turn["usage"]
        elif method in ("item/completed", "item/started"):
            pass  # 별도 처리 불필요
        else:
            pass  # 알 수 없는 이벤트는 무시

        # 이벤트 자체도 큐에 기록 (디버깅용)
        self.events.put(msg)

    # ---------------------------------------------------------------
    # Heartbeat (선택)
    # ---------------------------------------------------------------

    def _heartbeat_loop(self):
        """주기적으로 heartbeat 알림 (현재 v1은 기록만)."""
        while not self._stopped:
            time.sleep(self.heartbeat_sec)
            if self._stopped:
                break
            # app-server는 별도 heartbeat method가 없음. thread는 그대로 사용.
            # 필요시 thread/resume 등으로 상태 점검 가능.

    # ---------------------------------------------------------------
    # High-level operations
    # ---------------------------------------------------------------

    def start_thread(self, sandbox: str | None = None,
                     approval_policy: str | None = None) -> str:
        """thread/start. thread.id 반환."""
        result = self._request("thread/start", {
            "model": self.model,
            "cwd": self.cwd,
            "sandbox": sandbox or self.sandbox,
            "approvalPolicy": approval_policy or self.approval_policy,
        })
        tid = result.get("result", {}).get("thread", {}).get("id") or result.get("thread", {}).get("id")
        if not tid:
            # 다양한 응답 형태 허용
            tid = (result.get("result") or result).get("thread", {}).get("id")
        if not tid:
            raise RuntimeError(f"thread/start returned no thread id: {result}")
        self.thread_id = tid
        return tid

    def resume_thread(self, thread_id: str) -> str:
        """thread/resume."""
        result = self._request("thread/resume", {
            "threadId": thread_id,
            "cwd": self.cwd,
        })
        self.thread_id = thread_id
        return thread_id

    def start_turn(self, thread_id: str, prompt: str, timeout: float = 600.0) -> dict:
        """turn/start. turn/completed까지 대기 후 결과 반환."""
        self.last_message = None
        self.last_diff = None
        self.last_usage = None

        self._request("turn/start", {
            "threadId": thread_id,
            "input": [{"type": "text", "text": prompt}],
        }, timeout=30.0)

        # turn/completed 이벤트까지 대기
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                evt = self.events.get(timeout=1.0)
                if evt.get("method") == "turn/completed":
                    return {
                        "thread_id": self.thread_id,
                        "turn_id": self.last_turn_id,
                        "message": self.last_message,
                        "diff": self.last_diff,
                        "usage": self.last_usage,
                        "status": (evt.get("params") or {}).get("status", "completed"),
                    }
            except queue.Empty:
                continue
        raise TimeoutError("turn/start timeout")

    # ---------------------------------------------------------------
    # Convenience
    # ---------------------------------------------------------------

    def run_once(self, prompt: str, sandbox: str = "readOnly",
                 approval_policy: str = "never", timeout: float = 600.0) -> dict:
        """init → thread/start → turn/start → 결과. 한 번의 호출."""
        self.start()
        try:
            tid = self.start_thread(sandbox=sandbox, approval_policy=approval_policy)
            return self.start_turn(tid, prompt, timeout=timeout)
        finally:
            self.stop()


def main():
    parser = argparse.ArgumentParser(description="Codex app-server client (v1)")
    sub = parser.add_subparsers(dest="cmd", required=True)

    # run 서브커맨드 (가장 흔한 사용)
    p_run = sub.add_parser("run", help="init → thread → turn 한 번에 실행")
    p_run.add_argument("--cwd", required=True)
    p_run.add_argument("--model", default="gpt-5.6-sol")
    p_run.add_argument("--prompt-file", required=True)
    p_run.add_argument("--output", required=True, help="응답 텍스트 저장 경로")
    p_run.add_argument("--sandbox", default="readOnly",
                       choices=["readOnly", "workspaceWrite"])
    p_run.add_argument("--approval-policy", default="never",
                       choices=["never", "onRequest", "untrusted"])
    p_run.add_argument("--heartbeat-sec", type=int, default=5)
    p_run.add_argument("--timeout", type=float, default=600.0)

    # init / thread-start / turn-start / stop 개별 호출
    p_init = sub.add_parser("init", help="initialize handshake만")
    p_init.add_argument("--cwd", required=True)
    p_init.add_argument("--model", default="gpt-5.6-sol")
    p_init.add_argument("--heartbeat-sec", type=int, default=5)

    args = parser.parse_args()

    if args.cmd == "run":
        sandbox = args.sandbox
        # sandbox 정책: implement/repair만 workspaceWrite
        prompt = Path(args.prompt_file).read_text(encoding="utf-8")
        client = CodexAppServer(
            cwd=args.cwd, model=args.model,
            sandbox=sandbox, approval_policy=args.approval_policy,
            heartbeat_sec=args.heartbeat_sec,
        )
        # SIGTERM handler
        def on_signal(signum, frame):
            client.stop()
            sys.exit(128 + signum)
        signal.signal(signal.SIGTERM, on_signal)
        signal.signal(signal.SIGINT, on_signal)

        try:
            result = client.run_once(prompt, sandbox=sandbox,
                                     approval_policy=args.approval_policy,
                                     timeout=args.timeout)
            Path(args.output).write_text(result.get("message") or "", encoding="utf-8")
            # stderr로 메타데이터 (Kant가 파싱 가능하도록)
            print(json.dumps({
                "thread_id": result.get("thread_id"),
                "turn_id": result.get("turn_id"),
                "status": result.get("status"),
                "diff_length": len(result.get("diff") or ""),
                "usage": result.get("usage"),
            }, ensure_ascii=False), file=sys.stderr)
        finally:
            client.stop()
        return 0

    if args.cmd == "init":
        client = CodexAppServer(
            cwd=args.cwd, model=args.model,
            heartbeat_sec=args.heartbeat_sec,
        )
        client.start()
        try:
            print(f"initialized (heartbeat={args.heartbeat_sec}s)", file=sys.stderr)
            # 메인 스레드에서 stdin 대기 (간단한 장기 실행)
            try:
                while True:
                    line = sys.stdin.readline()
                    if not line:
                        break
                    cmd = line.strip()
                    if cmd == "thread/start":
                        try:
                            tid = client.start_thread()
                            print(json.dumps({"thread_id": tid}), flush=True)
                        except Exception as e:
                            print(json.dumps({"error": str(e)}), flush=True)
                    elif cmd.startswith("turn/start "):
                        parts = cmd.split(" ", 2)
                        if len(parts) >= 3:
                            try:
                                result = client.start_turn(parts[1], parts[2])
                                print(json.dumps(result, ensure_ascii=False), flush=True)
                            except Exception as e:
                                print(json.dumps({"error": str(e)}), flush=True)
                    elif cmd == "stop":
                        break
            except KeyboardInterrupt:
                pass
        finally:
            client.stop()
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())