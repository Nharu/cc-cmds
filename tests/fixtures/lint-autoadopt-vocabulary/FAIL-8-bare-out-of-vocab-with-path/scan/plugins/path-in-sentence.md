# Fixture out-of-vocabulary claim carrying a path later in the line

An out-of-vocabulary first token, then ordinary words, then a path. The value
reaches no terminator, so it runs to the end of the line and the token path is
what compares it.

Asking the shape test about the whole remainder reads that slash as a parser
pattern and skips the line whole, and the bad token at the head is then never
compared at all. Slashes are ordinary in these documents, so that reading hides
the claim behind any sentence that happens to mention a file.

판단 부류=없는-부류 — 자세한 것은 docs/foo.md 참조
