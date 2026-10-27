# tramp-ns

[![CI](https://github.com/bigredsponge/tramp-ns/actions/workflows/test.yml/badge.svg)](https://github.com/bigredsponge/tramp-ns/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/bigredsponge/tramp-ns/blob/master/LICENSE)

**tramp-ns** is a TRAMP backend for accessing user-owned Linux namespaces.
A rootless Podman container is a user-owned Linux namespace. Rootful Docker
and Podman containers belong to root, so this package does not support them.

The default Podman TRAMP backend is slow. We speed up the backend by:

- Noticing that for a file inside the namespace (e.g., `/etc/hosts`), there
  exists a path on the host that can access this file (e.g.,
  `/proc/PID/root/etc/hosts`). Thus, to access files, we can do a simple
  file name translation instead of needlessly copying files over.
- Running commands directly inside the namespace by wrapping each one with
  another command (e.g., `podman exec -i`). Commands like `podman exec -i`
  have some startup overhead, so we use the `nsenter` command directly for a
  very quick startup.

Plus, now we can support other types of namespaces, such as
[Nix chroot](https://nix.dev/manual/nix/latest/store/types/local-store#chroot).

## Installation

tramp-ns requires Emacs 30.1 or later, Linux, and a util-linux `nsenter` that
supports `--wdns`.

Install from GitHub with `use-package`:

```emacs-lisp
(use-package tramp-ns
  :vc (:url "https://github.com/bigredsponge/tramp-ns"
       :rev :newest))
```

### Local checkout

```sh
git clone https://github.com/bigredsponge/tramp-ns.git
```

```emacs-lisp
(add-to-list 'load-path "/path/to/tramp-ns")
(require 'tramp-ns)
```

## Configuration

`tramp-ns-environments` is a list of entries. Each entry has a name and an
`:enter` command, written as a list of strings. To connect, tramp-ns appends
`sh -c 'read _' tramp-ns-XXXXXX` to `:enter` and runs it. For example, this
entry:

```emacs-lisp
("mypod" :enter ("podman" "exec" "-i" "mypod"))
```

makes tramp-ns run:

```sh
podman exec -i mypod sh -c 'read _' tramp-ns-XXXXXX
```

`read _` waits on standard input, and tramp-ns finds the PID of that `sh`
process in `/proc`. So `:enter` must pass the extra arguments through, keep
standard input open, and work without a terminal.

tramp-ns runs `:enter` once per connection. Later commands run through
`nsenter` and inherit the environment variables of that `sh` process. Put any
environment setup in `:enter`. For example, to load `PATH` and other variables
from your shell profile, wrap the command in a login shell:

```emacs-lisp
("mybox" :enter ("distrobox" "enter" "mybox" "--"
                 "sh" "-lc" "exec \"$@\"" "sh"))
```

### Podman and Distrobox

```emacs-lisp
(setq tramp-ns-environments
      '(("mypod" :enter ("podman" "exec" "-i" "mypod"))
        ("mybox" :enter ("distrobox" "enter" "mybox" "--"))))
```

Open files with `/ns:mypod:/path/to/file` or `/ns:mybox:/path/to/file`.

### Nix chroot

If your Nix store is not at `/nix/store`, Nix runs programs in a mount
namespace where the store appears at `/nix/store`. Enter that namespace with a
`nix` command that runs a program:

```emacs-lisp
(setq tramp-ns-environments
      '(("mynix" :enter ("nix" "shell" "nixpkgs#hello" "-c"))))
```

### Startup timeout

tramp-ns waits `tramp-ns-start-timeout` seconds for `:enter` to start. Set
`:timeout` on an entry to change the limit for that environment:

```emacs-lisp
(setq tramp-ns-environments
      '(("slowbox" :enter ("distrobox" "enter" "slowbox" "--")
                   :timeout 300)))
```
