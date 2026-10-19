;;; nsenter-lint.el --- Lint the files named on the command line -*- lexical-binding: t; -*-

;;; Commentary:

;; Entry point for `just lint', after ghostel's tools/ghostel-lint.el.

;;; Code:

(require 'checkdoc)

(defun nsenter-lint-checkdoc ()
  "Run checkdoc over the files named on the command line, failing on a problem."
  (let ((files command-line-args-left)
        ;; Emacs 29 guesses at verbs, wrongly, and later versions don't.
        (checkdoc-verb-check-experimental-flag nil)
        (ok t))
    ;; Emacs would otherwise visit the files once this returns.
    (setq command-line-args-left nil)
    (dolist (file files)
      ;; checkdoc reports through *Warnings*, not a return value.
      (ignore-errors (kill-buffer "*Warnings*"))
      (let ((inhibit-message t))
        (checkdoc-file file))
      (when (get-buffer "*Warnings*")
        (setq ok nil)
        (with-current-buffer "*Warnings*"
          (message "%s" (buffer-string)))))
    (unless ok (kill-emacs 1))))

(provide 'nsenter-lint)
;;; nsenter-lint.el ends here
