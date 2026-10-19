;;; nsenter.el --- Fast access to your Linux namespaces -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "29.1"))

;;; Commentary:

;; See README.md.

;;; Code:

(require 'subr-x)

;;; Options

(defgroup nsenter nil
  "Fast access to your Linux namespaces."
  :group 'processes)

(defcustom nsenter-environments nil
  "Alist of (NAME :enter COMMAND), the environments that /ns:NAME: names.
COMMAND is prepended to the desired command so that the desired command runs
inside the namespace, for example \(\"distrobox\" \"enter\" \"mybox\" \"--\")."
  :type '(alist :key-type string :value-type plist)
  :group 'nsenter)

(defcustom nsenter-start-timeout 120
  "Seconds to wait for the process inside an environment to start."
  :type 'number
  :group 'nsenter)

;;; Names

;; A name /ns:NAME:PATH stands for PATH inside the environment NAME, where an
;; empty PATH is the home directory, as in TRAMP.  The handler performs most
;; operations by calling Emacs again on other names, and must then keep Emacs
;; from handing the call straight back.  `nsenter--apply-operation-bare' does
;; that the way TRAMP's `tramp-run-real-handler' does: it inhibits the
;; handlers for that one operation only, so that the calls the operation makes
;; in turn still find their handlers.

(defconst nsenter--environment-prefix-regexp
  (rx bos "/ns:" (group (+ (not (in "/:|")))) ":")
  "Matches the /ns:NAME: that starts a name, with NAME as the first group.")

(defun nsenter--split-name (file)
  "Return (NAME . PATH) for FILE, a /ns:NAME:PATH name, or nil."
  (when (and (stringp file)
             (string-match nsenter--environment-prefix-regexp file))
    (cons (match-string 1 file)
          (let ((path (substring file (match-end 0))))
            (if (string-empty-p path) "~/" path)))))

(defun nsenter--environment-prefix (environment)
  "Return /ns:ENVIRONMENT:, the start of the names inside ENVIRONMENT."
  (concat "/ns:" environment ":"))

(defun nsenter--apply-operation-bare (operation arguments)
  "Call OPERATION with ARGUMENTS as if no file name handler matched."
  (let ((inhibit-file-name-handlers (mapcar #'cdr file-name-handler-alist))
        (inhibit-file-name-operation operation))
    (apply operation arguments)))

;;; Environments

;; Everything rests on one process per environment: the :enter command starts
;; "sh -c 'echo \"$0\"; read _' 'nsenter EMACS-PID NAME'" inside it, and that
;; shell lives until Emacs exits and closes its input.  What the host needs is
;; that process's pid, since /proc/PID/root reaches its files and nsenter joins
;; its namespaces.  Nothing hands the pid over: the process Emacs started is
;; the :enter command, a client such as podman exec whose child may belong to
;; a daemon, and the shell inside sees only the pid its own namespace gives it.
;; So the shell announces itself by printing its last argument, which is
;; unique to this Emacs, and the host then finds the process whose command line
;; is exactly that command.  The pid is remembered on the Emacs process, so it
;; is found again only after the environment restarts.

(define-error 'nsenter-environment-unavailable
  "Environment did not start")

(defun nsenter--environment-process-name (environment)
  "Return the name of the Emacs process inside ENVIRONMENT."
  (concat "nsenter " environment))

(defun nsenter--environment-process-command (environment)
  "Return the command that the process inside ENVIRONMENT runs."
  `("sh" "-c" "echo \"$0\"; read _"
    ,(format "nsenter %d %s" (emacs-pid) environment)))

(defun nsenter--environment-started-p (process line)
  "Return whether PROCESS has printed LINE."
  (with-current-buffer (process-buffer process)
    (save-excursion
      (goto-char (point-min))
      (search-forward (concat line "\n") nil t))))

(defun nsenter--environment-cmdline (pid)
  "Return the command line of host process PID, as bytes, or nil."
  (ignore-errors
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally (format "/proc/%d/cmdline" pid))
      (buffer-string))))

(defun nsenter--environment-find-pid (command)
  "Return the pid of a host process running COMMAND, or nil."
  ;; /proc/PID/cmdline holds each argument followed by a NUL byte, see proc(5).
  (let* ((joined (concat (string-join command "\0") "\0"))
         (cmdline (encode-coding-string joined 'utf-8))
         (pids (mapcar #'string-to-number
                       (directory-files "/proc" nil "\\`[0-9]+\\'"))))
    (seq-find (lambda (pid)
                (equal cmdline (nsenter--environment-cmdline pid)))
              pids)))

(defun nsenter--environment-process (environment)
  "Return the live process inside ENVIRONMENT, starting the process if needed."
  (let* ((name (nsenter--environment-process-name environment))
         (old (get-process name)))
    (if (process-live-p old)
        old
      ;; A dead process keeps its name, and `make-process' would then pick
      ;; another one, like "nsenter box<2>".
      (when old (delete-process old))
      ;; Background code, like saveplace, binds `non-essential' so as not to
      ;; wait for connections.
      (when non-essential
        (throw 'nsenter-non-essential 'nsenter-non-essential))
      (let* ((settings (alist-get environment nsenter-environments
                                  nil nil #'equal))
             (enter (plist-get settings :enter))
             (process-command
              (nsenter--environment-process-command environment))
             (default-directory (expand-file-name "~/"))
             (process (make-process
                       :name name
                       :buffer (generate-new-buffer (concat " *" name "*"))
                       :command (append enter process-command)
                       :connection-type 'pipe
                       :noquery t)))
        (process-put process 'nsenter-environment environment)
        process))))

(defun nsenter--environment-connected-p (environment)
  "Return whether the process inside ENVIRONMENT runs."
  (process-live-p
   (get-process (nsenter--environment-process-name environment))))

(defun nsenter--environment-output (process)
  "Return what PROCESS has printed."
  (with-current-buffer (process-buffer process)
    (buffer-string)))

(defun nsenter--environment-last-line (process)
  "Return the last line that PROCESS has printed, or nil."
  (car (last (split-string (nsenter--environment-output process) "\n" t
                           "[[:space:]]+"))))

(defun nsenter--environment-pid (environment)
  "Return the host pid of the process inside ENVIRONMENT."
  (let ((process (nsenter--environment-process environment)))
    (with-memoization (process-get process 'nsenter-pid)
      (let* ((command (nsenter--environment-process-command environment))
             (line (car (last command)))
             (reporter (make-progress-reporter
                        (format "Entering %s..." environment)))
             (started nil))
        (unwind-protect
            (with-timeout (nsenter-start-timeout
                           (signal 'nsenter-environment-unavailable
                                   (list environment
                                         (nsenter--environment-output
                                          process))))
              (while (and (process-live-p process)
                          (not (setq started (nsenter--environment-started-p
                                              process line))))
                ;; Without a timeout, Emacs warns of a blocking call whenever
                ;; a timer opens a file, as timers inhibit quitting.
                (accept-process-output process 0.1)
                ;; The :enter command may print its own progress first, or
                ;; wait for an answer that it asks for, which shows here.
                (progress-reporter-update
                 reporter nil (nsenter--environment-last-line process))
                ;; Emacs would not show it while a command, like `find-file'
                ;; checking its minibuffer, keeps running.
                (redisplay)))
          ;; Otherwise `nsenter--environment-process' would find a process
          ;; stuck after a quit or the timeout, and wait for it again.
          (unless started
            (delete-process process)))
        (progress-reporter-done reporter)
        (or (nsenter--environment-find-pid command)
            (signal 'nsenter-environment-unavailable
                    (list environment
                          (nsenter--environment-output process))))))))

(defun nsenter--environment-of-pid (pid)
  "Return the environment whose process inside has host pid PID."
  (seq-some (lambda (process)
              (and (eql (process-get process 'nsenter-pid) pid)
                   (process-get process 'nsenter-environment)))
            (process-list)))

(defun nsenter--environment-variables (environment current initial)
  "Return the variables for programs inside ENVIRONMENT.
Those are the variables of the process inside, which entering produced, plus
what CURRENT adds to INITIAL, both lists like `process-environment'.  PATH
stays the one inside, where the programs are, and PWD is left out, since the
directory inside differs from the one in Emacs."
  (let* ((pid (nsenter--environment-pid environment))
         (environ (format "/proc/%d/environ" pid))
         (contents (with-temp-buffer
                     (insert-file-contents-literally environ)
                     (buffer-string)))
         (inside (split-string contents "\0" t))
         (changed (seq-difference current initial))
         (changed-but-path (seq-remove (lambda (variable)
                                         (string-prefix-p "PATH=" variable))
                                       changed)))
    (seq-remove (lambda (variable) (string-prefix-p "PWD=" variable))
                (append changed-but-path inside))))

(defun nsenter--environment-program-command
    (environment directory program arguments)
  "Return the nsenter command that runs PROGRAM with ARGUMENTS in ENVIRONMENT.
DIRECTORY is the working directory inside.  The command itself starts on the
host, so run it from a directory of the host."
  (let* ((pid (number-to-string (nsenter--environment-pid environment)))
         ;; setns(2) fails with EINVAL for the user namespace the caller is
         ;; already in, as when the environment shares the host's; the links
         ;; name their namespace, like "user:[4026531837]".
         (own-user-namespace
          (equal (file-symlink-p (format "/proc/%s/ns/user" pid))
                 (file-symlink-p "/proc/self/ns/user"))))
    `("nsenter" "-t" ,pid "-m" "-r" "--preserve-credentials"
      ;; --wd would name the directory as the host sees it, --wdns as the
      ;; target's mount namespace does, see nsenter(1).
      ,(concat "--wdns=" directory)
      ,@(unless own-user-namespace '("-U"))
      "--"
      ,(or (cdr (nsenter--split-name program)) program)
      ,@arguments)))

(defun nsenter--environment-home (environment user)
  "Return the home of USER inside ENVIRONMENT, as a shell there expands ~USER.
An empty USER is the user inside, as for ~ alone."
  ;; USER goes into a shell command, so it must not hold anything but a name.
  (unless (string-match-p (rx bos (* (in alnum "._-")) eos) user)
    (error "Cannot expand tilde for user `%s'" user))
  (let ((process (nsenter--environment-process environment)))
    (with-memoization (alist-get user (process-get process 'nsenter-homes)
                                 nil nil #'equal)
      (let* ((echo (list "-c" (concat "echo ~" user)))
             (command (nsenter--environment-program-command
                       environment "/" "sh" echo))
             (process-environment
              (nsenter--environment-variables
               environment process-environment initial-environment))
             (default-directory temporary-file-directory)
             (output (with-temp-buffer
                       (apply #'call-process (car command) nil '(t nil) nil
                              (cdr command))
                       (buffer-string)))
             (home (string-trim-right output)))
        ;; A shell prints ~USER back unchanged for a user it does not know.
        (unless (file-name-absolute-p home)
          (error "Cannot expand tilde for user `%s'" user))
        home))))

;;; Host names

;; The host reaches /path inside an environment as /proc/PID/root/path, so
;; most operations only need that name.  Symbolic links are the catch.  A
;; relative link resolves the same way from either side, but an absolute one
;; does not: if /proc/PID/root/etc/hosts links to /run/hosts, following it on
;; the host leads to the host's own /run/hosts.  So translation resolves links
;; itself, running `file-truename' with a handler that answers
;; `file-symlink-p' as the host does, except that it puts absolute targets
;; under /proc/PID/root, and says /proc/PID/root itself is no link, since it
;; links to the host's root.  The way back looks up which environment has the
;; pid in /proc/PID/root.

(defun nsenter--inside-path (environment path)
  "Return PATH, a path inside ENVIRONMENT, made absolute."
  (pcase path
    ((rx bos "~" (let user (* (not "/"))) (let rest (* anything)))
     (nsenter--inside-path
      environment (concat (nsenter--environment-home environment user) rest)))
    (_ (nsenter--apply-operation-bare 'expand-file-name (list path "/")))))

(defun nsenter--translate-symlink-handler (root)
  "Return a file name handler that keeps symlinks under ROOT inside ROOT."
  (lambda (operation &rest arguments)
    (let ((bare (nsenter--apply-operation-bare operation arguments)))
      (cond ((not (eq operation 'file-symlink-p)) bare)
            ((equal (directory-file-name (car arguments)) root) nil)
            ((and bare (file-name-absolute-p bare)) (concat root bare))
            (t bare)))))

(defun nsenter--translate-to-host (file &optional nofollow)
  "Return the host name of FILE, a /ns: name, or FILE itself.
With NOFOLLOW, do not follow a symlink at the end of FILE."
  (pcase (nsenter--split-name file)
    (`(,environment . ,path)
     (let* ((pid (nsenter--environment-pid environment))
            (root (format "/proc/%d/root" pid))
            (inside (nsenter--inside-path environment path))
            (host-file (concat root inside))
            (under-root (rx bos (literal root) (or "/" eos)))
            (handler (nsenter--translate-symlink-handler root))
            (file-name-handler-alist (list (cons under-root handler))))
       (if nofollow
           (concat (file-truename (file-name-directory host-file))
                   (file-name-nondirectory host-file))
         (file-truename host-file))))
    (_ file)))

(defun nsenter--translate-from-host (value)
  "Return VALUE with each host name in VALUE as a /ns: name again.
VALUE is the result of an operation: a name, a list of names, as from
`directory-files', or lists within lists, as from
`directory-files-and-attributes'."
  (pcase value
    ((pred consp) (cons (nsenter--translate-from-host (car value))
                        (nsenter--translate-from-host (cdr value))))
    ((rx bos "/proc/" (let pid (+ digit)) "/root"
         (let rest (or (seq "/" (* anything)) eos)))
     (if-let* ((environment (nsenter--environment-of-pid
                             (string-to-number pid))))
         (concat (nsenter--environment-prefix environment) rest)
       value))
    (_ value)))

;;; Custom operations

;; The operations that `nsenter--handler' cannot route by table.  Each one is
;; named after the Emacs operation it stands in for.

;;;; Names

;; These work on names alone.  Translated, they would answer with host names;
;; raw, they would treat /ns:NAME: as part of an ordinary path.

(defun nsenter--expand-file-name (name &optional directory)
  "Like `expand-file-name' for NAME in DIRECTORY.
A NAME absolute on its own, like /etc/hosts, stays a name of the host."
  (let ((absolute (if (file-name-absolute-p name)
                      name
                    (concat (file-name-as-directory
                             (or directory default-directory))
                            name))))
    (pcase (nsenter--split-name absolute)
      (`(,environment . ,path)
       (concat (nsenter--environment-prefix environment)
               (nsenter--inside-path environment path)))
      ;; `expand-file-name' also consults the handler of `default-directory',
      ;; which would be this one again.
      (_ (let ((file-name-handler-alist nil))
           (expand-file-name absolute))))))

(defun nsenter--directory-file-name (directory)
  "Like `directory-file-name' for DIRECTORY."
  ;; Not `nsenter--split-name', which reads an empty path as ~/.
  (string-match nsenter--environment-prefix-regexp directory)
  (concat (match-string 0 directory)
          (directory-file-name (substring directory (match-end 0)))))

(defun nsenter--file-name-directory (file)
  "Like `file-name-directory' for FILE.
Raw, the directory of /ns:NAME: would be /, as /ns:NAME: has no slash."
  (string-match nsenter--environment-prefix-regexp file)
  (concat (match-string 0 file)
          (file-name-directory (substring file (match-end 0)))))

(defun nsenter--file-name-nondirectory (file)
  "Like `file-name-nondirectory' for FILE."
  (string-match nsenter--environment-prefix-regexp file)
  (file-name-nondirectory (substring file (match-end 0))))

(defun nsenter--file-remote-p (file &optional identification connected)
  "Like `file-remote-p' for FILE, IDENTIFICATION and CONNECTED."
  (pcase-let ((`(,environment . ,path) (nsenter--split-name file)))
    (when (or (not connected) (nsenter--environment-connected-p environment))
      (pcase identification
        ('method "ns")
        ('host environment)
        ('localname path)
        ((or 'user 'hop) nil)
        (_ (nsenter--environment-prefix environment))))))

(defun nsenter--file-truename (file)
  "Like `file-truename' for FILE.
Translated, the host's `file-truename' would follow /proc/PID/root out to /."
  (nsenter--translate-from-host
   (nsenter--translate-to-host (nsenter--expand-file-name file))))

;;;; Files

;; These move bytes through the host's name for a file, but keep the /ns:
;; name wherever Emacs remembers the file, as in `buffer-file-name'.

(defun nsenter--insert-file-contents (file &optional visit beg end replace)
  "Like `insert-file-contents' for FILE, VISIT, BEG, END and REPLACE.
Translated, the buffer would visit the host name of FILE."
  (let ((expanded (expand-file-name file)))
    (unwind-protect
        (cons expanded
              (cdr (insert-file-contents (nsenter--translate-to-host expanded)
                                         visit beg end replace)))
      (when visit (setq buffer-file-name expanded)))))

(defun nsenter--write-region
    (start end file &optional append visit lockname mustbenew)
  "Like `write-region' for START, END, FILE, APPEND, VISIT, LOCKNAME, MUSTBENEW.
Translated, a VISIT of t would make the buffer visit the host name of FILE, so
VISIT becomes FILE itself, which Emacs hands to the handler again unless the
call skips the handlers."
  (let ((expanded (expand-file-name file)))
    (nsenter--apply-operation-bare
     'write-region
     (list start end (nsenter--translate-to-host expanded) append
           (if (eq visit t) expanded visit) lockname mustbenew))))

(defun nsenter--verify-visited-file-modtime (&optional buffer)
  "Like `verify-visited-file-modtime' for BUFFER.
Emacs checks the file that the variable `buffer-file-name' names, so for as
long as it checks, that is the host name."
  (with-current-buffer (or buffer (current-buffer))
    (let ((buffer-file-name (nsenter--translate-to-host buffer-file-name)))
      (verify-visited-file-modtime))))

(defun nsenter--set-visited-file-modtime (&optional time)
  "Like `set-visited-file-modtime' for TIME.
Without TIME, Emacs reads the file that the variable `buffer-file-name' names,
as in `nsenter--verify-visited-file-modtime'."
  (let ((buffer-file-name (nsenter--translate-to-host buffer-file-name)))
    (set-visited-file-modtime time)))

(defun nsenter--file-local-copy (file)
  "Like `file-local-copy' for FILE.
Translated, the host name is already local, so the answer would be nil, which
tells the caller to use the /ns: name itself."
  (let ((copy (make-temp-file "nsenter-" nil (file-name-extension file t))))
    (copy-file (nsenter--translate-to-host file) copy t 'keep-time)
    copy))

(defun nsenter--make-symbolic-link (target link &optional ok-if-already-exists)
  "Like `make-symbolic-link' for TARGET, LINK and OK-IF-ALREADY-EXISTS.
TARGET is the text that the link holds, which is read inside, so a TARGET in
the environment of LINK loses its /ns: prefix."
  (pcase-let ((`(,target-environment . ,target-path)
               (nsenter--split-name target)))
    (make-symbolic-link (if (equal target-environment
                                   (car (nsenter--split-name link)))
                            target-path
                          target)
                        (nsenter--translate-to-host link t)
                        ok-if-already-exists)))

(defun nsenter--temporary-file-directory ()
  "Like the function `temporary-file-directory'.
That is the /tmp inside, where programs inside find what Emacs puts there."
  (pcase-let ((`(,environment . ,_) (nsenter--split-name default-directory)))
    (concat (nsenter--environment-prefix environment) "/tmp/")))

;;;; Programs

;; Every program starts on the host as nsenter, which joins the namespaces of
;; the process inside, with the variables of that process and with
;; `default-directory' as the environment names it.  Emacs itself, though, must
;; start nsenter from a directory of the host, which a /ns: name is not.

(defun nsenter--exec-path ()
  "Like the function `exec-path'.
That is the PATH inside, then the working directory inside, which Eshell drops,
taking the last element for the directory of Emacs, as with TRAMP."
  (pcase-let* ((`(,environment . ,path)
                (nsenter--split-name default-directory))
               (variables
                (nsenter--environment-variables
                 environment process-environment initial-environment)))
    (append (parse-colon-path (getenv-internal "PATH" variables))
            (list (nsenter--inside-path environment path)))))

(defun nsenter--make-process (&rest arguments)
  "Like `make-process' for ARGUMENTS."
  (pcase-let* ((`(,environment . ,path)
                (nsenter--split-name (expand-file-name default-directory)))
               (`(,program . ,program-arguments) (plist-get arguments :command))
               (inside (nsenter--inside-path environment path))
               (command (nsenter--environment-program-command
                         environment inside program program-arguments))
               (process-environment
                (nsenter--environment-variables
                 environment process-environment initial-environment))
               (default-directory temporary-file-directory))
    ;; `make-process' reads the first :command, so this one wins.
    (apply #'make-process :command command arguments)))

(defun nsenter--start-file-process (name buffer program &rest arguments)
  "Like `start-file-process' for NAME, BUFFER, PROGRAM and ARGUMENTS."
  (nsenter--make-process
   :name name :buffer buffer :command (cons program arguments)))

(defun nsenter--process-file
    (program &optional infile destination display &rest arguments)
  "Like `process-file' for PROGRAM, INFILE, DESTINATION, DISPLAY, ARGUMENTS.
INFILE and a file in DESTINATION are /ns: names, which the host reads and
writes by their host names."
  (pcase-let* ((`(,environment . ,path)
                (nsenter--split-name (expand-file-name default-directory)))
               (host-infile (and infile (nsenter--translate-to-host
                                         (expand-file-name infile))))
               (error-file (and (consp destination) (stringp (cadr destination))
                                (cadr destination)))
               (host-error-file
                (and error-file (nsenter--translate-to-host
                                 (expand-file-name error-file))))
               (host-destination (if host-error-file
                                     (list (car destination) host-error-file)
                                   destination))
               (inside (nsenter--inside-path environment path))
               (command (nsenter--environment-program-command
                         environment inside program arguments))
               (process-environment
                (nsenter--environment-variables
                 environment process-environment initial-environment))
               (default-directory temporary-file-directory))
    (apply #'call-process (car command) host-infile host-destination
           display (cdr command))))

(declare-function tramp-handle-shell-command "tramp")

(defun nsenter--shell-command (command &optional output-buffer error-buffer)
  "Like `shell-command' for COMMAND, OUTPUT-BUFFER and ERROR-BUFFER.
Emacs's own would run the shell on the host; TRAMP's runs it through
`process-file' and `start-file-process', and so through the handler."
  (require 'tramp)
  (tramp-handle-shell-command command output-buffer error-buffer))

;;; Routing

;; Emacs hands every operation on a /ns: name to `nsenter--handler', which
;; performs it by the table that lists it.  Every operation that Emacs or
;; TRAMP's backends know is in exactly one table, which the tests check, so an
;; operation that newer Emacs adds signals an error rather than being guessed.

(defconst nsenter--custom-operations
  '((expand-file-name . nsenter--expand-file-name)
    (directory-file-name . nsenter--directory-file-name)
    (file-name-directory . nsenter--file-name-directory)
    (file-name-nondirectory . nsenter--file-name-nondirectory)
    (file-remote-p . nsenter--file-remote-p)
    (file-truename . nsenter--file-truename)
    (unhandled-file-name-directory . nsenter--translate-to-host)
    (insert-file-contents . nsenter--insert-file-contents)
    (write-region . nsenter--write-region)
    (verify-visited-file-modtime . nsenter--verify-visited-file-modtime)
    (set-visited-file-modtime . nsenter--set-visited-file-modtime)
    (file-local-copy . nsenter--file-local-copy)
    (make-symbolic-link . nsenter--make-symbolic-link)
    (temporary-file-directory . nsenter--temporary-file-directory)
    (exec-path . nsenter--exec-path)
    (make-process . nsenter--make-process)
    (start-file-process . nsenter--start-file-process)
    (process-file . nsenter--process-file)
    (shell-command . nsenter--shell-command))
  "Operations with logic of their own, and the functions that perform them.")

(defconst nsenter--translated-operations
  '(access-file add-name-to-file copy-directory copy-file delete-directory
    delete-file directory-files directory-files-and-attributes dired-uncache
    file-accessible-directory-p file-acl file-attributes file-directory-p
    file-executable-p file-exists-p file-locked-p file-modes
    file-name-all-completions file-name-case-insensitive-p file-name-completion
    file-newer-than-file-p file-notify-add-watch file-ownership-preserved-p
    file-readable-p file-regular-p file-selinux-context file-symlink-p
    file-system-info file-writable-p find-backup-file-name insert-directory
    load lock-file make-directory make-lock-file-name rename-file set-file-acl
    set-file-modes set-file-selinux-context set-file-times unlock-file)
  "Operations on the host names of their arguments.
Their results are translated back.")

(defconst nsenter--translated-link-operations
  '(file-symlink-p file-attributes delete-file rename-file)
  "Translated operations that act on a symbolic link itself, not its target.")

(defconst nsenter--raw-operations
  '(abbreviate-file-name byte-compiler-base-file-name diff-latest-backup-file
    dired-compress-file file-equal-p file-group-gid file-in-directory-p
    file-name-as-directory file-name-sans-versions file-notify-rm-watch
    file-notify-valid-p file-user-uid get-file-buffer list-system-processes
    make-auto-save-file-name make-directory-internal make-nearby-temp-file
    memory-info process-attributes substitute-in-file-name vc-registered)
  "Operations that need no translation.
They only take names apart, or ask about the host.")

(defun nsenter--handler (operation &rest arguments)
  "Perform OPERATION on ARGUMENTS by the table that lists OPERATION.
If that would start an environment while `non-essential' is non-nil,
perform OPERATION as if there were no handler, as TRAMP does."
  (let ((result (catch 'nsenter-non-essential
                  (list (apply #'nsenter--perform operation arguments)))))
    (if (eq result 'nsenter-non-essential)
        (nsenter--apply-operation-bare operation arguments)
      (car result))))

(defun nsenter--perform (operation &rest arguments)
  "Perform OPERATION on ARGUMENTS by the table that lists OPERATION."
  (let ((custom (alist-get operation nsenter--custom-operations))
        (nofollow (memq operation nsenter--translated-link-operations)))
    (cond (custom (apply custom arguments))
          ((memq operation nsenter--translated-operations)
           (nsenter--translate-from-host
            (apply operation
                   (mapcar (lambda (argument)
                             (nsenter--translate-to-host argument nofollow))
                           arguments))))
          ((memq operation nsenter--raw-operations)
           (nsenter--apply-operation-bare operation arguments))
          (t (error "No nsenter rule for the operation `%s'" operation)))))

;;; Registering

;; Emacs tries the entries of `file-name-handler-alist' in order, and TRAMP's
;; match /ns: names too, so the handler goes first, and back to the front
;; whenever TRAMP registers its handlers again.  TRAMP's conventions still
;; apply to /ns: names where TRAMP looks at them: it knows "ns" as a method,
;; so code that takes names apart with TRAMP works, and TRAMP completes
;; /ns: with the names of the environments.

(defun nsenter--register (&rest _)
  "Put `nsenter--handler' first in `file-name-handler-alist'."
  (setq file-name-handler-alist
        (cons (cons nsenter--environment-prefix-regexp #'nsenter--handler)
              (assoc-delete-all nsenter--environment-prefix-regexp
                                file-name-handler-alist))))

(nsenter--register)
(advice-add 'tramp-register-file-name-handlers :after #'nsenter--register)

;; Shells inside are /bin/sh, not the host's `shell-file-name', which may not
;; exist inside.  TRAMP sets the same for its own methods, but only once TRAMP
;; loads.
(connection-local-set-profile-variables
 'nsenter-connection-local-default-profile
 '((shell-file-name . "/bin/sh") (shell-command-switch . "-c")))
(connection-local-set-profiles '(:application tramp :protocol "ns")
                               'nsenter-connection-local-default-profile)

(defvar tramp-methods)
(declare-function tramp-set-completion-function "tramp")
(with-eval-after-load 'tramp
  (add-to-list 'tramp-methods '("ns"))
  (tramp-set-completion-function
   "ns" (list (list (lambda (_)
                      (mapcar (lambda (environment)
                                (list nil (car environment)))
                              nsenter-environments))
                    ""))))

(provide 'nsenter)
;;; nsenter.el ends here
