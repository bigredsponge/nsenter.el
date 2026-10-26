emacs := env("EMACS", "emacs")
container := "nsenter-test"
image := "docker.io/library/alpine:3.22"
nix_store := home_directory() / ".cache/nsenter-test-nix-store"

check: compile lint

compile:
    {{emacs}} -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile tramp-ns.el
    rm -f tramp-ns.elc

lint:
    {{emacs}} -Q --batch -l checkdoc --eval \
      '(progn (mapc (function checkdoc-file) command-line-args-left) (kill-emacs (if (get-buffer "*Warnings*") 1 0)))' *.el

test-podman:
    #!/usr/bin/env bash
    set -euo pipefail
    podman run --detach --replace --name {{container}} {{image}} sleep infinity
    trap 'podman rm --force --time 0 {{container}} > /dev/null' EXIT
    {{just_executable()}} _test 'podman exec -i {{container}}'

test-distrobox:
    #!/usr/bin/env bash
    set -euo pipefail
    distrobox create --yes --name {{container}} --image {{image}}
    trap 'distrobox rm --force --yes {{container}} > /dev/null' EXIT
    distrobox enter --no-tty {{container}} -- true
    {{just_executable()}} _test 'distrobox enter --no-tty {{container}} --'

# A store outside /nix makes nix shell use a namespace.
test-nix:
    {{just_executable()}} _test 'nix shell --store {{nix_store}} nixpkgs#hello -c'

[private]
_test enter:
    NSENTER_TEST_ENTER='{{enter}}' {{emacs}} -Q --batch -L . -l tramp-ns-test.el -f ert-run-tests-batch-and-exit < /dev/null
