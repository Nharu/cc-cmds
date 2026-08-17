# Verification (fixture)

One definition site, one by-name reference, one marked discussion.

```
git status --porcelain --untracked-files=all
```

At every boundary the main tree **capture format** must equal the baseline.

The bare `git status --porcelain` folds untracked directories, which is why it was retired.

The gate MUST run bare `git status --porcelain` and compare entries.
