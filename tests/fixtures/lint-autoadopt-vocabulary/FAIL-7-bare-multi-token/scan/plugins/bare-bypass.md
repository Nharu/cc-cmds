# Fixture bare bypass row

Two class names set side by side with nothing after them. The value reaches no
terminator, so it runs to the end of the line and the token path decides it:
every token names a class and there is more than one, which is the bypass shape
and not a sentence about a class.

The terminated spelling of the same shape is covered by another fixture, and it
takes the other branch — a value ending at a field separator is compared whole.
This fixture is the only one that reaches the unterminated multi-token arm, so
disabling that arm has to turn this directory red and nothing else.

판단 부류=스테이지-재시도 팀-구성
