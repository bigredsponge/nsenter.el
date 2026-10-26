;;; nsenter.el --- Local namespace access through TRAMP -*- lexical-binding: t; -*-

;; Version: 0.1
;; Package-Requires: ((emacs "30.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Configure `nsenter-environments', then visit /ns:NAME:/path.
;; Linux /proc and util-linux nsenter with --wdns are required.
;; File access uses the host's credentials; programs retain those credentials.

;;; Code:

(require 'tramp)
(require 'cl-lib)

(defgroup nsenter nil "Local namespace environments." :group 'tramp)

(defcustom nsenter-environments nil
  "Alist of (NAME :enter (PROGRAM ARG...)) environment definitions.
The command prefix must run its remaining arguments inside the environment,
with stdin open, without allocating a terminal.  Optional :timeout overrides
`nsenter-start-timeout' for this environment.  For example:
  ((\"box\" :enter (\"podman\" \"exec\" \"-i\" \"box\")))"
  :type '(alist :key-type string :value-type plist)
  :group 'nsenter)

(defcustom nsenter-start-timeout 120
  "Seconds to wait for an environment to start."
  :type 'number
  :group 'nsenter)

(defun nsenter--read (file)
  "Read FILE literally."
  (with-temp-buffer
    (insert-file-contents-literally file)
    (buffer-string)))

(defun nsenter--connection (vec)
  "Return the live environment process for VEC, starting it if needed."
  (or (let ((p (tramp-get-connection-process vec)))
        (and p (process-live-p p) (process-get p 'nsenter-pid) p))
      (progn
        (unless (tramp-connectable-p vec)
          (throw 'non-essential 'non-essential))
        (let* ((entry (assoc (tramp-file-name-host vec) nsenter-environments))
               (prefix (plist-get (cdr entry) :enter))
               (marker (concat "nsenter-" (make-temp-name "")))
               (command (list "sh" "-c" "read _" marker))
               (expected (concat (mapconcat #'identity command "\0") "\0"))
               (default-directory "/")
               (deadline (+ (float-time) (or (plist-get (cdr entry) :timeout)
                                            nsenter-start-timeout)))
               (reporter (make-progress-reporter
                          (format "Entering %s..." (car entry))))
               p pid)
          (unless prefix (error "No :enter command for %s" (car entry)))
          (setq p (make-process
                   :name (tramp-get-connection-name vec)
                   :buffer (tramp-get-connection-buffer vec)
                   :command (append prefix command)
                   :connection-type 'pipe :noquery t))
          (unwind-protect
              (progn
                (while (and (not pid) (process-live-p p)
                            (< (float-time) deadline))
                  (dolist (dir (directory-files "/proc" t "\\`[0-9]+\\'"))
                    (when (equal (ignore-errors
                                   (nsenter--read (concat dir "/cmdline")))
                                 expected)
                      (setq pid (string-to-number (file-name-nondirectory dir)))))
                  (unless pid
                    (accept-process-output p 0.02)
                    (progress-reporter-update
                     reporter nil (with-current-buffer (process-buffer p)
                                    (car (last (split-string (buffer-string) "\n" t)))))
                    (redisplay)))
                (unless pid
                  (error "Environment did not start: %s"
                         (with-current-buffer (process-buffer p) (buffer-string))))
                (process-put p 'nsenter-pid pid)
                (process-put p 'nsenter-environment
                             (split-string
                              (nsenter--read (format "/proc/%d/environ" pid))
                              "\0" t))
                (tramp-post-process-creation p vec)
                (tramp-set-connection-property p "connected" t)
                (tramp-set-connection-local-variables vec)
                (progress-reporter-done reporter)
                p)
            (unless (process-get p 'nsenter-pid) (delete-process p)))))))

(defun nsenter--resolve (root path &optional nofollow)
  "Resolve PATH within ROOT, following links component by component.
Absolute link targets restart at ROOT; .. cannot escape it.
With NOFOLLOW, leave the final component unresolved."
  (let ((todo (split-string path "/" t)) done (links 0))
    (while todo
      (let ((part (pop todo)))
        (cond
         ((equal part "."))
         ((equal part "..") (pop done))
         (t
          (let* ((candidate (concat root "/"
                                    (mapconcat #'identity
                                               (reverse (cons part done)) "/")))
                 (target (unless (and nofollow (null todo))
                           (file-symlink-p candidate))))
            (if (not target) (push part done)
              (when (> (cl-incf links) 40)
                (signal 'file-error (list "Too many symbolic links" path)))
              (when (string-prefix-p "/" target) (setq done nil))
              (setq todo (append (split-string target "/" t) todo))))))))
    (concat root "/" (mapconcat #'identity (reverse done) "/")
            (when (and done (not nofollow) (string-suffix-p "/" path)) "/"))))

(defun nsenter--local (file &optional nofollow)
  "Translate an ns FILE to a host path, optionally with NOFOLLOW."
  (if (not (nsenter--file-name-p file)) file
    (let* ((vec (tramp-dissect-file-name file))
           (p (nsenter--connection vec)))
      (nsenter--resolve
       (format "/proc/%d/root" (process-get p 'nsenter-pid))
       (file-name-unquote (tramp-file-name-localname vec)) nofollow))))

(defun nsenter--file-operation (operation &rest args)
  "Run file OPERATION on translated ARGS."
  (let ((nofollow (memq operation '(file-attributes delete-file delete-directory
                                  rename-file make-directory))))
    (setcar args (nsenter--local (car args) nofollow))
    (when (memq operation '(copy-file rename-file add-name-to-file))
      (setcar (cdr args) (nsenter--local (cadr args) t)))
    (apply operation args)))

(defun nsenter--completions (file directory)
  "Return completions for FILE in DIRECTORY using TRAMP's filtering."
  (tramp-skeleton-file-name-all-completions file directory
    (all-completions
     file (mapcar (lambda (name)
                    (if (file-directory-p (concat directory name))
                        (concat name "/") name))
                  (directory-files (nsenter--local directory))))))

(defun nsenter--exec-path ()
  "Return the inner process's executable search path."
  (let* ((vec (tramp-dissect-file-name default-directory))
         (env (nsenter--environment (nsenter--connection vec))))
    (append (split-string (getenv-internal "PATH" env) ":")
            (list (tramp-file-name-localname vec)))))

(defun nsenter--insert (filename &optional visit beg end replace)
  "Insert FILENAME, honoring VISIT, BEG, END and REPLACE."
  (let (result)
    (unwind-protect
        (setq result (insert-file-contents
                      (nsenter--local filename) visit beg end replace))
      (when visit (setq buffer-file-name filename)))
    (cons filename (cdr result))))

(defun nsenter--write (start end filename &optional append visit lockname mustbenew)
  "Like `write-region' for START, END, FILENAME and APPEND.
VISIT, LOCKNAME and MUSTBENEW are as for `write-region'."
  (tramp-skeleton-write-region start end filename append visit lockname mustbenew
    (let (create-lockfiles)
      (write-region start end (nsenter--local filename) append 'nomessage))
    (setq coding-system-used last-coding-system-used)))

(defun nsenter--environment (p)
  "Return P's inner environment plus dynamically bound variables."
  (append (cl-remove-if
           (lambda (entry)
             (member entry (default-toplevel-value 'process-environment)))
           process-environment)
          (process-get p 'nsenter-environment)))

(defun nsenter--command (vec)
  "Return the nsenter command prefix for VEC's working directory."
  (let* ((p (nsenter--connection vec))
         (pid (process-get p 'nsenter-pid))
         (base (format "/proc/%d/ns/" pid))
         (flags '(("user" . "--user") ("mnt" . "--mount")
                  ("uts" . "--uts") ("ipc" . "--ipc") ("net" . "--net")
                  ("pid" . "--pid") ("cgroup" . "--cgroup") ("time" . "--time"))))
    (append (list (executable-find "nsenter") "-t" (number-to-string pid)
                  "-r" "--preserve-credentials"
                  (concat "--wdns=" (tramp-file-name-localname vec)))
            (cl-loop for (name . flag) in flags
                     unless (equal (file-symlink-p (concat base name))
                                   (file-symlink-p (concat "/proc/self/ns/" name)))
                     collect flag)
            '("--"))))

(defun nsenter--process-file (program &optional infile destination display &rest args)
  "Run PROGRAM with INFILE, DESTINATION, DISPLAY and ARGS inside the environment."
  (let* ((vec (tramp-dissect-file-name default-directory))
         (command (nsenter--command vec))
         (infile (and infile (nsenter--local infile)))
         (destination (if (and (consp destination) (stringp (cadr destination)))
                          (list (car destination) (nsenter--local (cadr destination)))
                        destination))
         (process-environment (nsenter--environment (nsenter--connection vec)))
         (default-directory "/"))
    (apply #'call-process (car command) infile destination display
           (append (cdr command) (list program) args))))

(defun nsenter--make-process (&rest args)
  "Run an asynchronous environment process with `make-process' ARGS."
  (let* ((vec (tramp-dissect-file-name default-directory))
         (command (append (nsenter--command vec) (plist-get args :command)))
         (process-environment (nsenter--environment (nsenter--connection vec)))
         (default-directory "/")
         (p (apply #'make-process (plist-put (copy-sequence args) :command command))))
    (process-put p 'remote-command (plist-get args :command))
    p))

(defun nsenter--home (vec &optional _user)
  "Return the environment's HOME for VEC."
  (getenv-internal "HOME" (process-get (nsenter--connection vec) 'nsenter-environment)))

(defconst nsenter-file-name-handler-alist
  (append
   (mapcar (lambda (op) (cons op (intern (concat "tramp-handle-" (symbol-name op)))))
           '(access-file copy-directory directory-file-name directory-files
             directory-files-and-attributes dired-uncache expand-file-name
             file-accessible-directory-p file-directory-p file-equal-p
             file-in-directory-p file-local-copy file-locked-p file-modes
             file-name-as-directory file-name-case-insensitive-p file-name-completion
             file-name-directory file-name-nondirectory file-newer-than-file-p
             file-regular-p file-remote-p file-symlink-p file-truename
             find-backup-file-name insert-directory load lock-file
             make-auto-save-file-name make-lock-file-name make-nearby-temp-file
             set-visited-file-modtime shell-command start-file-process
             substitute-in-file-name temporary-file-directory unlock-file
             verify-visited-file-modtime))
   (mapcar (lambda (op) (cons op #'nsenter--file-operation))
           '(add-name-to-file copy-file delete-directory delete-file file-attributes
             file-executable-p file-exists-p file-readable-p file-writable-p
             file-system-info make-directory rename-file set-file-modes set-file-times))
   '((exec-path . nsenter--exec-path)
     (file-name-all-completions . nsenter--completions)
     (insert-file-contents . nsenter--insert) (write-region . nsenter--write)
     (process-file . nsenter--process-file) (make-process . nsenter--make-process)
     (tramp-get-home-directory . nsenter--home)
     (tramp-get-remote-uid . ignore) (tramp-get-remote-gid . ignore)
     (tramp-set-file-uid-gid . ignore) (file-acl . ignore)
     (file-selinux-context . tramp-handle-file-selinux-context)
     (set-file-acl . ignore) (set-file-selinux-context . ignore)
     (unhandled-file-name-directory . ignore) (vc-registered . ignore)))
  "Operations handled by the ns backend.")

(defun nsenter--file-name-p (file)
  "Whether FILE is an ns name or dissected TRAMP vector."
  (let ((vec (tramp-ensure-dissected-file-name file)))
    (and vec (equal (tramp-file-name-method vec) "ns"))))

(defun nsenter-file-name-handler (operation &rest args)
  "Dispatch OPERATION with ARGS through TRAMP's ns backend."
  (let ((handler (alist-get operation nsenter-file-name-handler-alist)))
    (save-match-data
      (cond ((eq handler #'nsenter--file-operation)
             (apply handler operation args))
            (handler (apply handler args))
            (t (tramp-run-real-handler operation args))))))

(add-to-list 'tramp-methods '("ns" (tramp-remote-shell "/bin/sh")
                            (tramp-remote-shell-args ("-c"))))
(tramp-register-foreign-file-name-handler #'nsenter--file-name-p
                                          #'nsenter-file-name-handler)

(provide 'nsenter)
;;; nsenter.el ends here
