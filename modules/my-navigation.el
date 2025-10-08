;;; modules/my-navigation.el --- Navigation utilities -*- lexical-binding: t; -*-

;;; Commentary:
;; UP/DOWN arrows jump 10 lines at a time
;; LEFT/RIGHT arrows navigate between functions

;;; Code:

(defun my/jump-up ()
  "Jump up 10 lines."
  (interactive)
  (forward-line -10))

(defun my/jump-down ()
  "Jump down 10 lines."
  (interactive)
  (forward-line 10))

(defun my/next-defun ()
  "Move to the beginning of the next function definition.
Uses `beginning-of-defun' with a negative argument to move forward."
  (interactive)
  (beginning-of-defun -1))

;; Bind arrow keys for normal and visual modes
(map! :n "<up>" #'my/jump-up
      :n "<down>" #'my/jump-down
      :v "<up>" #'my/jump-up
      :v "<down>" #'my/jump-down
      ;; Function navigation with left/right arrows
      :n "<left>" #'beginning-of-defun    ; Previous function
      :n "<right>" #'my/next-defun)       ; Next function

;; Aggressively override Ctrl-Tab from yasnippet
(after! yasnippet
  ;; First unbind the yasnippet function
  (map! :map yas-minor-mode-map
        "C-<tab>" nil)
  (map! :map yas-keymap
        "C-<tab>" nil)
  ;; Unbind from insert mode specifically
  (map! :i "C-<tab>" nil))

;; Then bind our function globally
(map! :g "C-<tab>" #'switch-to-buffer
      :n "C-<tab>" #'switch-to-buffer
      :i "C-<tab>" #'switch-to-buffer
      :v "C-<tab>" #'switch-to-buffer)

;; Force override with global-set-key as backup
(with-eval-after-load 'yasnippet
  (global-set-key (kbd "C-<tab>") #'switch-to-buffer))

;; Python structural navigation with { and }
(with-eval-after-load 'python
  (defun my/python-nav-up-list-backward ()
    "Move to the beginning of the current/outer block backward."
    (interactive)
    (python-nav-backward-up-list 1))
  (defun my/python-nav-up-list-forward ()
    "Move forward to the beginning of the next outer block."
    (interactive)
    (python-nav-backward-up-list -1))
  
  ;; Class block navigation functions
  (defun my/python-prev-class ()
    "Move to the previous class definition."
    (interactive)
    (let ((current-pos (point)))
      (if (re-search-backward "^class " nil t)
          (progn
            (beginning-of-line)
            (message "Moved to previous class"))
        (progn
          (goto-char current-pos)
          (message "No previous class found")))))
  
  (defun my/python-next-class ()
    "Move to the next class definition."
    (interactive)
    (let ((current-pos (point))
          (found nil))
      ;; Move forward to avoid matching current line if we're on a class definition
      (when (looking-at "^class ")
        (forward-line 1))
      (if (re-search-forward "^class " nil t)
          (progn
            (beginning-of-line)
            (message "Moved to next class"))
        (progn
          (goto-char current-pos)
          (message "No next class found")))))
  
  (defun my/python-current-or-outer-class ()
    "Move to the current class definition or the outer class if nested."
    (interactive)
    (let ((current-pos (point))
          (current-indent (current-indentation))
          (found-class nil))
      ;; Look backwards for class definition
      (save-excursion
        (while (and (not found-class) (re-search-backward "^class " nil t))
          (let ((class-indent (current-indentation)))
            ;; If we find a class at same or lesser indentation, that's our target
            (when (<= class-indent current-indent)
              (setq found-class (point))))))
      (if found-class
          (progn
            (goto-char found-class)
            (message "Moved to current/outer class"))
        (message "No enclosing class found"))))
  
  ;; Replace { and } with class navigation
  (map! :map python-mode-map
        :n "{" #'my/python-prev-class
        :n "}" #'my/python-next-class
        ;; Keep the original block navigation on shifted versions if needed
        :n "C-{" #'my/python-nav-up-list-backward
        :n "C-}" #'my/python-nav-up-list-forward
        :n "M-{" #'my/python-current-or-outer-class)
  
  (when (boundp 'python-ts-mode-map)
    (map! :map python-ts-mode-map
          :n "{" #'my/python-prev-class
          :n "}" #'my/python-next-class
          ;; Keep the original block navigation on shifted versions if needed
          :n "C-{" #'my/python-nav-up-list-backward
          :n "C-}" #'my/python-nav-up-list-forward
          :n "M-{" #'my/python-current-or-outer-class)))

(provide 'my-navigation)

;;; my-navigation.el ends here
