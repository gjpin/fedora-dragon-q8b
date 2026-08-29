# Agent instructions

## GitHub Actions

- When creating or updating GitHub Actions workflows, always use the latest stable release of each action.
- Pin every `uses:` reference to the action's full commit SHA. Do not use mutable tags or branches.
- Put the human-readable action version immediately after the pinned SHA as a comment.
- Whenever the action version changes, update both the version comment and the pinned commit SHA together.

Example:

```yaml
uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
```

## CI validation

- Run `./scripts/ci-smoke.sh` for every change, and always when a change is made that affects a GitHub Actions workflow.
- The CI smoke test must pass before committing or pushing the change.
