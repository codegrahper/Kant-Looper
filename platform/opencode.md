# `platform/opencode.md` — OpenCode (Meta Agent Host)

이 파일은 **OpenCode 런타임에서 Meta Agent를 구동**할 때의 정보를 담는다.

## 설치 — 별도 설치 불필요

OpenCode는 `.claude/skills/`(및 `.agents/skills/`) 경로를 자체적으로 직접
읽도록 공식 지원한다. 따라서 nomad-kant-looper를 OpenCode에서 쓰기 위해
**별도로 복사하거나 clone하거나 심링크를 만들 필요가 없다.**

Claude Code 설치 경로(`$HOME/.claude/skills/nomad-kant-looper`)에 이미
스킬이 있다면, OpenCode는 그 경로를 그대로 읽는다.

## 미확정 항목

권한 모델, 백그라운드 실행 인터페이스 등 OpenCode와 다른 런타임 간의 세부
차이는 아직 미확정이다. 내용이 확인되면 이 파일에 추가한다. 확인 전에는
추측 내용을 적지 않는다.
