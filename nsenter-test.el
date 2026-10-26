;;; nsenter-test.el --- Tests in real environments -*- lexical-binding: t; -*-

;;; Commentary:

;; NSENTER_TEST_ENTER is the command that enters the environment, split on
;; spaces, like "podman exec -i box"; the justfile sets it.

;;; Code:

(require 'ert)
(require 'nsenter)
(require 'dired)
(require 'compile)
(require 'vc-git)
(require 'shell)
(require 'eshell)

(setq nsenter-environments
      `(("test" :enter ,(split-string (getenv "NSENTER_TEST_ENTER")))))
(defvar nsenter-test-root
  (format "/ns:test:/tmp/nsenter-test-%d/" (emacs-pid))
  "The directory inside that a test makes and then deletes.")

(defmacro nsenter-test-with-directory (&rest body)
  "Evaluate BODY in a fresh `nsenter-test-root', deleted afterwards."
  (declare (indent 0))
  `(let ((default-directory nsenter-test-root))
     (make-directory default-directory t)
     (unwind-protect (progn ,@body)
       (dolist (b (buffer-list))
         (when (with-current-buffer b
                 (and buffer-file-name
                      (string-prefix-p nsenter-test-root buffer-file-name)))
           (with-current-buffer b (set-buffer-modified-p nil))
           (kill-buffer b)))
       (delete-directory nsenter-test-root t))))

(defun nsenter-test-output (&rest args)
  "Return the output of running ARGS inside, which must succeed."
  (with-temp-buffer
    (should (zerop (apply #'process-file (car args) nil t nil (cdr args))))
    (buffer-string)))

(defun nsenter-test-wait (p)
  "Wait for process P to exit successfully."
  (let ((deadline (+ (float-time) 20)))
    (while (and (process-live-p p) (< (float-time) deadline))
      (accept-process-output p 0.05))
    (should-not (process-live-p p))
    (should (zerop (process-exit-status p)))))

(ert-deftest nsenter-edit-and-files ()
  (nsenter-test-with-directory
    (let* ((file (expand-file-name "notes.txt"))
           (b (find-file-noselect file)))
      (with-current-buffer b
        (insert "first\n") (save-buffer)
        (should (equal buffer-file-name file))
        (should (verify-visited-file-modtime b))
        (goto-char (point-max)) (insert "second\n") (save-buffer))
      (should (file-exists-p (concat file "~")))
      (should (file-exists-p file))
      (should (file-regular-p file))
      (should (file-readable-p file))
      (should (file-writable-p file))
      (should (equal (nsenter-test-output "cat" "notes.txt") "first\nsecond\n"))
      (copy-file file (expand-file-name "copy.txt"))
      (rename-file (expand-file-name "copy.txt") (expand-file-name "renamed.txt"))
      (should (member "renamed.txt" (directory-files default-directory)))
      (should (member "notes.txt" (file-name-all-completions "not" default-directory)))
      (should (member file (directory-files default-directory t "notes")))
      (let ((local (file-local-copy file)))
        (unwind-protect
            (should (equal (nsenter--read local) "first\nsecond\n"))
          (delete-file local)))
      (delete-file (expand-file-name "renamed.txt"))
      (should-not (file-exists-p (expand-file-name "renamed.txt"))))))

(ert-deftest nsenter-links-stay-in-root ()
  (nsenter-test-with-directory
    (nsenter-test-output
     "sh" "-c"
     "mkdir dir; printf inner > dir/data; ln -s \"$PWD/dir\" absolute; ln -s dir relative; ln -s /../../etc/os-release rooted; ln -s missing dangling")
    (dolist (name '("absolute/data" "relative/data"))
      (with-temp-buffer
        (insert-file-contents (expand-file-name name))
        (should (equal (buffer-string) "inner"))))
    (should (file-symlink-p (expand-file-name "absolute")))
    (should (stringp (file-attribute-type
                      (file-attributes (expand-file-name "absolute/")))))
    (should (file-directory-p (expand-file-name "absolute")))
    (should (member "absolute/" (file-name-all-completions "abs" default-directory)))
    (should-not (file-exists-p (expand-file-name "dangling")))
    (delete-file (expand-file-name "absolute"))
    (should (file-exists-p (expand-file-name "dir/data")))
    ;; PATH is deliberately not normalized by expand-file-name first.
    (should (equal (nsenter--read (nsenter--local (concat default-directory "rooted")))
                   (nsenter-test-output "cat" "/etc/os-release")))))

(ert-deftest nsenter-processes ()
  (nsenter-test-with-directory
    (should (equal (string-trim (nsenter-test-output "pwd"))
                   (directory-file-name (file-local-name default-directory))))
    (let ((process-environment (cons "NSENTER_TEST_BOUND=from-emacs" process-environment)))
      (should (equal (nsenter-test-output "sh" "-c" "printf %s \"$NSENTER_TEST_BOUND\"")
                     "from-emacs")))
    (with-temp-buffer
      (let ((process-connection-type nil)
            (p (start-file-process "nsenter-async" (current-buffer)
                                   "sh" "-c" "printf async")))
        (nsenter-test-wait p)
        (should (string-prefix-p "async" (buffer-string)))))
    (with-temp-buffer
      (should (zerop (shell-command "printf shell" (current-buffer))))
      (should (equal (buffer-string) "shell")))
    (let* ((compilation-read-command nil)
           (b (compilation-start "printf 'source.c:1: test\\n'"))
           (p (get-buffer-process b)))
      (unwind-protect
          (progn (nsenter-test-wait p)
                 (with-current-buffer b
                   (should (string-match-p "source.c:1: test" (buffer-string)))))
        (kill-buffer b)))))

(ert-deftest nsenter-shell-and-eshell ()
  (nsenter-test-with-directory
    (save-window-excursion
      (let* ((explicit-shell-file-name "/bin/sh")
             (b (shell (generate-new-buffer "*nsenter-shell*")))
             (p (get-buffer-process b)))
        (unwind-protect
            (progn
              (process-send-string p "printf 'nsenter-shell-ok\\n'; exit\n")
              (nsenter-test-wait p)
              (with-current-buffer b
                (should (string-match-p "nsenter-shell-ok" (buffer-string)))))
          (when (process-live-p p) (delete-process p))
          (kill-buffer b))))
    (with-temp-buffer
      (eshell-command "printf nsenter-eshell-ok" t)
      (should (string-match-p "nsenter-eshell-ok" (buffer-string))))))

(ert-deftest nsenter-dired-and-git ()
  (nsenter-test-with-directory
    (skip-unless (executable-find "git" t))
    (nsenter-test-output "git" "init" "-q")
    (write-region "tracked\n" nil (expand-file-name "tracked") nil 'silent)
    (nsenter-test-output "git" "add" "tracked")
    (nsenter-test-output "git" "-c" "user.name=Test" "-c" "user.email=test@example.org"
                         "commit" "-qm" "Initial")
    (let ((file (expand-file-name "tracked")))
      (should (vc-git-registered file))
      (should (eq (vc-git-state file) 'up-to-date)))
    (save-window-excursion
      (let ((b (dired-noselect default-directory)))
        (unwind-protect
            (with-current-buffer b
              (should (dired-goto-file (expand-file-name "tracked")))
              (revert-buffer))
          (kill-buffer b))))))

(ert-deftest nsenter-connection-lifetime ()
  (let* ((vec (tramp-dissect-file-name "/ns:test:/"))
         (p (nsenter--connection vec))
         (pid (process-get p 'nsenter-pid)))
    (process-send-eof p)
    (let ((deadline (+ (float-time) 10)))
      (while (and (process-live-p p) (< (float-time) deadline))
        (accept-process-output p 0.05)))
    (should-not (file-exists-p (format "/proc/%d" pid)))
    (should (file-exists-p "/ns:test:/etc/os-release"))
    (should-not (= pid (process-get (nsenter--connection vec) 'nsenter-pid)))))

(ert-deftest nsenter-startup-timeouts ()
  (let* ((nsenter-start-timeout 0.05)
         (nsenter-environments
          '(("slow" :enter ("sh" "-c" "sleep 2; exec \"$@\"" "test"))))
         (vec (tramp-dissect-file-name "/ns:slow:/")))
    (unwind-protect
        (progn
          (let ((non-essential t))
            (should-not (file-exists-p "/ns:slow:/etc/os-release")))
          (should-not (tramp-get-connection-process vec))
          (dolist (timeout '(nil 0.15))
            (setf (plist-get (cdar nsenter-environments) :timeout) timeout)
            (let ((start (float-time)))
              (should-error (file-exists-p "/ns:slow:/etc/os-release"))
              (let ((elapsed (- (float-time) start))
                    (expected (or timeout nsenter-start-timeout)))
                (should (>= elapsed expected))
                (should (< elapsed (+ expected 1)))))
            (should-not (process-live-p (tramp-get-connection-process vec)))))
      (tramp-cleanup-connection vec))))

(provide 'nsenter-test)
;;; nsenter-test.el ends here
