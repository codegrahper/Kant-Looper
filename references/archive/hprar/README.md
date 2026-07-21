# HPRAR 아카이브

이 디렉터리의 문서는 v0.5 이전에 존재했던 HPRAR(Plan→Implement→Review→
Repair→Verify 자동 라운드) 아키텍처를 설명한다. HPRAR는 2026-07-17
복잡도 문제로 폐기됐고(`--full` 모드 코드 삭제, CHANGELOG.md 참고), 현재
`kant-loop.sh`는 `implement`/`review`/`repair` 3역할의 가벼운 quick/parallel
모드만 사용한다.

이 문서들은 **런타임 계약이 아니라 역사적 기록으로만** 보존한다. 현재 동작
기준은 `platform/HOST-CONTRACT.md`와 `scripts/kant-loop.sh` 자체다.
