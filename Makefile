.PHONY: help verify changeset changeset-status changeset-test hooks-install version

PYTHON ?= python3

help:
	@printf '%s\n' 'make verify            changeset tests and status, then mise run check'
	@printf '%s\n' 'make changeset         add a release note or an intentional empty changeset'
	@printf '%s\n' 'make changeset-status  validate pending notes and preview the next version'
	@printf '%s\n' 'make changeset-test    test the changeset tool and its hook in disposable repositories'
	@printf '%s\n' 'make hooks-install     install the changeset pre-commit hook once per clone'
	@printf '%s\n' 'make version           prepare a release on a clean main (no commit, tag or push)'

# The Zig checks stay mise tasks (mise.toml); this is the one entry point before a commit.
verify: changeset-test changeset-status
	mise run check

changeset:
	$(PYTHON) -B scripts/changeset.py add

changeset-status:
	$(PYTHON) -B scripts/changeset.py status

changeset-test:
	$(PYTHON) -B scripts/test_changeset.py

hooks-install:
	$(PYTHON) -B scripts/changeset.py install-hook

version:
	$(PYTHON) -B scripts/changeset.py version
