.PHONY: help verify install changeset changeset-status changeset-test hooks-install version

PYTHON ?= python3

# Settings for one machine (SIGN_IDENTITY, SIGN_ID, LAUNCH_AGENT, INSTALL_BIN); Git ignores it.
-include local.mk

# The launch agent runs this copy, not zig-out/.
INSTALL_BIN ?= $(HOME)/.local/share/zugriff/bin/zugriff
LAUNCH_AGENT ?= local.zugriff

# macOS ties the Accessibility permission (needed to insert emoji) to the code signature.
# Sign with a certificate of your own (SIGN_IDENTITY) so the permission survives updates.
SIGN_IDENTITY ?= -
SIGN_ID ?= local.zugriff

help:
	@printf '%s\n' 'make verify            changeset tests and status, then mise run check'
	@printf '%s\n' 'make install           build a clean tree in ReleaseSafe, sign, install and restart the launch agent'
	@printf '%s\n' 'make changeset         add a release note or an intentional empty changeset'
	@printf '%s\n' 'make changeset-status  validate pending notes and preview the next version'
	@printf '%s\n' 'make changeset-test    test the changeset tool and its hook in disposable repositories'
	@printf '%s\n' 'make hooks-install     install the changeset pre-commit hook once per clone'
	@printf '%s\n' 'make version           prepare a release on a clean main (no commit, tag or push)'

# The Zig checks stay mise tasks (mise.toml); this is the one entry point before a commit.
verify: changeset-test changeset-status
	mise run check

install:
	@test -z "$$(git status --porcelain --untracked-files=all)" || { echo "Commit pending work first."; exit 1; }
	mise x -- zig build -Doptimize=ReleaseSafe
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier $(SIGN_ID) zig-out/bin/zugriff
	codesign --verify --strict zig-out/bin/zugriff
	install -d "$$(dirname $(INSTALL_BIN))"
	install -m 0755 zig-out/bin/zugriff $(INSTALL_BIN)
	/bin/launchctl kickstart -k gui/$$(id -u)/$(LAUNCH_AGENT) || { echo "Launch agent $(LAUNCH_AGENT) is not loaded."; exit 1; }

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
