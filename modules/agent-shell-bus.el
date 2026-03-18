;;; agent-shell-bus.el --- Cross-instance event bus for agent-shell-team -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author: Igor Rizhyi
;; Keywords: tools, ai, ipc
;; Version: 0.1.0

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Cross-Emacs-instance event bus using inotify directory watches and
;; per-instance JSONL files.
;;
;; Directory layout under ~/.cache/agent-shell/ns-{namespace}/:
;;   peers/{emacs-pid}.json    — presence files
;;   events/{emacs-pid}.jsonl  — per-instance broadcast event logs
;;   inbox/{emacs-pid}/        — targeted messages TO this instance

;;; Code:

(require 'json)
(require 'filenotify)

(defvar agent-shell-team--session-id)

;;; --- State variables ---

(defvar agent-shell-bus--namespace nil
  "Current namespace string.")

(defvar agent-shell-bus--base-dir nil
  "Expanded path to ~/.cache/agent-shell/ns-{namespace}/.")

(defvar agent-shell-bus--watches nil
  "Alist of (PURPOSE . DESCRIPTOR) for the 3 directory watches.")

(defvar agent-shell-bus--read-positions (make-hash-table :test 'equal)
  "Hash-table: filepath → byte position for JSONL tailing.")

(defvar agent-shell-bus--event-handlers (make-hash-table :test 'eq)
  "Hash-table: event-type-symbol → list of handler functions.")

(defvar agent-shell-bus--seq 0
  "Monotonic counter for outgoing events.")

(defvar agent-shell-bus--peers (make-hash-table :test 'equal)
  "Hash-table: pid (integer) → peer-info plist.")

(defvar agent-shell-bus--heartbeat-timer nil
  "30-second heartbeat timer.")

;;; --- Path helpers ---

(defun agent-shell-bus--peers-dir ()
  "Return the peers/ directory path."
  (expand-file-name "peers" agent-shell-bus--base-dir))

(defun agent-shell-bus--events-dir ()
  "Return the events/ directory path."
  (expand-file-name "events" agent-shell-bus--base-dir))

(defun agent-shell-bus--inbox-dir (&optional pid)
  "Return inbox directory for PID (default: our PID)."
  (expand-file-name (format "%d" (or pid (emacs-pid)))
                    (expand-file-name "inbox" agent-shell-bus--base-dir)))

(defun agent-shell-bus--our-presence-file ()
  "Return our presence file path."
  (expand-file-name (format "%d.json" (emacs-pid))
                    (agent-shell-bus--peers-dir)))

(defun agent-shell-bus--our-event-log ()
  "Return our event log file path."
  (expand-file-name (format "%d.jsonl" (emacs-pid))
                    (agent-shell-bus--events-dir)))

;;; --- JSON helpers ---

(defun agent-shell-bus--plist-to-json (plist)
  "Encode PLIST as a JSON string."
  (let ((json-encoding-pretty-print nil))
    (json-encode (agent-shell-bus--plist-to-alist plist))))

(defun agent-shell-bus--plist-to-alist (plist)
  "Convert PLIST to an alist suitable for `json-encode'."
  (let (result)
    (while plist
      (let ((key (pop plist))
            (val (pop plist)))
        (push (cons (if (keywordp key)
                        (intern (substring (symbol-name key) 1))
                      key)
                    (if (and (listp val) (keywordp (car-safe val)))
                        (agent-shell-bus--plist-to-alist val)
                      val))
              result)))
    (nreverse result)))

(defun agent-shell-bus--parse-json (string)
  "Parse JSON STRING, returning a plist. Return nil on error."
  (condition-case nil
      (let ((json-object-type 'plist)
            (json-key-type 'keyword)
            (json-array-type 'list))
        (json-read-from-string string))
    (error nil)))

;;; --- File I/O helpers ---

(defun agent-shell-bus--write-file (file content &optional append)
  "Write CONTENT to FILE atomically. If APPEND, append instead.
Disables lock files to avoid spurious inotify events."
  (condition-case err
      (let ((create-lockfiles nil)
            (write-region-inhibit-fsync nil))
        (with-temp-buffer
          (insert content)
          (write-region (point-min) (point-max) file
                        (if append t nil) 'silent)))
    (error
     (message "agent-shell-bus: write error %s: %s" file (error-message-string err)))))

(defun agent-shell-bus--read-file (file)
  "Read FILE contents as string. Return nil on error."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents file)
        (buffer-string))
    (error nil)))

;;; --- Tail reading ---

(defun agent-shell-bus--tail-read-events (file)
  "Read new JSONL lines from FILE since last known position.
Parse each line and dispatch via registered handlers."
  (condition-case err
      (let* ((attrs (file-attributes file))
             (size (file-attribute-size attrs))
             (pos (gethash file agent-shell-bus--read-positions 0)))
        (when (and size (> size pos))
          (let ((content
                 (with-temp-buffer
                   (insert-file-contents file nil pos size)
                   (buffer-string))))
            (puthash file size agent-shell-bus--read-positions)
            (dolist (line (split-string content "\n" t))
              (let ((event (agent-shell-bus--parse-json line)))
                (when event
                  (let ((type (plist-get event :type))
                        (sender (plist-get event :pid))
                        (data (plist-get event :data)))
                    (when type
                      (agent-shell-bus--dispatch
                       (intern type) data sender)))))))))
    (error
     (message "agent-shell-bus: tail-read error %s: %s" file (error-message-string err)))))

(defun agent-shell-bus--dispatch (type data sender-pid)
  "Dispatch event of TYPE with DATA from SENDER-PID to registered handlers."
  (let ((handlers (gethash type agent-shell-bus--event-handlers)))
    (dolist (handler handlers)
      (condition-case err
          (funcall handler data sender-pid)
        (error
         (message "agent-shell-bus: handler error for %s: %s"
                  type (error-message-string err)))))))

;;; --- Directory watch callbacks ---

(defun agent-shell-bus--on-peers-change (event)
  "Handle changes in the peers/ directory.
EVENT is a file-notify event (DESCRIPTOR ACTION FILE [FILE1])."
  (let ((action (nth 1 event))
        (file (nth 2 event)))
    (when (and file (string-match-p "\\.json\\'" file))
      (let ((pid-str (file-name-sans-extension (file-name-nondirectory file))))
        (condition-case nil
            (let ((pid (string-to-number pid-str)))
              (when (> pid 0)
                (pcase action
                  ((or 'created 'changed)
                   (let ((info (agent-shell-bus--parse-json
                                (or (agent-shell-bus--read-file file) ""))))
                     (when info
                       (puthash pid info agent-shell-bus--peers)
                       ;; Start tailing their event log (set position to current size)
                       (let ((elog (expand-file-name
                                    (format "%d.jsonl" pid)
                                    (agent-shell-bus--events-dir))))
                         (unless (gethash elog agent-shell-bus--read-positions)
                           (let ((size (condition-case nil
                                           (file-attribute-size
                                            (file-attributes elog))
                                         (error 0))))
                             (puthash elog (or size 0)
                                      agent-shell-bus--read-positions))))
                       (agent-shell-bus--dispatch
                        'peer-join info pid))))
                  ('deleted
                   (let ((info (gethash pid agent-shell-bus--peers)))
                     (remhash pid agent-shell-bus--peers)
                     (agent-shell-bus--dispatch
                      'peer-leave info pid))))))
          (error nil))))))

(defun agent-shell-bus--on-events-change (event)
  "Handle changes in the events/ directory.
Tail-read new lines from any changed .jsonl file (except our own)."
  (let ((action (nth 1 event))
        (file (nth 2 event)))
    (when (and file
               (string-match-p "\\.jsonl\\'" file)
               (memq action '(created changed))
               ;; Don't read our own events back
               (not (string= (file-name-nondirectory file)
                              (format "%d.jsonl" (emacs-pid)))))
      (agent-shell-bus--tail-read-events file))))

(defun agent-shell-bus--on-inbox-change (event)
  "Handle new messages in our inbox/ directory.
Read, dispatch, then delete the message file."
  (let ((action (nth 1 event))
        (file (nth 2 event)))
    (when (and file
               (string-match-p "\\.json\\'" file)
               (eq action 'created))
      (condition-case err
          (let ((content (agent-shell-bus--read-file file)))
            (when content
              (let ((msg (agent-shell-bus--parse-json content)))
                (when msg
                  (let ((type (plist-get msg :type))
                        (sender (plist-get msg :pid))
                        (data (plist-get msg :data)))
                    (when type
                      (agent-shell-bus--dispatch
                       (intern type) data sender))))))
            (condition-case nil
                (delete-file file)
              (error nil)))
        (error
         (message "agent-shell-bus: inbox error %s: %s"
                  file (error-message-string err)))))))

;;; --- Heartbeat ---

(defun agent-shell-bus--heartbeat ()
  "Update our presence file mtime and check peer liveness."
  (condition-case nil
      (progn
        ;; Touch our presence file
        (let ((pfile (agent-shell-bus--our-presence-file)))
          (when (file-exists-p pfile)
            (set-file-times pfile)))
        ;; Check all peers
        (let ((stale nil))
          (maphash
           (lambda (pid _info)
             (unless (= pid (emacs-pid))
               (unless (condition-case nil
                           (= 0 (signal-process pid 0))
                         (error nil))
                 (push pid stale))))
           agent-shell-bus--peers)
          ;; Clean up stale peers
          (dolist (pid stale)
            (let ((info (gethash pid agent-shell-bus--peers)))
              (remhash pid agent-shell-bus--peers)
              (agent-shell-bus--dispatch 'peer-leave info pid)
              ;; Remove their files
              (condition-case nil
                  (progn
                    (let ((pfile (expand-file-name
                                  (format "%d.json" pid)
                                  (agent-shell-bus--peers-dir))))
                      (when (file-exists-p pfile)
                        (delete-file pfile)))
                    (let ((elog (expand-file-name
                                 (format "%d.jsonl" pid)
                                 (agent-shell-bus--events-dir))))
                      (when (file-exists-p elog)
                        (delete-file elog))
                      (remhash elog agent-shell-bus--read-positions))
                    (let ((idir (agent-shell-bus--inbox-dir pid)))
                      (when (file-directory-p idir)
                        (delete-directory idir t))))
                (error nil))))))
    (error nil)))

;;; --- Public API ---

(defun agent-shell-bus-start (namespace)
  "Start the event bus for NAMESPACE.
Create directories, write presence, scan peers, set up watches,
start heartbeat timer, add `kill-emacs-hook'."
  (when agent-shell-bus--namespace
    (agent-shell-bus-stop))
  (setq agent-shell-bus--namespace namespace)
  (setq agent-shell-bus--base-dir
        (expand-file-name
         (format "ns-%s" namespace)
         (expand-file-name "agent-shell"
                           (or (getenv "XDG_CACHE_HOME")
                               (expand-file-name ".cache" "~")))))
  (setq agent-shell-bus--seq 0)
  (setq agent-shell-bus--peers (make-hash-table :test 'equal))
  (setq agent-shell-bus--read-positions (make-hash-table :test 'equal))
  ;; Create directories
  (let ((dirs (list (agent-shell-bus--peers-dir)
                    (agent-shell-bus--events-dir)
                    (agent-shell-bus--inbox-dir))))
    (dolist (dir dirs)
      (make-directory dir t)))
  ;; Write presence file
  (let ((presence (agent-shell-bus--plist-to-json
                   (list :pid (emacs-pid)
                         :session_id (if (boundp 'agent-shell-team--session-id)
                                         (symbol-value 'agent-shell-team--session-id)
                                       (number-to-string (emacs-pid)))
                         :hostname (system-name)
                         :joined_at (float-time)
                         :project_root (if (boundp 'agent-shell-namespace--project-root)
                                           (or (symbol-value 'agent-shell-namespace--project-root)
                                               default-directory)
                                         default-directory)))))
    (agent-shell-bus--write-file (agent-shell-bus--our-presence-file)
                                  (concat presence "\n")))
  ;; Create empty event log
  (let ((elog (agent-shell-bus--our-event-log)))
    (unless (file-exists-p elog)
      (agent-shell-bus--write-file elog "")))
  ;; Scan existing peers and set read positions to current file sizes
  (condition-case nil
      (dolist (file (directory-files (agent-shell-bus--peers-dir) t "\\.json\\'"))
        (let* ((pid-str (file-name-sans-extension (file-name-nondirectory file)))
               (pid (string-to-number pid-str)))
          (when (and (> pid 0) (/= pid (emacs-pid)))
            (let ((info (agent-shell-bus--parse-json
                         (or (agent-shell-bus--read-file file) ""))))
              (when info
                (puthash pid info agent-shell-bus--peers)
                ;; Set read position to current size (skip old events)
                (let ((elog (expand-file-name
                              (format "%d.jsonl" pid)
                              (agent-shell-bus--events-dir))))
                  (when (file-exists-p elog)
                    (puthash elog
                             (or (file-attribute-size (file-attributes elog)) 0)
                             agent-shell-bus--read-positions))))))))
    (error nil))
  ;; Set up 3 directory watches
  (setq agent-shell-bus--watches nil)
  (condition-case err
      (progn
        (push (cons 'peers
                    (file-notify-add-watch
                     (agent-shell-bus--peers-dir)
                     '(change)
                     #'agent-shell-bus--on-peers-change))
              agent-shell-bus--watches)
        (push (cons 'events
                    (file-notify-add-watch
                     (agent-shell-bus--events-dir)
                     '(change)
                     #'agent-shell-bus--on-events-change))
              agent-shell-bus--watches)
        (push (cons 'inbox
                    (file-notify-add-watch
                     (agent-shell-bus--inbox-dir)
                     '(change)
                     #'agent-shell-bus--on-inbox-change))
              agent-shell-bus--watches))
    (error
     (message "agent-shell-bus: watch setup error: %s" (error-message-string err))))
  ;; Start heartbeat timer
  (setq agent-shell-bus--heartbeat-timer
        (run-with-timer 30 30 #'agent-shell-bus--heartbeat))
  ;; Add kill-emacs-hook
  (add-hook 'kill-emacs-hook #'agent-shell-bus-stop)
  (message "agent-shell-bus: started in namespace %s" namespace))

(defun agent-shell-bus-stop ()
  "Stop the event bus.
Emit peer-leave, remove our files, cancel timer, remove watches."
  (when agent-shell-bus--namespace
    ;; Emit peer-leave event
    (condition-case nil
        (agent-shell-bus-emit 'peer-leave
                               (list :pid (emacs-pid)
                                     :reason "shutdown"))
      (error nil))
    ;; Cancel heartbeat
    (when agent-shell-bus--heartbeat-timer
      (cancel-timer agent-shell-bus--heartbeat-timer)
      (setq agent-shell-bus--heartbeat-timer nil))
    ;; Remove watches
    (dolist (entry agent-shell-bus--watches)
      (condition-case nil
          (file-notify-rm-watch (cdr entry))
        (error nil)))
    (setq agent-shell-bus--watches nil)
    ;; Remove our files
    (condition-case nil
        (progn
          (let ((pfile (agent-shell-bus--our-presence-file)))
            (when (file-exists-p pfile)
              (delete-file pfile)))
          (let ((elog (agent-shell-bus--our-event-log)))
            (when (file-exists-p elog)
              (delete-file elog)))
          (let ((idir (agent-shell-bus--inbox-dir)))
            (when (file-directory-p idir)
              (delete-directory idir t))))
      (error nil))
    ;; Remove kill-emacs-hook
    (remove-hook 'kill-emacs-hook #'agent-shell-bus-stop)
    ;; Clear state
    (setq agent-shell-bus--namespace nil)
    (setq agent-shell-bus--base-dir nil)
    (clrhash agent-shell-bus--peers)
    (clrhash agent-shell-bus--read-positions)
    (message "agent-shell-bus: stopped")))

(defun agent-shell-bus-emit (type data)
  "Emit a broadcast event of TYPE with DATA (a plist).
Appends a JSON line to our events/{pid}.jsonl."
  (let* ((seq (cl-incf agent-shell-bus--seq))
         (event (agent-shell-bus--plist-to-json
                 (list :ts (float-time)
                       :seq seq
                       :type (if (symbolp type) (symbol-name type) type)
                       :pid (emacs-pid)
                       :data data)))
         (line (concat event "\n")))
    (agent-shell-bus--write-file (agent-shell-bus--our-event-log) line t)))

(defun agent-shell-bus-send (target-pid type data)
  "Send a targeted message to TARGET-PID with TYPE and DATA (a plist)."
  (let* ((seq (cl-incf agent-shell-bus--seq))
         (msg (agent-shell-bus--plist-to-json
               (list :ts (float-time)
                     :seq seq
                     :type (if (symbolp type) (symbol-name type) type)
                     :pid (emacs-pid)
                     :data data)))
         (inbox-dir (agent-shell-bus--inbox-dir target-pid))
         (file (expand-file-name
                (format "%d-%d.json" (emacs-pid) seq)
                inbox-dir)))
    ;; Ensure target inbox exists
    (make-directory inbox-dir t)
    (agent-shell-bus--write-file file (concat msg "\n"))))

(defun agent-shell-bus-on (type handler)
  "Register HANDLER for events of TYPE (a symbol).
HANDLER is called as (funcall handler data sender-pid)."
  (let ((handlers (gethash type agent-shell-bus--event-handlers)))
    (unless (memq handler handlers)
      (puthash type (cons handler handlers)
               agent-shell-bus--event-handlers))))

(provide 'agent-shell-bus)
;;; agent-shell-bus.el ends here
