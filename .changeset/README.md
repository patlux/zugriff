# Changesets

Pending release notes, one Markdown file per change. Add one with `make changeset`, or an
intentionally empty one for docs, tests and tooling:

```sh
python3 -B scripts/changeset.py add --empty
```

Stage the new file with its change. `make changeset-status` checks the pending notes; only
`make version` consumes them, on a clean `main`. The full flow is in `CONTRIBUTING.md`.
