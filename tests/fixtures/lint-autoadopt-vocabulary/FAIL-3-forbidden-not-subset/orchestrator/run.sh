#!/usr/bin/env bash
# Fixture driver whose forbidden set names a token the vocabulary does not carry.
# A class with no token has to borrow a permitted one when the decision is
# recorded, and that borrowing is the leak the named-and-forbidden pair closes.
readonly JUDGMENT_CLASSES="문서-신선도 감사-발견 심각도-조정 잔여-항목 인용-갱신 스테이지-재시도"
readonly JUDGMENT_CLASSES_FORBIDDEN="팀-구성 시각-면제"
