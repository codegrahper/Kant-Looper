# `platform/codex.md` — Codex (Meta Agent Host)

이 파일은 **Codex 런타임에서 Meta Agent를 구동**할 때의 정보를 담는다.

## 설치 경로

설치 경로는 `$HOME/.codex/skills/nomad-kant-looper`이다.

> **TODO (설치 방식):** 현재 이 경로는 이 저장소의 독립된 git clone으로
> 운영되고 있다. 추후 Claude Code와 동일하게 worktree 방식으로 전환될
> 예정이지만, 그 전환은 별개 작업에서 다룬다. (`install.sh` 도입 예정.)

## Codex 전용 인터페이스 메타데이터

Codex 런타임을 위한 인터페이스 메타데이터(name, phases, modes, agents,
safety, …)는 **저장소 루트의 `agents/openai.yaml`**에 분리되어 있다.
`platform/codex.md` 아래에 중복 파일을 만들지 않는다. 자세한 내용은
`../agents/openai.yaml`을 참조.

## 미확정 TODO

다음 항목은 아직 검증되지 않았다. 단정하지 않는다.

1. **구조화된 선택 UI 가용 등급 미검증.** Codex가 사용자에게 선택지를
   제공할 때, 어느 형태까지 지원하는지(구조화된 UI / 번호가 매겨진 목록 /
   평문 출력)가 아직 검증되지 않았다. 어느 등급에 해당하는지 확인되면 이
   파일에 기록한다.
