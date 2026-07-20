# `platform/claude.md` — Claude Code (Meta Agent Host)

이 파일은 **Claude Code 런타임에서 Meta Agent를 구동**할 때의 정보를 담는다.
런타임별 차이 중 Claude Code에 해당하는 설치 경로, 백그라운드 실행, 훅 관련
세부 내용을 여기에 모은다.

> **TODO (별도 작업):** Claude Code 전용 백그라운드 실행(`--detach`) 및
> 훅(hooks) 관련 세부 내용은 추후 별도 작업에서 이 파일로 옮겨진다. 지금은
> 해당 내용이 아직 `SKILL.md`와 스크립트에 남아 있다.

## 설치 경로

기본 설치 경로는 `$HOME/.claude/skills/nomad-kant-looper`이다.

이 경로는 이 저장소(nomad-kant-looper)의 **git worktree**로 구현되어 있다.
즉 Claude Code가 읽는 스킬 디렉터리와 저장소의 작업 브랜치가 같은 git 저장소를
공유한다.
