# Verification (fixture)

One definition site, one by-name reference, one marked discussion.

```
git status --porcelain --untracked-files=all ; legacy gates run git status --porcelain here.
```

At every boundary the main tree **capture format** must equal the baseline.

The bare `git status --porcelain` folds untracked directories, which is why it was retired.
