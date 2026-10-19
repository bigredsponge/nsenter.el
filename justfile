# Compile, lint and test with the Emacs, Podman and Nix of this machine.  The
# tests run in a Podman container, or in a Nix chroot store; both share
# test_root with the host, where the tests make their files.  `just --list`
# shows the recipes.

emacs := env("EMACS", "emacs")
test_root := env("NSENTER_TEST_ROOT", home_directory() / ".cache/nsenter-test")
container := "nsenter-test"
image := "docker.io/library/alpine:3.22"
nix_store := home_directory() / ".cache/nsenter-test-nix-store"

# Byte-compile nsenter.el, failing on warnings.
compile:
    {{emacs}} -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
      -f batch-byte-compile nsenter.el
    rm -f nsenter.elc

# Check the docstrings and comments of the Emacs Lisp files.
lint:
    {{emacs}} -Q --batch -l tools/nsenter-lint.el -f nsenter-lint-checkdoc \
      nsenter.el test/*.el tools/*.el

# Test in an Alpine container, whose apk is the marker.
test-podman:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p '{{test_root}}'
    podman run --detach --replace --name {{container}} \
      --volume '{{test_root}}:{{test_root}}:z' {{image}} sleep infinity
    trap 'podman rm --force --time 0 {{container}} > /dev/null' EXIT
    NSENTER_TEST_ENTER="podman exec -i {{container}}" \
    NSENTER_TEST_MARKER=apk \
      {{just_executable()}} _run-tests

# The store is outside /nix, so nix shell runs its command in a namespace,
# see https://nix.dev/manual/nix/latest/store/types/local-store#chroot
[doc('Test in a Nix chroot store, whose hello is the marker.')]
test-nix:
    mkdir -p '{{test_root}}'
    NSENTER_TEST_ENTER="nix shell --store {{nix_store}} nixpkgs#hello -c" \
    NSENTER_TEST_MARKER=hello \
      {{just_executable()}} _run-tests

# Each test file runs in an Emacs of its own, so that none sees what
# another left behind.
_run-tests:
    #!/usr/bin/env bash
    set -euo pipefail
    for file in test/*-test.el; do
      NSENTER_TEST_ROOT='{{test_root}}' {{emacs}} -Q --batch -L . -L test \
        -l "$file" -f ert-run-tests-batch-and-exit < /dev/null
    done
