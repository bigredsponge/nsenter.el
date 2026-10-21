;;; nsenter-operations-test.el --- One test per file name operation -*- lexical-binding: t; -*-

;;; Commentary:

;; Every operation that a file name handler can receive is listed in exactly
;; one of the tables of nsenter.el, and every listed operation has a test of
;; its own, run in a fresh directory.

;;; Code:

(require 'nsenter-test-helpers)

;;;; Every operation that Emacs's handlers implement is classified

(defconst nsenter-test-not-operations '(identity file-file-equal-p)
  "Keys of TRAMP's own handler tables that name no operation.
`file-file-equal-p' is a typo in tramp-smb.el, and `identity' is in
tramp-gvfs.el.")

(defun nsenter-test-known-operations ()
  "The operations that the handler tables shipped with Emacs implement.
There is no variable listing all operations a handler may receive, but
TRAMP's backends together implement all of them, and some of their own,
named tramp-*."
  (dolist (feature '(tramp-sh tramp-sshfs tramp-adb tramp-androidsu
                     tramp-archive tramp-crypt tramp-gvfs tramp-rclone
                     tramp-smb tramp-sudoedit))
    (require feature nil t))
  (let (operations)
    (mapatoms
     (lambda (symbol)
       (when (and (boundp symbol)
                  (string-suffix-p "-file-name-handler-alist"
                                   (symbol-name symbol))
                  (consp (symbol-value symbol))
                  (consp (car (symbol-value symbol))))
         (dolist (entry (symbol-value symbol))
           (when (symbolp (car entry)) (push (car entry) operations))))))
    (seq-remove (lambda (operation)
                  (or (string-prefix-p "tramp-" (symbol-name operation))
                      (memq operation nsenter-test-not-operations)))
                (delete-dups operations))))

(defconst nsenter-test-operations-since-30
  '(file-group-gid file-user-uid)
  "Operations that Emacs 30 added, which Emacs 29 does not define.")

(defun nsenter-test-classified-operations ()
  "The operations of the three tables of nsenter.el."
  (append (mapcar #'car nsenter--custom-operations)
          nsenter--translated-operations
          nsenter--raw-operations))

(ert-deftest nsenter-test-operations-classified ()
  "Each operation is in exactly one table, so new ones in Emacs are noticed."
  (let ((classified (nsenter-test-classified-operations)))
    (should-not (seq-remove (lambda (operation) (memq operation classified))
                            (nsenter-test-known-operations)))
    (should (= (length classified)
               (length (delete-dups (copy-sequence classified)))))
    (should-not (seq-remove #'fboundp
                            (seq-difference classified
                                            nsenter-test-operations-since-30)))
    (should-not (seq-difference nsenter--translated-link-operations
                                nsenter--translated-operations))))

(ert-deftest nsenter-test-unknown-operation ()
  "An operation that no table lists signals an error naming it."
  (let ((error (should-error (nsenter--handler 'file-from-the-future
                                               "/ns:test:/x"))))
    (should (string-search "file-from-the-future"
                           (error-message-string error)))))


;;;; Every classified operation has a case

(defvar nsenter-test-operations nil
  "The operations that have a case so far.")

(defvar nsenter-test-counter 0
  "The number of fixtures made so far, which keeps their names apart.")

(defun nsenter-test-with-fixture (body)
  "Call BODY with the two names of a fresh directory: NS, then HOST.
NS is the directory's /ns: name, and the operation under test gets it.  HOST
is the host's name, which checks what the operation did without nsenter.el.
The directory holds a.txt, sub/b.txt, an executable run.sh, and a link to
a.txt.  `default-directory' is NS."
  (let* ((name (format "ops-%d-%d/" (emacs-pid)
                       (cl-incf nsenter-test-counter)))
         (host (concat nsenter-test-directory-on-host name))
         (ns (concat nsenter-test-directory name)))
    (make-directory (concat host "sub") t)
    (with-temp-file (concat host "a.txt") (insert "alpha\n"))
    (with-temp-file (concat host "sub/b.txt") (insert "beta\n"))
    (with-temp-file (concat host "run.sh") (insert "#!/bin/sh\n"))
    (set-file-modes (concat host "run.sh") #o755)
    (make-symbolic-link "a.txt" (concat host "link"))
    (unwind-protect
        (let ((default-directory ns))
          (funcall body ns host))
      (delete-directory host t))))

(defmacro nsenter-test-operation (operations &rest body)
  "Define the test of OPERATIONS, one symbol or a list, as BODY.
BODY runs in a fixture, and sees its two names as NS and HOST, see
`nsenter-test-with-fixture'.  Operations that this Emacs lacks are skipped."
  (declare (indent 1))
  (let ((operations (ensure-list operations)))
    `(progn
       (setq nsenter-test-operations
             (append ',operations nsenter-test-operations))
       (ert-deftest ,(intern (format "nsenter-test-operation-%s"
                                     (car operations)))
           ()
         (skip-unless (fboundp ',(car operations)))
         (nsenter-test-with-fixture
          (lambda (ns host) (ignore ns host) ,@body))))))

(ert-deftest nsenter-test-every-operation-has-a-case ()
  "The cases are exactly the operations of the three tables."
  (let ((classified (nsenter-test-classified-operations)))
    (should-not (seq-difference classified nsenter-test-operations))
    (should-not (seq-difference nsenter-test-operations classified))))

;;; Names

(nsenter-test-operation expand-file-name
  (should (equal (expand-file-name "x" ns) (concat ns "x")))
  (should (equal (expand-file-name "sub/../x" ns) (concat ns "x")))
  ;; A name absolute on its own stays a host's name.
  (should (equal (expand-file-name "/etc/hosts" ns) "/etc/hosts")))

(nsenter-test-operation directory-file-name
  (should (equal (directory-file-name ns) (substring ns 0 -1)))
  (should (equal (directory-file-name "/ns:test:/") "/ns:test:/")))

(nsenter-test-operation substitute-in-file-name
  (let ((process-environment (cons "NSENTER_TEST=zz" process-environment)))
    (should (equal (substitute-in-file-name (concat ns "$NSENTER_TEST"))
                   (concat ns "zz"))))
  ;; As in TRAMP, // and ~/ start again inside...
  (should (equal (substitute-in-file-name (concat ns "/bin/sh"))
                 "/ns:test:/bin/sh"))
  (should (equal (substitute-in-file-name (concat ns "~/x"))
                 "/ns:test:~/x"))
  ;; ...and /// or //~ on the host.
  (should (equal (substitute-in-file-name (concat ns "//etc/hosts"))
                 "/etc/hosts"))
  (should (equal (substitute-in-file-name (concat ns "/~/x")) "~/x")))

(nsenter-test-operation file-remote-p
  (should (equal (file-remote-p ns) "/ns:test:"))
  (should (equal (file-remote-p ns 'method) "ns"))
  (should (equal (file-remote-p ns 'host) "test"))
  (should (equal (file-local-name ns) (substring ns (length "/ns:test:"))))
  (should-not (file-remote-p "/tmp/")))

(nsenter-test-operation file-name-case-insensitive-p
  (should-not (file-name-case-insensitive-p ns)))

(nsenter-test-operation unhandled-file-name-directory
  (should (file-directory-p (unhandled-file-name-directory ns))))

(nsenter-test-operation file-truename
  (should (equal (file-truename (concat ns "link")) (concat ns "a.txt"))))

;;; Names that Emacs works out by itself

(nsenter-test-operation abbreviate-file-name
  (should (string-prefix-p "/ns:test:"
                           (abbreviate-file-name (concat ns "a.txt")))))

(nsenter-test-operation byte-compiler-base-file-name
  (should (stringp (byte-compiler-base-file-name (concat ns "a.txt")))))

(nsenter-test-operation file-name-as-directory
  (should (equal (file-name-as-directory (concat ns "sub")) (concat ns "sub/"))))

(nsenter-test-operation file-name-directory
  (should (equal (file-name-directory (concat ns "sub/b.txt"))
                 (concat ns "sub/")))
  ;; Without a path, the directory stays the environment's root.
  (should (equal (file-name-directory "/ns:test:") "/ns:test:"))
  (should (equal (file-name-directory "/ns:test:/") "/ns:test:/"))
  (should (equal (file-name-directory "/ns:test:foo") "/ns:test:")))

(nsenter-test-operation file-name-nondirectory
  (should (equal (file-name-nondirectory (concat ns "sub/b.txt")) "b.txt"))
  (should (equal (file-name-nondirectory "/ns:test:") ""))
  (should (equal (file-name-nondirectory "/ns:test:/") ""))
  (should (equal (file-name-nondirectory "/ns:test:foo") "foo")))

(nsenter-test-operation file-name-sans-versions
  (should (equal (file-name-sans-versions (concat ns "a.txt~"))
                 (concat ns "a.txt"))))

(nsenter-test-operation file-equal-p
  (should (file-equal-p (concat ns "a.txt") (concat ns "sub/../a.txt")))
  (should-not (file-equal-p (concat ns "a.txt") (concat ns "sub/b.txt"))))

(nsenter-test-operation file-in-directory-p
  (should (file-in-directory-p (concat ns "sub/b.txt") ns))
  (should-not (file-in-directory-p ns (concat ns "sub/")))
  (should-not (file-in-directory-p (concat ns "a.txt") "/ns:test:/usr/")))

;;; Looking at files

(nsenter-test-operation access-file
  (should-not (access-file (concat ns "a.txt") "cannot"))
  (should-error (access-file (concat ns "missing") "cannot") :type 'file-error))

(nsenter-test-operation file-exists-p
  (should (file-exists-p (concat ns "a.txt")))
  (should-not (file-exists-p (concat ns "missing"))))

(nsenter-test-operation file-regular-p
  (should (file-regular-p (concat ns "a.txt")))
  (should-not (file-regular-p (concat ns "sub"))))

(nsenter-test-operation file-directory-p
  (should (file-directory-p (concat ns "sub")))
  (should-not (file-directory-p (concat ns "a.txt"))))

(nsenter-test-operation file-accessible-directory-p
  (should (file-accessible-directory-p ns))
  (should-not (file-accessible-directory-p (concat ns "a.txt"))))

(nsenter-test-operation file-readable-p
  (should (file-readable-p (concat ns "a.txt")))
  (should-not (file-readable-p (concat ns "missing"))))

(nsenter-test-operation file-writable-p
  (should (file-writable-p (concat ns "a.txt")))
  (should (file-writable-p (concat ns "new-file"))))

(nsenter-test-operation file-executable-p
  (should (file-executable-p (concat ns "run.sh")))
  (should-not (file-executable-p (concat ns "a.txt"))))

(nsenter-test-operation file-symlink-p
  (should (equal (file-symlink-p (concat ns "link")) "a.txt"))
  (should-not (file-symlink-p (concat ns "a.txt"))))

(nsenter-test-operation file-attributes
  (let ((attributes (file-attributes (concat ns "a.txt"))))
    (should (= 6 (file-attribute-size attributes)))
    (should (equal (file-attribute-modes attributes)
                   (file-attribute-modes
                    (file-attributes (concat host "a.txt"))))))
  (should (equal (file-attribute-type (file-attributes (concat ns "link")))
                 "a.txt")))

(nsenter-test-operation file-modes
  (should (equal (file-modes (concat ns "a.txt"))
                 (file-modes (concat host "a.txt"))))
  (should (= #o755 (logand #o777 (file-modes (concat ns "run.sh"))))))

(nsenter-test-operation file-newer-than-file-p
  (set-file-times (concat host "a.txt") (time-add (current-time) 100))
  (should (file-newer-than-file-p (concat ns "a.txt") (concat ns "sub/b.txt")))
  (should-not (file-newer-than-file-p (concat ns "sub/b.txt")
                                      (concat ns "a.txt"))))

(nsenter-test-operation file-ownership-preserved-p
  (should (eq (file-ownership-preserved-p (concat ns "a.txt"))
              (file-ownership-preserved-p (concat host "a.txt")))))

(nsenter-test-operation file-system-info
  (should (equal (car (file-system-info ns)) (car (file-system-info host)))))

(nsenter-test-operation (file-selinux-context set-file-selinux-context)
  (let ((context (file-selinux-context (concat host "a.txt"))))
    (should (equal (file-selinux-context (concat ns "a.txt")) context))
    (should (equal (set-file-selinux-context (concat ns "a.txt") context)
                   (set-file-selinux-context (concat host "a.txt") context)))))

(nsenter-test-operation (file-acl set-file-acl)
  (let ((acl (file-acl (concat host "a.txt"))))
    (should (equal (file-acl (concat ns "a.txt")) acl))
    (should (equal (set-file-acl (concat ns "a.txt") acl)
                   (set-file-acl (concat host "a.txt") acl)))))

;;; Listing and completing

(nsenter-test-operation directory-files
  (should (equal (directory-files ns) (directory-files host)))
  (should (equal (directory-files ns t "\\.txt\\'") (list (concat ns "a.txt")))))

(nsenter-test-operation directory-files-and-attributes
  (let ((entries (directory-files-and-attributes ns nil "\\.txt\\'")))
    (should (equal (mapcar #'car entries) '("a.txt")))
    (should (= 6 (file-attribute-size (cdar entries))))))

(nsenter-test-operation file-name-all-completions
  (should (equal (sort (file-name-all-completions "" ns) #'string<)
                 (sort (file-name-all-completions "" host) #'string<))))

(nsenter-test-operation file-name-completion
  (should (equal (file-name-completion "a.t" ns) "a.txt"))
  (should (equal (file-name-completion "su" ns) "sub/")))

(nsenter-test-operation insert-directory
  (with-temp-buffer
    (insert-directory ns "-l" nil t)
    (should (string-search "a.txt" (buffer-string)))
    (should (string-search "sub" (buffer-string)))))

(nsenter-test-operation dired-uncache
  (should-not (dired-uncache ns)))

;;; Changing files

(nsenter-test-operation make-directory
  (make-directory (concat ns "new/deep") t)
  (should (file-directory-p (concat host "new/deep"))))

(nsenter-test-operation make-directory-internal
  ;; Emacs calls it after dispatching `make-directory', so no handler sees it.
  (make-directory (concat ns "internal"))
  (should (file-directory-p (concat host "internal"))))

(nsenter-test-operation delete-file
  (delete-file (concat ns "link"))
  (should-not (file-symlink-p (concat host "link")))
  (should (file-exists-p (concat host "a.txt"))))

(nsenter-test-operation delete-directory
  (delete-directory (concat ns "sub") t)
  (should-not (file-exists-p (concat host "sub"))))

(nsenter-test-operation copy-file
  (copy-file (concat ns "a.txt") (concat ns "copy.txt"))
  (should (equal (nsenter-test-read (concat host "copy.txt")) "alpha\n"))
  (let ((local (make-temp-file "nsenter-out")))
    (unwind-protect
        (progn
          (copy-file (concat ns "a.txt") local t)
          (should (equal (nsenter-test-read local) "alpha\n"))
          (with-temp-file local (insert "from outside\n"))
          (copy-file local (concat ns "in.txt"))
          (should (equal (nsenter-test-read (concat host "in.txt"))
                         "from outside\n")))
      (delete-file local))))

(nsenter-test-operation copy-directory
  (copy-directory (concat ns "sub") (concat ns "copy"))
  (should (equal (nsenter-test-read (concat host "copy/b.txt")) "beta\n")))

(nsenter-test-operation rename-file
  (rename-file (concat ns "a.txt") (concat ns "moved.txt"))
  (should (equal (nsenter-test-read (concat host "moved.txt")) "alpha\n"))
  (should-not (file-exists-p (concat host "a.txt"))))

(nsenter-test-operation add-name-to-file
  (add-name-to-file (concat ns "a.txt") (concat ns "hard"))
  (should (= 2 (file-attribute-link-number
                (file-attributes (concat host "a.txt"))))))

(nsenter-test-operation make-symbolic-link
  (make-symbolic-link "a.txt" (concat ns "link2"))
  (should (equal (file-symlink-p (concat host "link2")) "a.txt")))

(nsenter-test-operation set-file-modes
  (set-file-modes (concat ns "a.txt") #o600)
  (should (= #o600 (logand #o777 (file-modes (concat host "a.txt"))))))

(nsenter-test-operation set-file-times
  (set-file-times (concat ns "a.txt") 1700000000)
  (should (time-equal-p 1700000000
                        (file-attribute-modification-time
                         (file-attributes (concat host "a.txt"))))))

;;; Contents

(nsenter-test-operation insert-file-contents
  (with-temp-buffer
    (should (equal (cdr (insert-file-contents (concat ns "a.txt"))) '(6)))
    (should (equal (buffer-string) "alpha\n"))))

(nsenter-test-operation write-region
  (with-temp-buffer
    (insert "written\n")
    (write-region nil nil (concat ns "w.txt")))
  (should (equal (nsenter-test-read (concat host "w.txt")) "written\n")))

(nsenter-test-operation file-local-copy
  (let ((copy (file-local-copy (concat ns "a.txt"))))
    (unwind-protect
        (should (equal (nsenter-test-read copy) "alpha\n"))
      (delete-file copy))))

(nsenter-test-operation load
  ;; Only the compiled file tells a handled `load' from a raw one: Emacs cannot
  ;; open a compiled file through a name that is not a real path.
  (with-temp-file (concat host "load.el")
    (insert ";;; -*- lexical-binding: t -*-\n(setq nsenter-test-loaded 42)\n"))
  (let ((byte-compile-warnings nil))
    (byte-compile-file (concat host "load.el")))
  (unwind-protect
      (dolist (name '("load.el" "load"))
        (makunbound 'nsenter-test-loaded)
        (load (concat ns name) nil t)
        (should (equal (bound-and-true-p nsenter-test-loaded) 42)))
    (makunbound 'nsenter-test-loaded)))

(nsenter-test-operation (verify-visited-file-modtime set-visited-file-modtime
                  get-file-buffer)
  (let ((buffer (find-file-noselect (concat ns "a.txt"))))
    (unwind-protect
        (with-current-buffer buffer
          (should (eq buffer (get-file-buffer (concat ns "a.txt"))))
          (should (verify-visited-file-modtime buffer))
          (set-file-times (concat host "a.txt") (time-add (current-time) 100))
          (should-not (verify-visited-file-modtime buffer))
          (set-visited-file-modtime)
          (should (verify-visited-file-modtime buffer)))
      (kill-buffer buffer))))

;;; Backups and locks

(nsenter-test-operation find-backup-file-name
  (should (equal (find-backup-file-name (concat ns "a.txt"))
                 (list (concat ns "a.txt~")))))

(nsenter-test-operation diff-latest-backup-file
  (should-not (diff-latest-backup-file (concat ns "a.txt"))))

(nsenter-test-operation make-auto-save-file-name
  (with-temp-buffer
    (setq buffer-file-name (concat ns "a.txt"))
    ;; Emacs puts the auto-save files of remote files in a local directory.
    (let ((name (make-auto-save-file-name)))
      (should-not (file-remote-p name))
      (should (string-search "a.txt" name)))))

(nsenter-test-operation make-lock-file-name
  (should (equal (make-lock-file-name (concat ns "a.txt"))
                 (concat ns ".#a.txt"))))

(nsenter-test-operation (lock-file unlock-file file-locked-p)
  (let ((file (concat ns "a.txt")))
    (should-not (file-locked-p file))
    (lock-file file)
    (unwind-protect (should (file-locked-p file))
      (unlock-file file))
    (should-not (file-locked-p file))))

(nsenter-test-operation (file-notify-add-watch file-notify-rm-watch
                  file-notify-valid-p)
  (let* ((events nil)
         (descriptor (file-notify-add-watch ns '(change)
                                            (lambda (event)
                                              (push event events)))))
    (should (file-notify-valid-p descriptor))
    (with-temp-file (concat host "created.txt") (insert "x"))
    ;; Events are special input events, which only reading input delivers.
    (with-timeout (10 nil) (while (not events) (read-event nil nil 0.05)))
    (should events)
    ;; Events name files the way the watch was asked for them.
    (should (string-prefix-p ns (nth 2 (car events))))
    (file-notify-rm-watch descriptor)
    (should-not (file-notify-valid-p descriptor))))

(nsenter-test-operation dired-compress-file
  (let ((compressed (dired-compress-file (concat ns "a.txt"))))
    (should (equal compressed (concat ns "a.txt.gz")))
    (should (file-exists-p (concat host "a.txt.gz")))
    (should (equal (dired-compress-file compressed) (concat ns "a.txt")))
    (should (equal (nsenter-test-read (concat host "a.txt")) "alpha\n"))))

(nsenter-test-operation vc-registered
  (should-not (vc-registered (concat ns "a.txt"))))

;;; Temporary files

(nsenter-test-operation temporary-file-directory
  (should (equal (temporary-file-directory) "/ns:test:/tmp/")))

(nsenter-test-operation make-nearby-temp-file
  (let ((file (make-nearby-temp-file "nsenter-" nil ".txt")))
    (unwind-protect
        (progn (should (string-prefix-p "/ns:test:/tmp/nsenter-" file))
               (should (file-exists-p file)))
      (delete-file file))))

;;; Programs

(nsenter-test-operation exec-path
  (should (seq-some (lambda (directory) (string-match-p "/bin/?\\'" directory))
                    (exec-path))))

(nsenter-test-operation make-process
  (let* ((output "")
         (process (make-process
                   :name "nsenter-test" :command '("sh" "-c" "echo $((6*7))")
                   :connection-type 'pipe
                   :filter (lambda (_ string)
                             (setq output (concat output string))))))
    (nsenter-test-wait (lambda () (not (process-live-p process))))
    (should (equal output "42\n"))))

(nsenter-test-operation start-file-process
  (let* ((output "")
         (process (start-file-process "nsenter-test" nil "sh" "-c" "echo hi")))
    (set-process-filter process (lambda (_ string)
                                  (setq output (concat output string))))
    (nsenter-test-wait (lambda () (not (process-live-p process))))
    (should (equal output "hi\n"))))

(nsenter-test-operation process-file
  (with-temp-buffer
    (should (= 3 (process-file "sh" nil t nil "-c"
                               (concat "pwd; command -v " nsenter-test-marker
                                       "; exit 3"))))
    (should (equal (car (split-string (buffer-string) "\n"))
                   (directory-file-name host)))
    (should (string-match-p nsenter-test-marker (buffer-string))))
  ;; Standard error to a file, by its /ns: name.
  (with-temp-buffer
    (let ((errors (make-nearby-temp-file "errors")))
      (process-file "sh" nil (list t errors) nil
                    "-c" "echo out; echo error >&2")
      (should (equal (buffer-string) "out\n"))
      (should (equal (nsenter-test-read errors) "error\n")))))

(nsenter-test-operation shell-command
  (with-temp-buffer
    (shell-command "echo hello" t)
    (should (equal (buffer-string) "hello\n")))
  (should (string-match-p nsenter-test-marker
                          (shell-command-to-string
                           (concat "command -v " nsenter-test-marker)))))

;;; Asking about the machine

(nsenter-test-operation file-user-uid (should (integerp (file-user-uid))))
(nsenter-test-operation file-group-gid (should (integerp (file-group-gid))))
(nsenter-test-operation list-system-processes (should (consp (list-system-processes))))
(nsenter-test-operation memory-info (should (consp (memory-info))))
(nsenter-test-operation process-attributes
  (should (consp (process-attributes (emacs-pid)))))

;;; nsenter-operations-test.el ends here
