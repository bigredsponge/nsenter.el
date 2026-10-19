;;; nsenter-scenarios-test.el --- Packages at work on /ns: names -*- lexical-binding: t; -*-

;;; Commentary:

;; Scenarios that combine operations the way packages like Dired, Eshell and
;; compile do.

;;; Code:

(require 'nsenter-test-helpers)

(ert-deftest nsenter-test-files ()
  "Visiting, saving and listing a file, as `find-file' and Dired do."
  (let ((file (concat nsenter-test-directory "visit.txt"))
        (on-host (concat nsenter-test-directory-on-host "visit.txt")))
    (with-temp-file on-host (insert "one\n"))
    (let ((buffer (find-file-noselect file)))
      (unwind-protect
          (with-current-buffer buffer
            (should (equal buffer-file-name file))
            (should (equal (buffer-string) "one\n"))
            (goto-char (point-max))
            (insert "two\n")
            (save-buffer)
            (should (equal (nsenter-test-read on-host) "one\ntwo\n"))
            (should (verify-visited-file-modtime buffer))
            (sleep-for 1.1)
            (with-temp-file on-host (insert "changed\n"))
            (should-not (verify-visited-file-modtime buffer)))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))
    (should (member file (directory-files nsenter-test-directory t "visit")))
    (should (file-exists-p file))
    (should (file-regular-p file))
    (with-current-buffer (dired-noselect nsenter-test-directory)
      (unwind-protect (should (string-search "visit.txt" (buffer-string)))
        (kill-buffer)))))

(ert-deftest nsenter-test-files-only-inside ()
  "A /ns: name of a file that only the environment has, like the marker."
  (nsenter-test-in-directory
    (let* ((inside (string-trim (shell-command-to-string
                                 (concat "command -v " nsenter-test-marker))))
           (file (concat "/ns:test:" inside)))
      (should (string-suffix-p nsenter-test-marker inside))
      (should (file-executable-p file))
      (should-not (file-exists-p inside))
      (should (equal (executable-find nsenter-test-marker t) inside))
      ;; Links resolve inside, so the result is a /ns: name too.
      (should (string-prefix-p "/ns:test:/" (file-truename "/ns:test:/bin/sh")))
      (should (file-executable-p (file-truename "/ns:test:/bin/sh"))))))

(ert-deftest nsenter-test-absolute-links ()
  "Absolute links name files inside, wherever they appear in a name."
  (nsenter-test-in-directory
    (let* ((inside (string-trim (shell-command-to-string
                                 (concat "command -v " nsenter-test-marker))))
           (link (concat nsenter-test-directory "program-link"))
           (directory-link (concat nsenter-test-directory "directory-link")))
      (make-symbolic-link inside link t)
      (make-symbolic-link (file-name-directory inside) directory-link t)
      (unwind-protect
          (progn
            (should (file-executable-p link))
            (should (equal (file-symlink-p link) inside))
            (should (equal (file-attribute-type (file-attributes link)) inside))
            (should (file-executable-p
                     (concat directory-link "/" nsenter-test-marker)))
            (delete-file link)
            (should-not (file-symlink-p link))
            (should (file-exists-p (concat "/ns:test:" inside))))
        (ignore-errors (delete-file link))
        (delete-file directory-link)))))

(ert-deftest nsenter-test-rename-link ()
  "Renaming a link renames the link, and leaves its target alone."
  (nsenter-test-in-directory
    (let ((target (concat nsenter-test-directory "rename-target"))
          (link (concat nsenter-test-directory "rename-link"))
          (renamed (concat nsenter-test-directory "rename-renamed")))
      (with-temp-file target (insert "x"))
      (make-symbolic-link "rename-target" link t)
      (unwind-protect
          (progn
            (rename-file link renamed t)
            (should (file-exists-p target))
            (should (equal (file-symlink-p renamed) "rename-target"))
            (should-not (file-symlink-p link)))
        (ignore-errors (delete-file renamed))
        (ignore-errors (delete-file link))
        (delete-file target)))))

(ert-deftest nsenter-test-home ()
  "In /ns:test:~/, the ~ is the home inside the environment."
  (should (equal (expand-file-name "/ns:test:~/")
                 (concat "/ns:test:"
                         (file-name-as-directory
                          (string-trim
                           (nsenter-test-in-directory
                             (shell-command-to-string "echo $HOME"))))))))

(ert-deftest nsenter-test-terminal ()
  "A shell on a pty gets job control, ^C, window sizes and its exit status."
  (nsenter-test-in-directory
    (let* ((output "")
           (shell (make-process
                   :name "shell" :connection-type 'pty :file-handler t
                   :command '("sh" "-i")
                   :filter (lambda (_ string)
                             (setq output (concat output string))))))
      (set-process-window-size shell 33 101)
      (process-send-string shell "PS1='PROMPT> '; stty size\n")
      (nsenter-test-wait (lambda () (string-search "33 101" output)))
      (setq output "")
      (process-send-string shell "sleep 100; echo AFTER\n")
      (sleep-for 0.3)
      (interrupt-process shell t)
      (nsenter-test-wait (lambda () (string-search "PROMPT> " output)))
      (should-not (string-search "AFTER" output))
      (process-send-string shell "exit 3\n")
      (nsenter-test-wait (lambda () (not (process-live-p shell))))
      (should (= 3 (process-exit-status shell))))))

(ert-deftest nsenter-test-eshell ()
  "Eshell finds and runs the programs inside."
  (nsenter-test-in-directory
    (should (string-match-p nsenter-test-marker
                            (eshell-command-result
                             (concat "which " nsenter-test-marker))))
    (should (equal (string-trim (eshell-command-result "*sh -c 'echo inside'"))
                   "inside"))))

(ert-deftest nsenter-test-compile ()
  "A compilation runs inside."
  (nsenter-test-in-directory
    (let* ((buffer (compilation-start
                    (concat "command -v " nsenter-test-marker)))
           (process (get-buffer-process buffer)))
      (nsenter-test-wait (lambda () (not (process-live-p process))))
      (should (= 0 (process-exit-status process)))
      (should (with-current-buffer buffer
                (string-match-p (concat "/" nsenter-test-marker)
                                (buffer-string))))
      (kill-buffer buffer))))

(ert-deftest nsenter-test-completion ()
  "/ns: completes to the environments, and their files complete inside."
  ;; As while reading a file name in the minibuffer.
  (let ((minibuffer-completing-file-name t))
    (should (equal (try-completion "/ns:" #'read-file-name-internal)
                   "/ns:test:"))
    (should (member "usr/" (all-completions "/ns:test:/u"
                                            #'read-file-name-internal)))))

(ert-deftest nsenter-test-unstarted-environment ()
  "A configured environment that has not started does not break results."
  (let ((nsenter-environments (cons '("never-started" :enter ("false"))
                                    nsenter-environments)))
    (nsenter-test-in-directory
      (should (listp (directory-files nsenter-test-directory t))))))

;;; nsenter-scenarios-test.el ends here
