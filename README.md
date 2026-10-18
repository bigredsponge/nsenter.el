# nsenter.el

Fast access to your Linux namespaces.

This package allows TRAMP-like access to a local, user-owned namespace (think
Podman containers) without the overhead of TRAMP.

TRAMP's architecture assumes that you are connecting to a server over the
network.  Because of this, TRAMP performs operations by running shell
commands and piping data over the network.  This leads to considerable
overhead, even if you are connecting to a local container using the Podman
TRAMP backends.

To solve this problem, we register a file name handler, as TRAMP does.  We
use two techniques to provide fast access:

- We notice that for a file inside the namespace (e.g., /etc/hosts), there
  exists a path on the host that can access this file (e.g.,
  /proc/PID/root/etc/hosts).  Thus, to access files, we can do a simple
  file name translation instead of needlessly copying files over.
- We run a command directly inside the namespace by wrapping it with another
  command (e.g., "podman exec -i").  Commands like "podman exec -i" have
  some startup overhead, so we use the "nsenter" command directly for a very
  quick startup.

Here is an example of how one could use the package.

```elisp
(require 'nsenter)
(setq nsenter-environments
      '(("mypod" :enter ("podman" "exec" "-i" "mypod"))
        ("mybox" :enter ("distrobox" "enter" "mybox" "--"))))
```

Then you can access files with "/ns:mypod:..." or "/ns:mybox:...".

You can even enter a Nix chroot (see
https://nix.dev/manual/nix/latest/store/types/local-store#chroot).

```elisp
(setq nsenter-environments
      '(("mynix" :enter ("nix shell nixpkgs#hello -c"))))
```

## License

[MIT License](LICENSE).
