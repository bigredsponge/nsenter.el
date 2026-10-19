;;; nsenter-test-helpers.el --- The environment that the tests run in -*- lexical-binding: t; -*-

;;; Commentary:

;; The tests run real programs in a real environment, named "test", which
;; these variables describe:
;;
;; - NSENTER_TEST_ENTER: the command that runs its arguments inside, split on
;;   spaces, like "podman exec -i box".
;; - NSENTER_TEST_MARKER: a program that exists inside, but not on the host.
;; - NSENTER_TEST_ROOT: a directory that the host and the environment share,
;;   ~/.cache/nsenter-test/ by default.
;;
;; The justfile sets them up for a Podman container and for a Nix chroot
;; store, and runs each test file in an Emacs of its own.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'nsenter)
;; Libraries of operations that the tests call.
(require 'bytecomp)
(require 'compile)
(require 'diff)
(require 'dired)
(require 'eshell)
(require 'filenotify)
(require 'tramp)

(defvar nsenter-test-directory-on-host
  (file-name-as-directory
   (expand-file-name (or (getenv "NSENTER_TEST_ROOT") "~/.cache/nsenter-test")))
  "The host's name for the directory that the tests work in.")

(defvar nsenter-test-directory
  (concat "/ns:test:" nsenter-test-directory-on-host)
  "The /ns: name for the directory that the tests work in.")

(defvar nsenter-test-marker
  (or (getenv "NSENTER_TEST_MARKER")
      (error "Set NSENTER_TEST_MARKER, or run the tests from the justfile"))
  "A program that exists inside the environment, but not on the host.")

(setq nsenter-environments
      `(("test" :enter ,(split-string
                         (or (getenv "NSENTER_TEST_ENTER")
                             (error "Set NSENTER_TEST_ENTER, or run the \
tests from the justfile"))))))

(make-directory nsenter-test-directory-on-host t)

(defmacro nsenter-test-in-directory (&rest body)
  "Evaluate BODY with `nsenter-test-directory' as `default-directory'."
  (declare (indent 0))
  `(let ((default-directory nsenter-test-directory)) ,@body))

(defconst nsenter-test-timeout (if (getenv "CI") 40 10)
  "Seconds to wait for a process, longer on CI, whose machines are slower.")

(defun nsenter-test-wait (predicate)
  "Wait for PREDICATE, processing process output meanwhile.
Fail the test if PREDICATE is still nil after `nsenter-test-timeout'."
  (with-timeout (nsenter-test-timeout
                 (ert-fail (format "Timed out after %ds"
                                   nsenter-test-timeout)))
    (while (not (funcall predicate))
      (accept-process-output nil 0.01))))

(defun nsenter-test-read (file)
  "The contents of FILE."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(provide 'nsenter-test-helpers)
;;; nsenter-test-helpers.el ends here
