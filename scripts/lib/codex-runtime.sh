#!/usr/bin/env bash
# codex-runtime.sh — Codex app-server 런타임 wrapper (bash)
#
# Kant 어댑터가 exec 또는 app-server 런타임을 선택해 호출할 수 있도록
# 단일 진입점 제공. Python 클라이언트는 scripts/runtime/codex-app-server-client.py.
#
# 사용:
#   codex-runtime.sh exec <timeout> <log> <response> <cwd> <model> <prompt_file>
#   codex-runtime.sh app-server <timeout> <log> <response> <cwd> <model> <prompt_file> [sandbox]
#
# 안전:
# - sandbox 정책 강제 (sandbox 인자 화이트리스트)
# - approval_policy=never in detached (서버 initiated 자동 decline)
# - </dev/null stdin 차단
# - SIGTERM graceful shutdown (Python 클라이언트가 처리)

set -Eeuo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$LIB_DIR/../runtime"

# ---------------------------------------------------------------------------
# exec 런타임 (기존 codex exec 호출) — 단순히 caller가 그대로 호출하는 wrapper
# ---------------------------------------------------------------------------

runtime_exec() {
    local timeout="$1" log_file="$2" response_file="$3" cwd="$4" model="$5" prompt_file="$6"

    if [ ! -f "$prompt_file" ]; then
        echo "ERROR: prompt file not found: $prompt_file" >&2
        return 1
    fi

    local prompt
    prompt="$(cat "$prompt_file")"

    local cmd=(
        codex exec
        --json
        -o "$response_file"
        -s read-only
        -C "$cwd"
        -m "$model"
        --skip-git-repo-check
    )

    if printf '%s' "$model" | grep -qE 'gpt-5\.'; then
        local effort="${KANT_CODEX_REASONING_EFFORT:-medium}"
        cmd+=( -c "model_reasoning_effort=$effort" )
    fi

    if [ "${KANT_DETACHED:-0}" = "1" ]; then
        cmd+=( -c "approval_policy=never" )
    fi

    cmd+=( "$prompt" )

    timeout "$timeout" "${cmd[@]}" </dev/null > "$response_file" 2> "$log_file"
}

# ---------------------------------------------------------------------------
# app-server 런타임 (Python 클라이언트 호출)
# ---------------------------------------------------------------------------

runtime_app_server() {
    local timeout="$1" log_file="$2" response_file="$3" cwd="$4" model="$5" prompt_file="$6"
    local sandbox="${7:-readOnly}"

    if [ ! -f "$prompt_file" ]; then
        echo "ERROR: prompt file not found: $prompt_file" >&2
        return 1
    fi

    if [ ! -x "$RUNTIME_DIR/codex-app-server-client.py" ]; then
        echo "ERROR: codex-app-server-client.py not found or not executable: $RUNTIME_DIR/codex-app-server-client.py" >&2
        return 1
    fi

    # sandbox 화이트리스트
    case "$sandbox" in
        readOnly|workspaceWrite) ;;
        *)
            echo "ERROR: invalid sandbox '$sandbox' (readOnly|workspaceWrite only)" >&2
            return 1
            ;;
    esac

    # detached 모드면 approval_policy=never, 아니면 onRequest (foreground면 사용자 응답 큐잉)
    local approval_policy
    if [ "${KANT_DETACHED:-0}" = "1" ]; then
        approval_policy="never"
    else
        approval_policy="onRequest"
    fi

    # Python 클라이언트 호출. 응답은 response_file에 저장, stderr는 log.
    local heartbeat_sec="${KANT_HEARTBEAT_SEC:-5}"

    python3 "$RUNTIME_DIR/codex-app-server-client.py" run \
        --cwd "$cwd" \
        --model "$model" \
        --prompt-file "$prompt_file" \
        --output "$response_file" \
        --sandbox "$sandbox" \
        --approval-policy "$approval_policy" \
        --heartbeat-sec "$heartbeat_sec" \
        --timeout "$timeout" \
        > "$response_file" 2> "$log_file"

    local rc=$?
    # app-server Python 클라이언트는 응답 텍스트를 stdout으로도 보냄. response_file에 텍스트만 남도록 정리.
    if [ -f "$response_file" ]; then
        # stderr 메타데이터가 response_file에 섞였으면 정리 (v1에서는 stdout만 response_file에 저장되므로 OK)
        :
    fi
    return $rc
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

case "${1:-}" in
    exec)
        shift
        runtime_exec "$@"
        exit $?
        ;;
    app-server)
        shift
        runtime_app_server "$@"
        exit $?
        ;;
    *)
        echo "codex-runtime.sh — Codex 런타임 dispatcher"
        echo ""
        echo "사용법:"
        echo "  codex-runtime.sh exec <timeout> <log> <response> <cwd> <model> <prompt>"
        echo "  codex-runtime.sh app-server <timeout> <log> <response> <cwd> <model> <prompt> [sandbox]"
        exit 1
        ;;
esac