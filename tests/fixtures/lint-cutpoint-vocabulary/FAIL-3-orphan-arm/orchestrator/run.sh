readonly CUTPOINTS="커밋 브랜치 push PR 머지 배포 머지후착수"
cutpoint_display() {
  case "$1" in
    커밋)       printf '커밋' ;;
    브랜치)     printf '브랜치' ;;
    push)       printf 'push' ;;
    PR)         printf 'PR' ;;
    머지)       printf '머지' ;;
    배포)       printf '배포' ;;
    머지후착수) printf '머지 후 후속 착수' ;;
    없는토큰)   printf '없는 표시' ;;
    *)          return 1 ;;
  esac
}
