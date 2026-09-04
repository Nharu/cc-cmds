#!/usr/bin/env bash
# An invalid UTF-8 byte sits on the same line as the idiom, and the file holds
# no NUL byte anywhere. A UTF-8 matcher refuses the line outright, so the
# candidate pass has to include a C-pinned run to nominate it at all; a NUL
# would put BSD grep on its byte-oriented path, where the two locales behave
# alike and this file would stop discriminating.
ÿ sed -i '' s/old/new/ target.txt
