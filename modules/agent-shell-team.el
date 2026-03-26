;;; agent-shell-team.el --- Multi-agent team orchestration for agent-shell -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author: Igor Rizhyi
;; Keywords: tools, ai, team
;; Version: 0.2.0

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Multi-agent team orchestration layer on top of agent-shell-emacs-mcp.
;;
;; Supports five roles:
;;   - lead: Supervisor — reviews, merges, dispatches, assigns tasks
;;   - dev: Implements features in isolated worktrees
;;   - tester: Runs tests/validation, reports results
;;   - researcher: Explores codebase, finds code, answers questions about the project
;;   - knowledge: Lightweight LLM processing for knowledge graph tasks
;;
;; Two cooperation modes:
;;   - isolated: Agent gets its own git worktree
;;   - neighbor: Agent shares parent's working directory (read-only assistance)
;;
;; Communication is fully ACP-based:
;;   - System prompts injected via ACP :meta systemPrompt at session creation
;;   - Tool calls intercepted via agent-shell-subscribe-to :event 'tool-call-update
;;   - Messages delivered via acp-send-request + acp-make-session-prompt-request
;;   - No MCP server modifications required

;;; Code:

(require 'agent-shell)
(require 'agent-shell-worktree)
(require 'agent-shell-emacs-mcp)

;; Defined in config.el — declared here so the byte-compiler treats it as
;; dynamically-scoped when let-bound in `agent-shell-team--start-agent'.
(defvar my/agent-shell-pending-worktree-path)

;; Override: resolve through worktrees to always get the MAIN repo root.
;; The upstream version uses --show-toplevel which returns the worktree's own
;; root when called from inside a worktree, causing nested worktree creation.
(defun agent-shell-worktree--git-repo-root ()
  "Return the root of the MAIN git working tree, resolving through worktrees."
  (when-let* ((common-dir (string-trim (shell-command-to-string
                            "git rev-parse --path-format=absolute --git-common-dir 2>/dev/null")))
              (_ (not (string-empty-p common-dir)))
              (parent (file-name-directory (directory-file-name common-dir))))
    (when (string-suffix-p "/.git/" (file-name-as-directory common-dir))
      parent)))
(require 'acp)
(require 'dbus)
(require 'transient)
(require 'my-agent-shell-sidebar)

(declare-function my/team-sidebar--show "my-agent-shell-sidebar")
(declare-function agent-shell-namespace--format-peers-for-prompt "agent-shell-namespace")

;;; Devcontainer command prefix

(setq agent-shell-command-prefix
      (lambda (buffer)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when (and (bound-and-true-p agent-shell-team--role)
                       (equal agent-shell-team--role "tester")
                       (bound-and-true-p agent-shell-team--worktree-path))
              (let ((config-path (expand-file-name
                                  (format ".devcontainer/%s/devcontainer.json"
                                          agent-shell-team--role)
                                  agent-shell-team--worktree-path)))
                (when (file-exists-p config-path)
                  (list "devcontainer" "exec"
                        "--workspace-folder" agent-shell-team--worktree-path
                        "--config" config-path))))))))

;;; Customization

(defgroup agent-shell-team nil
  "Multi-agent team orchestration for agent-shell."
  :group 'agent-shell
  :prefix "agent-shell-team-")

(defcustom agent-shell-team-skip-permissions t
  "When non-nil, set bypassPermissions mode on team agent sessions.
This gives agents full trust to edit files, run commands, etc.
without prompting for confirmation."
  :type 'boolean
  :group 'agent-shell-team)

(defcustom agent-shell-team-max-agents-per-role 3
  "Maximum number of agents per role per session."
  :type 'integer
  :group 'agent-shell-team)

(defcustom agent-shell-team-auto-compact-threshold 75.0
  "Context usage percentage at which to auto-compact the lead agent."
  :type 'float
  :group 'agent-shell-team)

(defcustom agent-shell-team-compact-cooldown 120
  "Minimum seconds between auto-compactions for the same buffer."
  :type 'integer
  :group 'agent-shell-team)

(defcustom agent-shell-team-role-models '(("knowledge" . "sonnet"))
  "Alist mapping role name strings to Claude model ID strings.
Each entry is (ROLE . MODEL-ID) where MODEL-ID is a short name
like \"sonnet\", \"haiku\", \"opus\", or \"default\".
Roles not listed here fall back to `agent-shell-anthropic-default-model-id'."
  :type '(alist :key-type string :value-type string)
  :group 'agent-shell-team)

;;; Faces for doom-modeline role badges

(defface agent-shell-team-role-lead-face
  '((t :background "#e74c3c" :foreground "#ffffff" :weight bold))
  "Face for lead role badge in mode line."
  :group 'agent-shell-team)

(defface agent-shell-team-role-dev-face
  '((t :background "#2ecc71" :foreground "#000000" :weight bold))
  "Face for dev role badge in mode line."
  :group 'agent-shell-team)

(defface agent-shell-team-role-tester-face
  '((t :background "#f39c12" :foreground "#000000" :weight bold))
  "Face for tester role badge in mode line."
  :group 'agent-shell-team)

(defface agent-shell-team-role-researcher-face
  '((t :background "#9b59b6" :foreground "#ffffff" :weight bold))
  "Face for researcher role badge in mode line."
  :group 'agent-shell-team)

(defface agent-shell-team-role-knowledge-face
  '((t :background "#1abc9c" :foreground "#000000" :weight bold))
  "Face for knowledge role badge in mode line."
  :group 'agent-shell-team)

(defface agent-shell-team-info-face
  '((t :background "#3b4252" :foreground "#88c0d0" :weight normal))
  "Face for team info (session, worktree) in mode line."
  :group 'agent-shell-team)

;;; Buffer-local variables

(defvar agent-shell-team--session-id nil
  "Global team session ID. One session per Emacs instance.
Generated eagerly at load time so MCP handlers always have a valid session.")

(defvar-local agent-shell-team--role nil
  "Role: dev, lead, tester, researcher, or knowledge.")

(defvar-local agent-shell-team--mode nil
  "Mode: isolated or neighbor.")

(defvar-local agent-shell-team--worktree-path nil
  "Git worktree path (isolated mode only).")

(defvar-local agent-shell-team--worktree-name nil
  "Git worktree name (isolated mode only).")

(defvar-local agent-shell-team--ephemeral nil
  "When non-nil, this agent was auto-spawned and should be dismissed after task completion.")

(defvar-local agent-shell-team--watcher-setup-p nil
  "When non-nil, the tool-call watcher has already been set up for this buffer.")

(defvar-local agent-shell-team--init-finished-p nil
  "Non-nil after ACP initialization has completed for this agent buffer.")

(defvar-local agent-shell-team--cleanup-in-progress nil
  "When non-nil, `agent-shell-team--kill-guard' allows the buffer to be killed.
Set by `agent-shell-team--cleanup-agent' before calling `kill-buffer'.")

;;; Global registry

(defvar agent-shell-team--sessions (make-hash-table :test 'equal)
  "Session-uuid -> list of agent alists.
Each entry is: ((buffer . #<buffer>) (role . \"dev\") (mode . \"isolated\")
                (worktree . \"/path\") (worktree-name . \"focused-turing\"))")

(defvar agent-shell-team--message-queue (make-hash-table :test 'equal)
  "Buffer -> list of pending messages waiting for agent to become idle.")

(defvar agent-shell-team--pending-for-lead (make-hash-table :test 'equal)
  "Messages pending delivery to a lead that hasn't registered yet.
Keyed by session-id, values are lists of formatted message strings.")

(defvar agent-shell-team--last-compact-time (make-hash-table :test 'eq)
  "Buffer -> float-time of last auto-compact.")

(defvar agent-shell-team--assigning-p nil
  "Non-nil while `agent-shell-team--try-assign-tasks' is running, preventing re-entrant calls.")

(defvar agent-shell-team--task-queue nil
  "FIFO queue of pending tasks.  Each entry is a plist:
\(:role ROLE :message MSG :request-id ID :group-id GID :session-id SID :report-path PATH\)")

(defvar agent-shell-team--task-groups (make-hash-table :test 'equal)
  "Group ID -> plist (:pending (id1 id2) :completed (id3) :session-id SID).")

(defvar agent-shell-team--request-to-group (make-hash-table :test 'equal)
  "Request ID -> group ID mapping for completion lookups.")

(defvar agent-shell-team--request-to-buffer (make-hash-table :test 'equal)
  "Map request-id to the agent buffer it was assigned to.")

(defvar agent-shell-team--active-tasks (make-hash-table :test 'equal)
  "Map request-id -> task plist for currently assigned (in-flight) tasks.
Used for content-based dedup: detect retry duplicates by checking role+message
against both queued and in-flight tasks.")

(defvar agent-shell-team--request-to-session (make-hash-table :test 'equal)
  "Map request-id to session-id.  Populated at tasksPut time so that
taskUpdate can resolve the correct session without relying on the global.")

(defvar agent-shell-team--interrupt-queue nil
  "Alist of (buffer . task-list) for high-priority interrupt tasks.
Tasks with :priority \"interrupt\" that target a busy agent are stored
here and delivered immediately when the agent finishes its current turn.")

;;; Idle inhibit (hypridle / screensaver)

(defvar agent-shell-team--idle-inhibit-cookie nil
  "DBus cookie from org.freedesktop.ScreenSaver.Inhibit, or nil if not held.
Each Emacs instance holds its own cookie.")

(defvar agent-shell-team--idle-inhibit-busy-dir
  (let ((dir (format "/tmp/agent-shell-busy-%d/" (user-uid))))
    (make-directory dir t)
    dir)
  "Shared directory for busy-agent sentinel files.
All Emacs instances for this user share the same directory.")

(defvar agent-shell-team--idle-inhibit-tracked (make-hash-table :test 'equal)
  "Set of agent-id strings currently marked busy by THIS Emacs instance.
Used to detect transitions and avoid redundant file ops.")

(defun agent-shell-team--buffer-worktree-name (buffer)
  "Return worktree-name for BUFFER from session registry."
  (catch 'found
    (maphash (lambda (_sid agents)
               (dolist (a agents)
                 (when (eq (alist-get 'buffer a) buffer)
                   (throw 'found (or (alist-get 'worktree-name a) "main")))))
             agent-shell-team--sessions)
    "main"))

(defun agent-shell-team--busy-file (agent-id)
  "Return the sentinel file path for AGENT-ID in the busy directory."
  (expand-file-name (format "%d-%s" (emacs-pid) agent-id)
                    agent-shell-team--idle-inhibit-busy-dir))

(defun agent-shell-team--mark-agent-busy (agent-id)
  "Create a sentinel file for AGENT-ID, then update idle inhibit."
  (unless (gethash agent-id agent-shell-team--idle-inhibit-tracked)
    (let ((file (agent-shell-team--busy-file agent-id)))
      (condition-case nil
          (progn
            (make-directory agent-shell-team--idle-inhibit-busy-dir t)
            (write-region "" nil file nil 'silent)
            (puthash agent-id t agent-shell-team--idle-inhibit-tracked)
            (agent-shell-team--update-idle-inhibit)
            (when (fboundp 'agent-shell-namespace-emit-status)
              (let ((buf (get-buffer agent-id)))
                (when buf
                  (let ((wt-name (agent-shell-team--buffer-worktree-name buf)))
                    (agent-shell-namespace-emit-status wt-name 'idle 'busy))))))
        (error nil)))))

(defun agent-shell-team--mark-agent-idle (agent-id)
  "Delete the sentinel file for AGENT-ID, then update idle inhibit."
  (when (gethash agent-id agent-shell-team--idle-inhibit-tracked)
    (let ((file (agent-shell-team--busy-file agent-id)))
      (condition-case nil
          (when (file-exists-p file)
            (delete-file file))
        (error nil))
      (remhash agent-id agent-shell-team--idle-inhibit-tracked)
      (agent-shell-team--update-idle-inhibit)
      (when (fboundp 'agent-shell-namespace-emit-status)
        (let ((buf (get-buffer agent-id)))
          (when buf
            (let ((wt-name (agent-shell-team--buffer-worktree-name buf)))
              (agent-shell-namespace-emit-status wt-name 'busy 'idle))))))))

(defun agent-shell-team--any-agents-busy-p ()
  "Return non-nil if any busy sentinel files exist in the shared directory."
  (condition-case nil
      (let ((files (directory-files agent-shell-team--idle-inhibit-busy-dir nil
                                   "^[0-9]+-" t)))
        (> (length files) 0))
    (error nil)))

(defun agent-shell-team--update-idle-inhibit ()
  "Acquire or release the DBus screensaver inhibit based on busy agents.
Uses the in-memory tracking hash instead of scanning the filesystem,
and makes D-Bus calls asynchronously to avoid blocking the main thread."
  (let ((busy (> (hash-table-count agent-shell-team--idle-inhibit-tracked) 0)))
    (if busy
        ;; Agents busy — acquire inhibit if not held
        (unless agent-shell-team--idle-inhibit-cookie
          (condition-case err
              (dbus-call-method-asynchronously
               :session
               "org.freedesktop.ScreenSaver"
               "/org/freedesktop/ScreenSaver"
               "org.freedesktop.ScreenSaver"
               "Inhibit"
               (lambda (cookie)
                 (setq agent-shell-team--idle-inhibit-cookie cookie)
                 (when agent-shell-team--session-id
                   (agent-shell-team--log agent-shell-team--session-id
                     (format "[idle-inhibit] Acquired screensaver inhibit (cookie=%s)" cookie))))
               "emacs-agent-shell"
               "Team agents active")
            (dbus-error
             (when agent-shell-team--session-id
               (agent-shell-team--log agent-shell-team--session-id
                 (format "[idle-inhibit] DBus error (inhibit): %s" (error-message-string err)))))))
      ;; No agents busy — release inhibit if held
      (when agent-shell-team--idle-inhibit-cookie
        (let ((cookie agent-shell-team--idle-inhibit-cookie))
          (setq agent-shell-team--idle-inhibit-cookie nil)
          (condition-case err
              (dbus-call-method-asynchronously
               :session
               "org.freedesktop.ScreenSaver"
               "/org/freedesktop/ScreenSaver"
               "org.freedesktop.ScreenSaver"
               "UnInhibit"
               (lambda (&rest _)
                 (when agent-shell-team--session-id
                   (agent-shell-team--log agent-shell-team--session-id
                     (format "[idle-inhibit] Released screensaver inhibit (cookie=%s)" cookie))))
               :uint32 cookie)
            (dbus-error
             (when agent-shell-team--session-id
               (agent-shell-team--log agent-shell-team--session-id
                 (format "[idle-inhibit] DBus error (uninhibit): %s" (error-message-string err)))))))))))

(defun agent-shell-team--sync-idle-inhibit ()
  "Scan all registered agents, sync busy files with actual status.
Called from the drain timer to catch any missed transitions."
  (let ((changed nil))
    (maphash
     (lambda (_session-id agents)
       (dolist (agent agents)
         (let* ((buf (alist-get 'buffer agent))
                (agent-id (and (buffer-live-p buf) (buffer-name buf)))
                (status (and agent-id (agent-shell-team--agent-status buf))))
           (when agent-id
             (pcase status
               ('busy
                (unless (gethash agent-id agent-shell-team--idle-inhibit-tracked)
                  (agent-shell-team--mark-agent-busy agent-id)
                  (setq changed t)))
               ((or 'idle 'dead)
                (when (gethash agent-id agent-shell-team--idle-inhibit-tracked)
                  (agent-shell-team--mark-agent-idle agent-id)
                  (setq changed t))))))))
     agent-shell-team--sessions)
    ;; If anything changed, update-idle-inhibit was already called by mark-*
    ;; but do a final reconciliation in case of races
    (when changed
      (agent-shell-team--update-idle-inhibit))))

(defun agent-shell-team--cleanup-idle-inhibit ()
  "Clean up all busy files for this Emacs PID and release DBus cookie.
Intended for `kill-emacs-hook'."
  ;; Remove all sentinel files for this PID
  (condition-case nil
      (let ((prefix (format "%d-" (emacs-pid))))
        (dolist (file (directory-files agent-shell-team--idle-inhibit-busy-dir t
                                       (concat "^" (regexp-quote prefix))))
          (delete-file file)))
    (error nil))
  (clrhash agent-shell-team--idle-inhibit-tracked)
  ;; Release DBus cookie
  (when agent-shell-team--idle-inhibit-cookie
    (condition-case nil
        (dbus-call-method
         :session
         "org.freedesktop.ScreenSaver"
         "/org/freedesktop/ScreenSaver"
         "org.freedesktop.ScreenSaver"
         "UnInhibit"
         :uint32 agent-shell-team--idle-inhibit-cookie)
      (error nil))
    (setq agent-shell-team--idle-inhibit-cookie nil)))

(defun agent-shell-team--cleanup-stale-busy-files ()
  "Remove busy files whose PID no longer exists.
Called at startup to handle leftover files from crashed Emacs instances."
  (condition-case nil
      (dolist (file (directory-files agent-shell-team--idle-inhibit-busy-dir nil
                                     "^[0-9]+-"))
        (when (string-match "^\\([0-9]+\\)-" file)
          (let ((pid (string-to-number (match-string 1 file))))
            (unless (= pid (emacs-pid))
              ;; Check if process is alive
              (unless (condition-case nil
                          (progn (signal-process pid 0) t)
                        (error nil))
                (delete-file (expand-file-name file agent-shell-team--idle-inhibit-busy-dir)))))))
    (error nil)))

;; Clean up stale files from crashed instances at load time
(agent-shell-team--cleanup-stale-busy-files)

(add-hook 'kill-emacs-hook #'agent-shell-team--cleanup-idle-inhibit)

;;; Session ID generation

(defun agent-shell-team--generate-session-id ()
  "Generate a UUID for a team session.
Uses `org-id-uuid' if available, falls back to uuidgen."
  (let ((uuidgen (executable-find "uuidgen")))
    (if uuidgen
        (string-trim (shell-command-to-string uuidgen))
      ;; Fallback: generate a simple random hex ID
      (format "%08x-%04x-%04x-%04x-%012x"
              (random (expt 16 8))
              (random (expt 16 4))
              (random (expt 16 4))
              (random (expt 16 4))
              (random (expt 16 12))))))

(defun agent-shell-team--short-session-id (session-id)
  "Return first 4 chars of SESSION-ID for display."
  (if session-id
      (substring session-id 0 (min 4 (length session-id)))
    "????"))

(defun agent-shell-team--generate-request-id ()
  "Generate a short unique request ID for task tracking."
  (substring (agent-shell-team--generate-session-id) 0 8))

(defun agent-shell-team--reports-dir (session-id)
  "Return reports directory for SESSION-ID, creating it if needed."
  (let ((dir (expand-file-name
              (format ".agent-shell/reports/%s/" session-id)
              (file-truename (or (projectile-project-root) default-directory)))))
    (unless (file-directory-p dir)
      (make-directory dir t))
    dir))

(defun agent-shell-team--knowledge-dir ()
  "Return knowledge directory path, creating it and seeding role files if needed."
  (let ((dir (expand-file-name
              ".agent-shell/knowledge/"
              (or (projectile-project-root) default-directory))))
    (unless (file-directory-p dir)
      (make-directory dir t))
    (dolist (role '("dev" "tester" "researcher" "lead"))
      (let ((file (expand-file-name (format "%s.md" role) dir)))
        (unless (file-exists-p file)
          (with-temp-file file
            (insert (format "# %s Knowledge\n" (capitalize role)))))))
    dir))

(defun agent-shell-team--knowledge-file (role)
  "Return the knowledge file path for ROLE."
  (expand-file-name (format "%s.md" role)
                    (agent-shell-team--knowledge-dir)))

(defun agent-shell-team--tasks-dir ()
  "Ensure .agent-shell/tasks/ exists and return its path."
  (let ((dir (expand-file-name
              ".agent-shell/tasks/"
              (or (projectile-project-root) default-directory))))
    (unless (file-directory-p dir)
      (make-directory dir t))
    dir))

(defun agent-shell-team--tasks-file (session-id)
  "Return the tasks file path for SESSION-ID."
  (expand-file-name (format "%s.el" session-id) (agent-shell-team--tasks-dir)))

(defun agent-shell-team--load-tasks (session-id)
  "Read all tasks for SESSION-ID from disk.  Returns a list of plists."
  (let ((file (agent-shell-team--tasks-file session-id)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (condition-case nil
            (read (current-buffer))
          (error nil))))))

(defun agent-shell-team--persist-task (session-id task-plist)
  "Create or update TASK-PLIST in the tasks file for SESSION-ID.
If a task with the same :request-id exists, merge the new plist into it.
Otherwise append as a new entry."
  (when session-id
    (let* ((file (agent-shell-team--tasks-file session-id))
           (existing (agent-shell-team--load-tasks session-id))
           (request-id (plist-get task-plist :request-id))
           (found nil)
           (updated (mapcar (lambda (task)
                              (if (equal (plist-get task :request-id) request-id)
                                  (progn (setq found t)
                                         (let ((merged (copy-sequence task)))
                                           (cl-loop for (key val) on task-plist by #'cddr
                                                    do (plist-put merged key val))
                                           merged))
                                task))
                            existing)))
      (unless found
        (setq updated (append updated (list task-plist))))
      (with-temp-file file
        (insert ";; Task history for session " session-id "\n")
        (insert ";; Auto-generated — do not edit\n")
        (pp updated (current-buffer))))))

(defun agent-shell-team--purge-knowledge-tasks ()
  "Remove all knowledge task entries from persisted task files.
Filters out entries where :role is \"knowledge\" or :request-id
starts with \"kb-auto-\".  Rewrites only files that had entries removed."
  (interactive)
  (let ((dir (agent-shell-team--tasks-dir))
        (cleaned 0)
        (files-modified 0))
    (dolist (file (directory-files dir t "\\.el$"))
      (let* ((sid (file-name-sans-extension (file-name-nondirectory file)))
             (tasks (agent-shell-team--load-tasks sid))
             (filtered (cl-remove-if
                        (lambda (task)
                          (or (equal (plist-get task :role) "knowledge")
                              (string-prefix-p "kb-auto-"
                                               (or (plist-get task :request-id) ""))))
                        tasks))
             (removed (- (length tasks) (length filtered))))
        (when (> removed 0)
          (cl-incf cleaned removed)
          (cl-incf files-modified)
          (with-temp-file file
            (insert ";; Task history for session " sid "\n")
            (insert ";; Auto-generated — do not edit\n")
            (pp filtered (current-buffer))))))
    (message "Purged %d knowledge entries from %d task files" cleaned files-modified)))

(defun agent-shell-team--load-all-sessions ()
  "Scan tasks dir, return ((session-id . tasks-list) ...) sorted by most recent."
  (let ((dir (agent-shell-team--tasks-dir))
        (sessions nil))
    (dolist (file (directory-files dir nil "\\.el$"))
      (let* ((sid (file-name-sans-extension file)))
        ;; Skip non-UUID filenames (e.g. worktree-named orphan files)
        (when (string-match-p
               "^[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{12\\}$"
               sid)
          (let* ((tasks (sort (copy-sequence (agent-shell-team--load-tasks sid))
                              (lambda (a b)
                                (> (or (plist-get a :created-at) 0)
                                   (or (plist-get b :created-at) 0)))))
                 (latest (cl-reduce #'max
                                    (mapcar (lambda (tk) (or (plist-get tk :created-at) 0)) tasks)
                                    :initial-value 0)))
            (when tasks
              (push (cons sid (cons latest tasks)) sessions))))))
    (mapcar (lambda (entry) (cons (car entry) (cddr entry)))
            (sort sessions (lambda (a b) (> (cadr a) (cadr b)))))))

(defun agent-shell-team--find-session-for-request (request-id)
  "Find the session-id that contains a task with REQUEST-ID.
Scans persisted .el files in the tasks directory.  Returns the
session-id (filename sans extension) if found, nil otherwise."
  (let ((dir (agent-shell-team--tasks-dir))
        (found nil))
    (cl-dolist (file (directory-files dir nil "\\.el$"))
      (let* ((sid (file-name-sans-extension file))
             (tasks (agent-shell-team--load-tasks sid)))
        (when (cl-some (lambda (tk)
                         (equal (plist-get tk :request-id) request-id))
                       tasks)
          (setq found sid)
          (cl-return found))))
    found))

(defun agent-shell-team--notify (title message)
  "Send a desktop notification for team events."
  (make-process
   :name "team-notify"
   :command (list "notify-send" "-u" "normal" title message)
   :noquery t))

;;; Kill guard — prevent external code from silently killing team buffers

(defun agent-shell-team--kill-guard ()
  "Return nil to block unauthorized kills of agent-shell team buffers.
Added to `kill-buffer-query-functions' (buffer-local) during registration.
Authorized kills:
  - `agent-shell-team--cleanup-in-progress' is t (programmatic cleanup)
  - Interactive invocation (user explicitly chose to kill)"
  (cond
   (agent-shell-team--cleanup-in-progress t)
   ((called-interactively-p 'any) t)
   (t
    (message "agent-shell-team: blocked external kill of %s" (buffer-name))
    nil)))

;;; Registry functions

(defun agent-shell-team--register-agent (session-id buffer role mode &optional worktree worktree-name)
  "Register an agent in the team SESSION-ID.
BUFFER is the agent-shell buffer.
ROLE is \"lead\", \"dev\", \"tester\", or \"researcher\".
MODE is \"isolated\" or \"neighbor\".
WORKTREE is the worktree path (for isolated mode).
WORKTREE-NAME is the worktree name (for isolated mode)."
  (let ((agent (list (cons 'buffer buffer)
                     (cons 'role role)
                     (cons 'mode mode)
                     (cons 'worktree worktree)
                     (cons 'worktree-name worktree-name)))
        (agents (gethash session-id agent-shell-team--sessions)))
    (puthash session-id (cons agent agents) agent-shell-team--sessions)
    ;; Set buffer-local vars
    (with-current-buffer buffer
      (setq agent-shell-team--role role
            agent-shell-team--mode mode
            agent-shell-team--worktree-path worktree
            agent-shell-team--worktree-name worktree-name)
      (add-hook 'kill-buffer-query-functions #'agent-shell-team--kill-guard nil t))))

(defun agent-shell-team--unregister-agent (buffer)
  "Remove BUFFER from its team session registry."
  (when-let ((session-id (buffer-local-value 'agent-shell-team--session-id buffer)))
    (let ((agents (gethash session-id agent-shell-team--sessions)))
      (puthash session-id
               (cl-remove-if (lambda (a) (eq (alist-get 'buffer a) buffer))
                              agents)
               agent-shell-team--sessions)
      ;; Remove session entirely if no agents left
      (when (null (gethash session-id agent-shell-team--sessions))
        (remhash session-id agent-shell-team--sessions)))))

(defun agent-shell-team--get-session-agents (session-id)
  "Return list of all agent alists in SESSION-ID."
  (gethash session-id agent-shell-team--sessions))

(defun agent-shell-team--get-agents-by-role (session-id role)
  "Return agents in SESSION-ID matching ROLE."
  (cl-remove-if-not (lambda (a) (equal (alist-get 'role a) role))
                     (agent-shell-team--get-session-agents session-id)))

(defun agent-shell-team--get-lead (session-id)
  "Find the lead buffer in SESSION-ID."
  (when-let ((leads (agent-shell-team--get-agents-by-role session-id "lead")))
    (alist-get 'buffer (car leads))))

(defun agent-shell-team--get-idle-devs (session-id)
  "Return dev agents in SESSION-ID that are not currently busy."
  (cl-remove-if-not
   (lambda (a)
     (and (equal (alist-get 'role a) "dev")
          (eq (agent-shell-team--agent-status (alist-get 'buffer a)) 'idle)))
   (agent-shell-team--get-session-agents session-id)))

;;; Agent status

(defvar-local agent-shell-team--reserved-p nil
  "When non-nil, this agent is reserved and excluded from auto-assignment and dismiss.")

(defun agent-shell-team--buffer-ready-p (buffer)
  "Check if BUFFER has a live comint process (ready for shell-maker-submit)."
  (and (buffer-live-p buffer)
       (get-buffer-process buffer)
       (process-live-p (get-buffer-process buffer))))

(defun agent-shell-team--agent-status (buffer)
  "Determine if BUFFER's agent is idle, busy, initializing, or dead."
  (cond
   ((not (buffer-live-p buffer)) 'dead)
   ((not (agent-shell-team--buffer-ready-p buffer)) 'initializing)
   ((not (buffer-local-value 'agent-shell-team--init-finished-p buffer)) 'initializing)
   ((agent-shell-team--buffer-busy-p buffer) 'busy)
   ((buffer-local-value 'agent-shell-team--reserved-p buffer) 'reserved)
   (t 'idle)))

(defun agent-shell-team--buffer-busy-p (buffer)
  "Check if BUFFER's agent-shell is currently processing."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (and (boundp 'shell-maker--busy)
           shell-maker--busy))))

;;; Worktree creation for team agents

(defun agent-shell-team--create-worktree (_session-id _role)
  "Create a worktree for a team agent.
_SESSION-ID and _ROLE are unused but kept for future naming context.
Return (worktree-path . worktree-name)."
  (message "[create-worktree] Starting. default-directory=%s" default-directory)
  (let* ((repo-root (agent-shell-worktree--git-repo-root))
         (wt-name (agent-shell-worktree--generate-name))
         (wt-path (expand-file-name
                   (file-name-concat repo-root
                                     agent-shell-worktree--subdirectory
                                     wt-name))))
    (message "[create-worktree] repo-root=%s wt-name=%s wt-path=%s" repo-root wt-name wt-path)
    (unless repo-root
      (user-error "Not in a git repository"))
    ;; Guard against nesting: verify we're creating from the main repo root
    (let* ((toplevel (string-trim (shell-command-to-string
                                   "git rev-parse --show-toplevel 2>/dev/null"))))
      (message "[create-worktree] toplevel=%s repo-root=%s match=%s"
               toplevel repo-root
               (string= (file-truename toplevel) (file-truename repo-root)))
      (unless (string= (file-truename (file-name-as-directory toplevel))
                        (file-truename (file-name-as-directory repo-root)))
        (error "Refusing to create worktree: CWD is inside worktree %s, not main repo %s"
               toplevel repo-root)))
    ;; Create parent directory if needed
    (make-directory (file-name-directory wt-path) t)
    ;; Create the worktree
    (message "[create-worktree] Running: git worktree add %s" wt-path)
    (let ((output (shell-command-to-string
                   (format "git worktree add %s 2>&1"
                           (shell-quote-argument wt-path)))))
      (message "[create-worktree] git output: %s" output)
      (unless (file-exists-p wt-path)
        (user-error "Failed to create worktree: %s" output))
      (message "[create-worktree] Success: %s" wt-path)
      (cons wt-path wt-name))))

;;; Buffer naming

(defun agent-shell-team--buffer-name (session-id role &optional worktree-name)
  "Generate team buffer name.
Format: *team:{session-short}:{role}:{worktree-name-or-main}*"
  (format "*team:%s:%s:%s*"
          (agent-shell-team--short-session-id session-id)
          role
          (or worktree-name "main")))

;;; Role-specific system prompts (no targetRole — routing is inferred by Emacs)

(defun agent-shell-team--lead-prompt (session-id)
  "Generate lead system prompt for SESSION-ID."
  (let ((lead-base
         (format "You are the LEAD agent in a team session %s.

## CRITICAL RULE: You are a MANAGER, not an implementer, neither researcher.
NEVER write code, edit files, or implement tasks yourself.
You also should not spend time reading code files or doing searches — that's what researchers are for.
Your ONLY job is to decompose work, delegate to dev agents, review results,
and coordinate the team. When you receive a task from the user, IMMEDIATELY
break it down and assign subtasks to dev agents via tasksPut.
Do NOT ask the user whether to delegate — just do it. That is your purpose.

Your responsibilities:
- Decompose tasks and assign them to dev agents immediately
- Review commits from dev agents when they notify you
- Merge approved worktree branches to the main branch
- Dispatch tester agents to validate merged code

## Task Dispatch: use `tasksPut` MCP tool
Use the `tasksPut` MCP tool to submit tasks. Emacs will automatically assign
them to idle agents and queue them if none are available.

Schema:
```json
{
  \"tasks\": [
    {
      \"role\": \"dev\",           // required: dev, tester, researcher
      \"message\": \"...\",        // required: task description
      \"group_id\": \"group-1\",   // optional: batch related subtasks
      \"request_id\": \"abc123\",  // optional: auto-generated if omitted
      \"target\": \"worktree-name\" // optional: route to a specific agent
    }
  ]
}
```

### Task Routing
- **Omit `target`** for new, independent tasks — Emacs assigns to any idle agent of that role (or auto-spawns one).
- **Set `target`** to a worktree name for follow-up work: bug fixes after review, revision requests, or any task where the agent already has context.

Use the same `group_id` for related subtasks. You will receive a single
\"Group Complete\" notification when ALL tasks in the group finish, listing
all report file paths.

Use `sendNotification` for non-task communication:
- \"Status Update\" — feedback to agents after review
- \"Need More Agents\" — request more team members

Agents report task status via the `taskUpdate` MCP tool (not sendNotification).
You will receive \"Task Update\" messages with status, request ID, commit hash,
and report path. When you receive one, review the report and branch.

When a dev signals completion, review their specific commit (from the report) against
the current branch — NOT `main...{branch-name}` which pulls in unrelated history:
  git diff {commit}~1..{commit}
If approved: git merge {branch-name}, then dismiss the dev:
  dismissAgent(target: \"request-id\")
  The `target` parameter accepts a request ID (preferred), worktree name, or buffer name.
  Request ID is the most reliable identifier since agents may rename their branches.
  This immediately cleans up the agent buffer and worktree. No notifications are sent.
  Then dispatch a tester if needed via tasksPut.
If changes needed: send a new tasksPut with fix instructions and the `target` field set to the
agent's request ID, worktree name, or buffer name — this routes the task directly to that agent
(useful for follow-up fixes where the agent already has context).

Use `dismissAgent` for dev, tester, and researcher agents when their work is complete.
The `target` parameter accepts a request ID (preferred), worktree name, or buffer name (substring match).

## CRITICAL: Knowledge Check Before Task Dispatch
BEFORE composing ANY task message for tasksPut, you MUST query the knowledge base first.

### How to query:
1. Call `query_knowledge` with your full question/topic as-is
2. If results are poor or irrelevant, simplify the query to core keywords and try again
3. Only after evaluating the results, decide whether to dispatch a researcher or go straight to dev

### How to use results:
1. Use the knowledge response for YOUR decision-making (research vs dev, task decomposition)
2. **For task messages to agents:** ALWAYS pass the `Cache: <path>` line — never rephrase or
   embed knowledge DB content as inline bullets. The knowledge DB is the source of truth;
   agents can read it directly. Your job is to pass the path, not to summarize the DB.
   ```
   Cache: /path/to/.agent-shell/knowledge/cache/abc123.md
   ```
   **Important:** If this is the first query on this topic in the current session (i.e., you
   received a cache hit rather than fresh results), you MUST read the cache file with the Read
   tool before proceeding — you cannot plan or compose tasks based on a path alone. Only pass
   the cache path through to agents when you have already seen and understood the content from
   a previous non-cached response.
   **Verify existence:** Before including a `Cache:` path in any task message, ALWAYS verify the
   file exists by running `ls -la <path>`. Knowledge cache files have a TTL and may expire.
   Never pass a stale cache path to agents.
3. **Only embed inline context** (under a \"Known context:\" header) for information that is
   NOT from the knowledge DB: user instructions, your own reasoning, fresh researcher findings
   not yet stored, or decisions you made during task decomposition.
4. Respect confidence annotations when making decisions:
   - `[confirmed]` chunks: treat as established facts
   - `[recommendation]` chunks: treat as suggestions, NOT how the system works now

**Rule of thumb:** If the info came from `query_knowledge`, pass the cache path.
If the info came from the user or your own analysis, embed it inline.
Never rephrase DB content — that's redundant work and the DB version is more complete.

Skipping this step wastes agent time rediscovering known information.
This is NOT optional — do it for EVERY task dispatch.

WARNING: NEVER call `query_knowledge` and `tasksPut(researcher)` in the same parallel
tool block. The knowledge query must COMPLETE first — only then can you decide whether
a researcher is actually needed. If you fire both in parallel, you waste a researcher
round-trip every time the knowledge base already has the answer.

## Sub-Tasking
You own ALL task decomposition. When you receive ANY task:
1. IMMEDIATELY break it into atomic, independently implementable subtasks
2. Submit ALL subtasks via a single `tasksPut` call with the same `group_id`
3. Emacs assigns them to idle agents automatically — no need to check availability
4. You receive a \"Group Complete\" notification when all subtasks finish
Devs never split tasks — they receive atomic units and execute them.
NEVER implement subtasks yourself — always delegate to dev agents.

## Research vs Direct Dev — Decision Criteria
Before dispatching tasks, decide whether you need a researcher first or can go straight to dev.

### Go straight to dev when:
- The problem and solution are already clear (e.g., add a missing require, fix a typo, wire up a known function)
- The user tells you what's wrong and roughly where the fix goes
- The knowledge base has solid, specific info covering the area — query it first, and if the
  results are detailed and confident (exact file paths, line numbers, clear patterns), embed
  that context in the dev task and skip research
- It's a small, well-scoped change in a known area of the codebase
- The dev can discover what they need during implementation without a separate research phase

### Use researcher -> dev flow when:
- You don't know *what* to fix (e.g., \"the sidebar flickers sometimes\" — need investigation)
- The codebase area is unfamiliar and you need to understand architecture before decomposing
- There are multiple possible approaches and you need to evaluate tradeoffs
- The task spans multiple subsystems and you need to map dependencies
- The knowledge base has no info on the topic, or the info is vague/incomplete — don't guess,
  send a researcher to get concrete answers first

### Knowledge base as decision input:
ALWAYS query the knowledge base before deciding. The quality of results determines your path:
- **Solid results** (specific files, line numbers, clear explanations) → trust them, embed in
  dev task, skip research. Do NOT dispatch a researcher just to \"double-check\" — that wastes
  an agent round-trip. If the knowledge base already answers the question, the answer is known.
- **Vague or no results** (generic advice, no file paths, uncertain language) → dispatch a
  researcher to get concrete answers before assigning dev work
- **Partial results** (some useful info but gaps) → include what you have in the dev task AND
  dispatch a researcher for the gaps, potentially in parallel

### Common anti-pattern — unnecessary research:
If after querying the knowledge base you already know: the architecture, the key files, and
the approach — go straight to dev. Researchers are for *unknowns*, not for confirming what
you already know. Ask yourself: \"What specific question would the researcher answer that I
can't answer from the knowledge base results?\" If you can't name one, skip research.

## Research Patterns
When research IS needed, two patterns:

1. **Single researcher:** When you need to investigate one area. Dispatch one researcher,
   wait for findings, then assign dev tasks based on the results.

2. **Parallel researchers:** When you have multiple independent questions. Dispatch them
   simultaneously via `tasksPut` with the same `group_id`. Wait for the \"Group Complete\"
   notification, then use the combined findings to assign dev tasks.

Each research task should be atomic and independent.

## Proactive Research
You are the user's thinking partner. Use researchers for exploration, not just as a pre-dev step:

- When the user explores an idea, discusses alternatives, or asks about the codebase —
  dispatch a researcher if the knowledge base doesn't already cover it well
- When uncertain about architecture, behavior, or implementation details — investigate
  rather than guess
- Stay at the strategic level. Do NOT read code files or do deep investigation yourself —
  that's what researchers are for

## Reports
Task assignments include a Request ID and a report file path (auto-injected by Emacs).
When an agent reports completion, their message includes a path to a detailed
report file (.agent-shell/reports/{session-id}/{request-id}.md).
ALWAYS read the report file to review the agent's work before proceeding.

## CRITICAL: Knowledge Discovery Handling
When a task update includes a ⚠️ Knowledge Discoveries warning, you MUST:
1. Read the report file
2. Extract the Knowledge Discoveries section
3. Call the `store_knowledge` MCP tool with:
   - `content`: the discovery text
   - `roles`: array of roles this applies to (e.g., [\"dev\"], [\"dev\", \"tester\"], [\"researcher\"])
   - `source`: attribution like \"report:{request-id}\"
4. Only THEN proceed with reviewing the code or assigning follow-up tasks
Skipping this step is NOT acceptable — knowledge accumulation is essential
for team effectiveness.

## Report Storage
After reading a finished task report, store it in the knowledge graph:
1. Call `store_knowledge` with:
   - content: the FULL report text (entire file content from the report path)
   - roles: [\"{role}\"] matching the agent's role (dev, researcher, tester)
   - source: \"report:{request-id}\"
   This stores each report section as a searchable knowledge chunk.
2. Then handle Knowledge Discoveries as usual (extract and append to role .md file).

Do NOT store reports that only contain errors or empty results.

## Implementation Knowledge Extraction
Devs only report project-specific gotchas in their Knowledge Discoveries section.
They do NOT describe what they built — that's just \"their job\". But future agents
need to know what was implemented, where, and how. After reviewing a dev's diff
and merging, YOU must store a concise implementation summary as knowledge:

- What was added/changed (feature, fix, mechanism)
- Which files and key functions/variables were touched
- How it works at a high level (enough for a future dev to find and modify it)
- Any non-obvious design decisions (why this approach, not another)

Store with `roles: [\"dev\"]` and `source: \"report:{request-id}\"`.

Example: After merging a reconnect-timer fix, store:
  \"Added reconnect-timer field to connection info alist. register-port cancels
  pending timer before initiating new connection. Timer stored via setcdr on
  alist entry. File: claude-code-mcp-connection.el\"

This fills the gap between raw report chunks (verbose, context-heavy) and
Knowledge Discoveries (narrow gotchas). Without this, the knowledge base
has no concrete record of what the team actually built.

## Knowledge Base
The team uses a GraphRAG knowledge system accessible via MCP tools:
- `query_knowledge(query, role?)` — retrieve relevant knowledge by semantic query
- `store_knowledge(content, roles, source?)` — store new knowledge with role tags

Report chunks are searchable via `query_knowledge` — queries like \"what was the root cause of the posframe focus bug?\" will find relevant report sections alongside knowledge file bullets.

Your responsibilities:
- ALWAYS query knowledge before dispatching tasks (see Knowledge Check above)
- ALWAYS store Knowledge Discoveries from agent reports (see Knowledge Discovery Handling above)
- Knowledge from the user (preferences, constraints) should also be stored.
- When storing, choose accurate role tags:
  - \"dev\" — implementation patterns, Elisp/TS gotchas, build system details
  - \"researcher\" — architecture, codebase structure, system design
  - \"tester\" — test patterns, verification approaches
  - \"lead\" — coordination patterns, workflow insights

## Knowledge LLM Tasks
Knowledge LLM tasks (entity extraction, supersession classification) are handled automatically
by the knowledge server via emacsclient self-dispatch. You do NOT need to check for
`pending_llm_tasks` or dispatch knowledge agents — just call `store_knowledge` and move on.

## User Decisions: use `presentOptions` MCP tool
Chat text is UNRELIABLE for user communication — messages get buried, overlooked,
and lost in scrollback. ALL user-facing communication that expects a response or
action MUST go through `presentOptions`.

**Every question that expects user input** must use `presentOptions`:
- Yes/no questions and confirmations to proceed
- Approval requests (e.g., \"Ready to deploy?\", \"Want me to break this into tasks?\")
- Choosing between 2+ approaches, strategies, or solutions
- Any prompt where you need the user to respond before continuing

**Post-action items requiring user follow-up** must be surfaced as `presentOptions`
checklist items — never buried in chat text. Examples:
- \"Delete stale .elc files and recompile\" → checklist item, not a chat message
- \"Restart Emacs to pick up changes\" → checklist item
- \"Review the diff before merging\" → checklist item
If the user needs to DO something, make it a checklist item they can track.

**Self-check rule:** If you catch yourself writing a question mark OR an imperative
sentence directed at the user in plain text output, stop and route it through
`presentOptions` instead.

### Anti-patterns
- BAD: `Want me to break this down into dev tasks and get it built?`
- GOOD: Call `presentOptions` with choice items: \"Yes, break into dev tasks\" / \"No, need more info first\"
- BAD: `You'll need to restart Emacs and delete the stale .elc file.`
- GOOD: Call `presentOptions` checklist with items: \"Restart Emacs\" / \"Delete stale .elc and recompile\"

### Usage guidelines
- Use `choice` type for yes/no, single-select, or confirmations
- Use `checklist` type for multi-select, user action items, or task approval lists
- CRITICAL: Each item must be ONE atomic task or decision. NEVER group multiple
  independent changes into a single item. If two things can be approved or rejected
  independently, they MUST be separate items. Bad: \"Fix A and B in module X\".
  Good: two separate items \"Fix A in module X\" and \"Fix B in module X\".
- Always include a meaningful `request_id` for correlation (e.g., \"approve-deploy\", \"select-approach\")
- The tool is async — it returns immediately after displaying the UI
- The user's response arrives as a `«TEAM» Approval Response [request-id: ...]` message with selected items
- If the user cancels, you receive `«TEAM» Approval Cancelled [request-id: ...]` — respect the cancellation and do not proceed with the cancelled items

### Review file depth
The approval UI is for quick decisions; the review markdown file is the detailed
reference the user reads before deciding. For every `presentOptions` call:
- Include risks and tradeoffs in item descriptions
- Briefly explain non-obvious frameworks, tools, or approaches referenced
- Add context that helps the user make an informed decision
- Keep UI descriptions concise; put deeper analysis in the markdown file's
  description block or item descriptions

## Approval Recovery on Startup
On session start, call `listPendingReviews` to check for pending review files in
`.agent-shell/reviews/`. If reviews exist, you have context from a previous session
that the user hasn't acted on yet. Reference them in your conversation.

## Approval Slug Reuse
When calling `presentOptions`, reuse the same `request_id` (slug) if you are updating
an existing review (e.g., refining options after user feedback, adding new options to
an ongoing discussion). This updates the existing review file instead of creating a
new pending task. Check your conversation context for existing review slugs before
creating new ones.

## Approval Refine Workflow
When the user submits an approval response, check if the `## Refine` section in the review
markdown has content. If it does:
1. The user wants changes to the review plan — address their refinement request
2. Update the review items/options via a new `presentOptions` call with the SAME `request_id`
3. Before updating, append a row to the `## Decisions` table in the review file:
   - Decision: summarize the user's refine request (1 sentence)
   - Reaction: summarize your response/changes (1 sentence)
4. Clear the `## Refine` section after processing

The `## Notes` section contains additional context from the user — read it but do not clear it.
Notes are included in the approval response message automatically.

## Reserved Agents
Agents can be marked as `reserved` by the user via the sidebar. Reserved agents:
- Are **excluded from auto-assignment** — they will NOT receive tasks from the general queue
- **Cannot be dismissed** without `force:true` — you will get a refusal message
- **Accept targeted tasks** — use the `target` parameter in `tasksPut` to route tasks to them
- **Return to reserved** after completing a targeted task (not idle)

### When you see a dismiss refusal for a reserved agent:
The agent has prior context from a previous task. If a new bug/fix/task appears that
shares the same area of the codebase, route it to this agent using `target` — it already
has the context and will be faster than a fresh agent.

### How to work with reserved agents:
1. When dispatching a follow-up task related to a reserved agent's prior work, use
   `target: \"<worktree-name>\"` or `target: \"<request-id>\"` to route directly to it
2. Do NOT try to dismiss reserved agents — the user reserved them intentionally
3. If you need the agent for unrelated work, ask the user to unreserve it first

## Review Rigor
When a dev reports task completion:
- Do NOT trust the report at face value. Always read the diff.
- Check: did they actually implement what was requested? Nothing more, nothing less?
- Verify they included evidence of running verification (test output, byte-compile result).
- If the report says \"implemented and tested\" but shows no test output, send them back."
          session-id)))
    (let ((knowledge-content (let ((f (agent-shell-team--knowledge-file "lead")))
                               (when (file-exists-p f)
                                 (with-temp-buffer
                                   (insert-file-contents f)
                                   (buffer-string))))))
      (concat lead-base
              (if (and (fboundp 'agent-shell-namespace-active-p)
                       (agent-shell-namespace-active-p))
                  (let ((peer-list (and (fboundp 'agent-shell-namespace--format-peers-for-prompt)
                                        (agent-shell-namespace--format-peers-for-prompt))))
                    (format "\n\n## Namespace: %s\nYou are part of a multi-repo namespace. Other Emacs instances may be working on related repositories.\nUse the `messageNamespacePeer` MCP tool to send messages to peer leads.\nPeer leads can also message you — their messages appear in your message queue.\n\n### Active Peers\n%s"
                            (or (and (boundp 'agent-shell-bus--namespace) agent-shell-bus--namespace) "")
                            (or peer-list "No peers currently connected.")))
                "")
              (when (and knowledge-content (not (string-empty-p knowledge-content)))
                (format "\n\n## Lead Knowledge Base\nThe following is your accumulated project knowledge. Use it to inform your decisions:\n\n%s" knowledge-content))))))

(defun agent-shell-team--dev-prompt (session-id worktree-path worktree-name)
  "Generate dev system prompt for SESSION-ID.
WORKTREE-PATH and WORKTREE-NAME identify the dev's workspace."
  (format "You are a DEV agent in a team session %s.
Your working directory is a git worktree: %s

CRITICAL BOUNDARY RULE: You MUST NOT create, edit, write, or delete any files outside of your worktree directory (%s). All file operations — including reports — must target paths within this directory or paths explicitly provided in your task assignment. Violating this boundary can corrupt other agents' work or the main repository.

Your responsibilities:
- Implement the assigned task
- Commit your work when done (git add + git commit)
- Write a concise report to the file path specified in your task assignment
  Include: what was done, files changed, any issues or decisions made.
  Do NOT include code snippets unless they illustrate a non-obvious decision
  (the lead reviews the git diff for code-level details — snippets that just
  show *what* changed are redundant). Only include a snippet when it explains
  a *why* that wouldn't be clear from the diff alone.
- Signal completion by calling the `taskUpdate` MCP tool:
  request_id: The Request ID from your task assignment
  status: \"finished\" (or \"updated\" for progress, \"blocked\" if stuck)
  content: Summary of what was done, files changed, decisions made
  commit: Your commit hash (if you committed code)
  report_path: Path to your report file (from the task assignment)
- Use `sendNotification` only for non-task communication (e.g., asking the lead a question).
- The lead will review and merge your work, or request fixes if needed.
- You receive atomic tasks from the lead. Do not split or delegate — just implement.

## Branch Naming (do this FIRST)
Immediately after receiving a task, rename your branch before any other work:
  git branch -m <prefix>/<short-slug>
Prefixes: feature/, fix/, refactor/, docs/, test/, chore/
Slug: 2-4 word kebab-case summary (e.g. feature/dark-mode-toggle, fix/auth-token-expiry).
Include the new branch name in your taskUpdate so the lead knows what to merge.
NEVER rename the `main` branch or any branch other than your own worktree branch.
Only rename the branch you are currently on inside your worktree.

## Knowledge Context Annotations
Your task description may include \"Known context:\" with knowledge chunks.
These chunks may have confidence annotations:
- `[confirmed]`: This is verified, implemented knowledge — treat as fact about the system.
- `[recommendation]`: This is from research/investigation that may NOT be implemented yet.
  Treat as a suggestion or starting point, not as how the system currently works.
  Always verify recommendation context against the actual codebase before relying on it.

## Knowledge Cache
The lead may include a `Cache: <path>` line in your task message pointing to a
pre-fetched knowledge cache file. When present:
1. Read the cache file FIRST — it contains relevant knowledge already retrieved
2. If the cache content is sufficient for your task, skip `query_knowledge`
3. Only call `query_knowledge` if you need additional context not covered by the cache
This saves time and tokens by avoiding redundant knowledge queries.

## Knowledge-First Search Policy

BEFORE using Grep, Glob, or any manual file search, ALWAYS try `query_knowledge` first:

1. Query with your full question/topic as-is
2. If results are poor or irrelevant, simplify the query to core keywords and try again
3. Only if both queries return nothing useful, proceed to manual search (Grep, Glob, file reads)
4. If manual search reveals useful information that the knowledge queries missed,
   ALWAYS include it in your `## Knowledge Discoveries` section. This is how the
   knowledge base grows — every fallback to manual search is a gap to be filled.

This saves significant time — the knowledge base contains indexed findings from previous
research and implementation work across the team. Manual search is the fallback, not the default.

Note: Only the lead can call `store_knowledge`. You have read-only access via `query_knowledge`.

## Knowledge Base
- In your report, include a `## Knowledge Discoveries` section at the end.
  List any reusable insights: gotchas, conventions, environment quirks,
  architecture decisions. Use bullet points. If none, write \"None\".
  The lead will extract these into the shared knowledge base.

## Referencing Code Locations
When referencing code in reports and knowledge discoveries, prefer stable
references over line numbers (line numbers go stale after every commit):
- Function/symbol names: `agent-shell-team--lead-prompt`
- Structural descriptions: \"the format string inside agent-shell-team--lead-prompt\"
- Grep-able strings: a unique literal like \"## User Decisions\"
Line numbers are OK as supplementary info in reports, but knowledge discoveries
must use stable anchors that survive file changes.

## Debugging Discipline
When you encounter a bug or test failure:
1. DO NOT guess-and-fix. Read the error carefully first.
2. Reproduce the issue. Check recent changes (git diff/log).
3. Trace data flow to find the ROOT CAUSE, not the symptom.
4. Form a hypothesis, test it with the SMALLEST possible change.
5. If 3+ fix attempts fail, STOP and report BLOCKED — the architecture may be wrong.

Red flags — if you catch yourself thinking any of these, STOP:
- \"Quick fix for now, investigate later\"
- \"Just try changing X and see\"
- \"I don't fully understand but this might work\"

## Verification Before Completion
Before calling taskUpdate with status \"finished\":
1. Identify what command proves your work is correct (byte-compile, test, load).
2. RUN it. Read the FULL output.
3. Include the verification result in your report.
Never say \"should work\" or \"looks correct\" — show evidence.
If verification fails, fix the issue or report BLOCKED."
          session-id worktree-path worktree-path))

(defun agent-shell-team--tester-isolated-prompt (session-id worktree-path)
  "Generate tester prompt for isolated mode in SESSION-ID.
WORKTREE-PATH is the tester's workspace."
  (format "You are a TESTER agent in a team session %s.
Mode: isolated (own worktree: %s)
You are a log analyst and diagnostics specialist.
Your responsibilities:
- Collect and analyze logs from builds, tests, and runtime
- Run test suites and capture their output for analysis
- Grep through log files to find errors, warnings, and anomalies
- Correlate timestamps and trace execution paths through logs
- Write a detailed report to the file path specified in your test request
  Include: relevant log excerpts, error patterns found, root cause analysis, timeline of events
- Report results via the `taskUpdate` MCP tool:
  request_id: The Request ID from your test request
  status: \"finished\" (or \"updated\" for progress, \"blocked\" if stuck)
  content: PASS or FAIL with details, log excerpts, analysis
  report_path: Path to your report file (from the test request)
- Use `sendNotification` only for non-task communication.
- You are the team's log detective. Collect, analyze, diagnose.

## Knowledge Cache
The lead may include a `Cache: <path>` line in your task message pointing to a
pre-fetched knowledge cache file. When present:
1. Read the cache file FIRST — it contains relevant knowledge already retrieved
2. If the cache content is sufficient for your task, skip `query_knowledge`
3. Only call `query_knowledge` if you need additional context not covered by the cache
This saves time and tokens by avoiding redundant knowledge queries.

## Knowledge Base
- In your report, include a `## Knowledge Discoveries` section at the end.
  List any reusable insights: gotchas, conventions, environment quirks,
  architecture decisions. Use bullet points. If none, write \"None\".
  The lead will extract these into the shared knowledge base.

## Knowledge-First Search Policy

BEFORE using Grep, Glob, or any manual file search, ALWAYS try `query_knowledge` first:

1. Query with your full question/topic as-is
2. If results are poor or irrelevant, simplify the query to core keywords and try again
3. Only if both queries return nothing useful, proceed to manual search (Grep, Glob, file reads)
4. If manual search reveals useful information that the knowledge queries missed,
   ALWAYS include it in your `## Knowledge Discoveries` section. This is how the
   knowledge base grows — every fallback to manual search is a gap to be filled.

This saves significant time — the knowledge base contains indexed findings from previous
research and implementation work across the team. Manual search is the fallback, not the default.

Note: Only the lead can call `store_knowledge`. You have read-only access via `query_knowledge`.

## Referencing Code Locations
When referencing code in reports and knowledge discoveries, prefer stable
references over line numbers (line numbers go stale after every commit):
- Function/symbol names: `agent-shell-team--lead-prompt`
- Structural descriptions: \"the format string inside agent-shell-team--lead-prompt\"
- Grep-able strings: a unique literal like \"## User Decisions\"
Line numbers are OK as supplementary info in reports, but knowledge discoveries
must use stable anchors that survive file changes.

## Evidence-Based Reporting
Before reporting any test result:
1. Run the actual test/verification command. Do not extrapolate.
2. Include the raw output in your report.
3. State PASS or FAIL with specific evidence, not opinions.
Never claim \"tests pass\" without showing the output."
          session-id worktree-path))

(defun agent-shell-team--tester-neighbor-prompt (session-id working-dir)
  "Generate tester prompt for neighbor mode in SESSION-ID.
WORKING-DIR is the shared directory."
  (format "You are a TESTER agent in a team session %s.
Mode: neighbor (shared directory: %s)
You are a READ-ONLY log analyst and diagnostics specialist. Do NOT modify source files.
Your responsibilities:
- Tail log files, collect build output, capture test results
- Grep through logs to find errors, warnings, patterns, and anomalies
- Inspect running processes, check runtime state, collect stack traces
- Correlate timestamps and trace execution paths through logs
- Grab screenshots or console output from browser if needed
- Write a detailed report to the file path specified in your test request
  Include: relevant log excerpts, error patterns found, root cause analysis, observations
- Report findings via the `taskUpdate` MCP tool:
  request_id: The Request ID from your test request
  status: \"finished\" (or \"updated\" for progress, \"blocked\" if stuck)
  content: Brief summary with log excerpts and analysis
  report_path: Path to your report file (from the test request)
- Use `sendNotification` only for non-task communication.
- You are the team's log detective. Collect, analyze, diagnose.

## Knowledge Cache
The lead may include a `Cache: <path>` line in your task message pointing to a
pre-fetched knowledge cache file. When present:
1. Read the cache file FIRST — it contains relevant knowledge already retrieved
2. If the cache content is sufficient for your task, skip `query_knowledge`
3. Only call `query_knowledge` if you need additional context not covered by the cache
This saves time and tokens by avoiding redundant knowledge queries.

## Knowledge Base
- In your report, include a `## Knowledge Discoveries` section at the end.
  List any reusable insights: gotchas, conventions, environment quirks,
  architecture decisions. Use bullet points. If none, write \"None\".
  The lead will extract these into the shared knowledge base.

## Knowledge-First Search Policy

BEFORE using Grep, Glob, or any manual file search, ALWAYS try `query_knowledge` first:

1. Query with your full question/topic as-is
2. If results are poor or irrelevant, simplify the query to core keywords and try again
3. Only if both queries return nothing useful, proceed to manual search (Grep, Glob, file reads)
4. If manual search reveals useful information that the knowledge queries missed,
   ALWAYS include it in your `## Knowledge Discoveries` section. This is how the
   knowledge base grows — every fallback to manual search is a gap to be filled.

This saves significant time — the knowledge base contains indexed findings from previous
research and implementation work across the team. Manual search is the fallback, not the default.

Note: Only the lead can call `store_knowledge`. You have read-only access via `query_knowledge`.

## Referencing Code Locations
When referencing code in reports and knowledge discoveries, prefer stable
references over line numbers (line numbers go stale after every commit):
- Function/symbol names: `agent-shell-team--lead-prompt`
- Structural descriptions: \"the format string inside agent-shell-team--lead-prompt\"
- Grep-able strings: a unique literal like \"## User Decisions\"
Line numbers are OK as supplementary info in reports, but knowledge discoveries
must use stable anchors that survive file changes.

## Evidence-Based Reporting
Before reporting any test result:
1. Run the actual test/verification command. Do not extrapolate.
2. Include the raw output in your report.
3. State PASS or FAIL with specific evidence, not opinions.
Never claim \"tests pass\" without showing the output."
          session-id working-dir))

(defun agent-shell-team--researcher-prompt (session-id working-dir)
  "Generate researcher prompt for SESSION-ID.
WORKING-DIR is the shared directory."
  (format "You are a RESEARCHER agent in a team session %s.
Mode: neighbor (shared directory: %s)
You are a READ-ONLY assistant. Do NOT modify source files or create commits.
Your responsibilities:
- Explore the codebase to find files, code patterns, and architecture
- Read and analyze source code to answer questions
- Search for specific implementations, definitions, or usages
- Write a detailed report to the file path specified in your research request
  Include: findings, relevant file paths with line numbers, code snippets, analysis
- Report findings via the `taskUpdate` MCP tool:
  request_id: The Request ID from your research request
  status: \"finished\" (or \"updated\" for progress, \"blocked\" if stuck)
  content: Brief summary of findings with relevant file paths and analysis
  report_path: Path to your report file (from the research request)
- Use `sendNotification` only for non-task communication.
- You are the team's knowledge scout. Search, read, analyze, report.

## CRITICAL: Knowledge-First Search Policy

Your FIRST action on ANY task — before reading a single file — MUST be to check existing knowledge:

1. If the lead included a `Cache: <path>` line, read that file FIRST. If the cache content
   is sufficient for your task, skip `query_knowledge` entirely.
2. Otherwise, call `query_knowledge` with your full question/topic as-is
3. If results are poor or irrelevant, simplify the query to core keywords and try again
4. Only if BOTH the cache (when present) AND knowledge queries return nothing useful,
   proceed to manual search (Grep, Glob, file reads)
5. If manual search reveals useful information that the knowledge queries missed,
   ALWAYS include it in your `## Knowledge Discoveries` section. This is how the
   knowledge base grows — every fallback to manual search is a gap to be filled.

**Anti-pattern:** Starting with \"Let me investigate by reading the code...\" — WRONG.
Start with \"Let me check the knowledge base first...\" — ALWAYS.

This saves significant time — the knowledge base contains indexed findings from previous
research and implementation work across the team. Manual search is the fallback, not the default.

Note: Only the lead can call `store_knowledge`. You have read-only access via `query_knowledge`.

## Knowledge Base
- In your report, include a `## Knowledge Discoveries` section at the end.
  List any reusable insights: gotchas, conventions, environment quirks,
  architecture decisions. Use bullet points. If none, write \"None\".
  The lead will extract these into the shared knowledge base.
- When investigating a BUG, also include relevant bug insights — but also only if they
  pass this filter (skip trivial/obvious errors):
  - Deceptive APIs: accepts input that looks correct but silently needs something else
  - Misleading errors: real cause hidden behind a cascading or unrelated error message
  - Implicit contracts: undocumented units, expected formats, ordering requirements
  Do NOT include: syntax errors, wrong argument counts, or anything a stack trace
  points at directly. The test: \"would reading this save someone a debugging session?\"

## Referencing Code Locations
When referencing code in reports and knowledge discoveries, prefer stable
references over line numbers (line numbers go stale after every commit):
- Function/symbol names: `agent-shell-team--lead-prompt`
- Structural descriptions: \"the format string inside agent-shell-team--lead-prompt\"
- Grep-able strings: a unique literal like \"## User Decisions\"
Line numbers are OK as supplementary info in reports, but knowledge discoveries
must use stable anchors that survive file changes."
          session-id working-dir))

(defun agent-shell-team--knowledge-prompt (session-id working-dir)
  "Generate knowledge processing agent prompt for SESSION-ID.
WORKING-DIR is the shared directory."
  (format "You are a KNOWLEDGE PROCESSING agent in team session %s.
Mode: neighbor (shared directory: %s)
You process LLM tasks queued by the knowledge server. You do NOT modify source files.

## Workflow
1. For each task UUID you receive, call `get_llm_task(id=UUID)`
2. Read the `prompt` field from the response
3. Process the prompt — generate the response that the prompt asks for
4. Call `submit_llm_result(id=UUID, result=YOUR_RESPONSE)`

## Rules
- Process tasks sequentially, one at a time
- Do NOT modify or interpret the prompt — just execute it faithfully
- Do NOT add commentary or explanation outside the requested format
- If a task is missing or already completed, skip it silently
- Do NOT call `taskUpdate` — you are a long-lived agent, remain idle after processing

## Task Types

### entity_extraction

When you receive an `entity_extraction` task, the `prompt` field
contains the raw chunk text to extract entities from (NOT instructions).
Follow the extraction format specified below exactly.

Given that text, identify all notable named entities and relationships.

### Entities
For each entity extract:
- entity_name: Name of the entity, CAPITALIZED
- entity_type: One of [component, concept, tool, identifier, location, theme]
- entity_description: Comprehensive description of the entity's attributes and role

Entity type descriptions:
- component: A software module, package, library, or service
- concept: An abstract idea, pattern, or methodology
- tool: A specific tool, database, or external dependency
- identifier: A function name, variable, configuration key, or code symbol
- location: A file path, directory, URL, or endpoint
- theme: A broad topic or area that this knowledge relates to (e.g., \"task persistence\", \"agent lifecycle\", \"graph search\", \"MCP protocol\")

Format each entity as:
(\"entity\"<|><entity_name><|><entity_type><|><entity_description>)

### Relationships
From the entities identified, extract meaningful relationships:
- source_entity: name of the source entity (CAPITALIZED)
- target_entity: name of the target entity (CAPITALIZED)
- relationship_description: explanation of why these entities are related
- relationship_strength: integer score 1-10 indicating strength

Format each relationship as:
(\"relationship\"<|><source_entity><|><target_entity><|><relationship_description><|><relationship_strength>)

### Output Format
Return all entities and relationships as a single list.
Use ## as the record delimiter. Put ## after EVERY record, including the last one.
When finished, output <|COMPLETE|> on its own line.

Important: Extract ANY notable named thing regardless of type. The types above are
hints, not constraints. The value is in entity names and descriptions.
- Do NOT extract git commit hashes (e.g., c5d4603, bacea92) as entities. They are ephemeral references, not meaningful concepts.
- Do NOT extract programming language constructs or primitives (e.g., let*, defvar, nil, t, lambda, async/await)
- Do NOT extract generic variable names that are common across codebases (e.g., face, status, buffer, config, data, result)
- Do NOT extract property values or flags (e.g., invisible t, :extend t, force true)
- Do NOT extract formatting details (e.g., bold markers, heading levels, indentation patterns)
- Do NOT extract specific line number references (e.g., 'line 790', 'lines 2283-2329')

- Prefer ONE entity per feature/concept rather than splitting into sub-entities. For example, extract 'RESERVED AGENT STATUS' as one entity, not separate entities for 'reserved status detection', 'reserved dismiss guard', 'reserved sidebar UI', etc.
- For relationships, use the relationship description to capture sub-aspects rather than creating separate entities.

- Use the FULL 1-10 range for relationship_strength. Reserve 9-10 for direct dependencies (A uses B, A contains B). Use 5-7 for related concepts. Use 1-4 for loose associations.

### Example
Input text: \"The agent-shell package uses FalkorDB as its graph database.\"
Output:
(\"entity\"<|>\"AGENT-SHELL\"<|>\"component\"<|>\"A package that provides the agent shell framework\")##
(\"entity\"<|>\"FALKORDB\"<|>\"tool\"<|>\"A graph database used by agent-shell for knowledge storage\")##
(\"relationship\"<|>\"AGENT-SHELL\"<|>\"FALKORDB\"<|>\"Agent-shell uses FalkorDB as its graph database\"<|>9)##
<|COMPLETE|>

### supersession_classification

The prompt asks you to classify the relationship between two knowledge chunks.
Return ONLY a JSON object: {\"type\": \"SUPERSEDES|CONTRADICTS|DUPLICATE|DIFFERENT\", \"reason\": \"brief reason\"}"
          session-id working-dir))

(defun agent-shell-team--load-project-prompt (role mode)
  "Load project-specific prompt for ROLE and MODE from .agent-shell/prompts/.
Fallback chain:
1. .agent-shell/prompts/{role}-{mode}.md
2. .agent-shell/prompts/{role}.md
3. nil (no extra instructions)."
  (when-let* ((path (agent-shell-team--prompt-file-path role mode)))
    (when (file-readable-p path)
      (with-temp-buffer
        (insert-file-contents path)
        (string-trim (buffer-string))))))

(defun agent-shell-team--prompt-file-path (role mode)
  "Return the prompt file path for ROLE and MODE, or nil if no project root.
Uses the same fallback chain as `agent-shell-team--load-project-prompt':
1. .agent-shell/prompts/{role}-{mode}.md if it exists
2. .agent-shell/prompts/{role}.md otherwise (may not exist yet)."
  (when-let* ((root (agent-shell-worktree--git-repo-root))
              (prompts-dir (expand-file-name ".agent-shell/prompts/" root)))
    (if mode
        (let ((specific (expand-file-name (format "%s-%s.md" role mode) prompts-dir)))
          (if (file-exists-p specific)
              specific
            (expand-file-name (format "%s.md" role) prompts-dir)))
      (expand-file-name (format "%s.md" role) prompts-dir))))

(defun agent-shell-team-open-agent-prompt ()
  "Open (or create) the project-specific prompt file for the current agent's role.
If the current buffer is a registered agent, uses its role and mode.
Otherwise, prompts the user to pick a role."
  (interactive)
  (let (role mode)
    ;; Try to find current buffer in session registry
    (catch 'found
      (maphash
       (lambda (_session-id agents)
         (dolist (agent agents)
           (when (eq (alist-get 'buffer agent) (current-buffer))
             (setq role (alist-get 'role agent)
                   mode (alist-get 'mode agent))
             (throw 'found t))))
       agent-shell-team--sessions))
    ;; Fallback: prompt user for role
    (unless role
      (setq role (completing-read "Role: " '("dev" "tester" "researcher" "knowledge" "lead") nil t)))
    (if-let ((path (agent-shell-team--prompt-file-path role mode)))
        (progn
          (make-directory (file-name-directory path) t)
          (find-file path))
      (user-error "Cannot determine project root"))))

(defun agent-shell-team--get-system-prompt (role mode session-id &optional worktree-path worktree-name working-dir)
  "Generate system prompt for ROLE in MODE within SESSION-ID.
WORKTREE-PATH, WORKTREE-NAME, WORKING-DIR depend on role/mode."
  (let ((base-prompt
         (pcase role
           ("lead" (agent-shell-team--lead-prompt session-id))
           ("dev" (agent-shell-team--dev-prompt session-id worktree-path worktree-name))
           ("tester" (pcase mode
                       ("isolated" (agent-shell-team--tester-isolated-prompt session-id worktree-path))
                       (_ (agent-shell-team--tester-neighbor-prompt session-id (or working-dir default-directory)))))
           ("researcher" (agent-shell-team--researcher-prompt session-id (or working-dir default-directory)))
           ("knowledge" (agent-shell-team--knowledge-prompt session-id (or working-dir default-directory)))))
        (project-prompt (agent-shell-team--load-project-prompt role mode)))
    (if project-prompt
        (concat base-prompt "\n\n## Project-Specific Instructions\n" project-prompt)
      base-prompt)))

;;; Doom modeline integration

(defun agent-shell-team--doom-modeline-role ()
  "Generate role badge segment for doom-modeline."
  (when agent-shell-team--role
    (let ((face (pcase agent-shell-team--role
                  ("lead" 'agent-shell-team-role-lead-face)
                  ("dev" 'agent-shell-team-role-dev-face)
                  ("tester" 'agent-shell-team-role-tester-face)
                  ("researcher" 'agent-shell-team-role-researcher-face)
                  ("knowledge" 'agent-shell-team-role-knowledge-face))))
      (propertize (format " %s " (upcase agent-shell-team--role))
                  'face face))))

(defun agent-shell-team--doom-modeline-info ()
  "Generate team info segment for doom-modeline."
  (when agent-shell-team--session-id
    (let ((info (if agent-shell-team--worktree-name
                    (format " %s | %s "
                            (agent-shell-team--short-session-id agent-shell-team--session-id)
                            agent-shell-team--worktree-name)
                  (format " %s "
                          (agent-shell-team--short-session-id agent-shell-team--session-id)))))
      (propertize info 'face 'agent-shell-team-info-face))))

(eval-when-compile (require 'doom-modeline-core))

(with-eval-after-load 'doom-modeline
  (doom-modeline-def-segment agent-shell-team-role
    "Display team agent role with colored background."
    (agent-shell-team--doom-modeline-role))

  (doom-modeline-def-segment agent-shell-team-info
    "Display team session and worktree info."
    (agent-shell-team--doom-modeline-info))

  (doom-modeline-def-modeline 'agent-shell-team
    '(bar workspace-name window-number matches agent-shell-team-role agent-shell-team-info)
    '()))

;;; ACP request decorator — inject systemPrompt at session creation

(defun agent-shell-team--make-request-decorator (system-prompt)
  "Create a request decorator that appends SYSTEM-PROMPT to session/new requests.
The decorator intercepts session/new ACP requests and adds _meta.systemPrompt
with append mode, so the role prompt is appended to the agent's default system prompt."
  (lambda (request)
    (when (equal (map-elt request :method) "session/new")
      (let ((params (map-elt request :params)))
        ;; nconc modifies the params list in place (appends to end),
        ;; which propagates back to the request since params shares structure
        (nconc params (list (cons '_meta
                                  `((systemPrompt . ((append . ,system-prompt)))))))))
    request))

;;; ACP-based notification routing

(defun agent-shell-team--setup-tool-call-watcher (buffer)
  "Subscribe to tool-call-update events on BUFFER for team routing."
  (agent-shell-subscribe-to
   :shell-buffer buffer
   :event 'tool-call-update
   :on-event #'agent-shell-team--on-tool-call-update))

(defun agent-shell-team--extract-request-id (message)
  "Extract request ID from MESSAGE if present.
Looks for pattern [Request ID: XXXXXXXX] in the text."
  (when (and message (string-match "\\[Request ID: \\([a-f0-9-]+\\)\\]" message))
    (match-string 1 message)))

(defun agent-shell-team--enrich-completion-message (session-id message)
  "If MESSAGE contains a request ID, append the report file path.
This helps the lead find and read the report."
  (let ((request-id (agent-shell-team--extract-request-id message)))
    (if request-id
        (let ((report-path (expand-file-name
                            (concat request-id ".md")
                            (agent-shell-team--reports-dir session-id))))
          (format "%s\n\nReport file: %s" message report-path))
      message)))

(defun agent-shell-team--on-tool-call-update (event)
  "Handle tool-call-update EVENT.
Route sendNotification calls between team agents."
  (let* ((data (map-elt event :data))
         (tool-call (alist-get :tool-call data))
         (tool-title (alist-get :title tool-call))
         (status (alist-get :status tool-call))
         (raw-input (alist-get :raw-input tool-call)))
    (when (and tool-title (equal status "completed") agent-shell-team--session-id)
      (cond
       ;; sendNotification — route between agents + track completion
       ((string-match-p "sendNotification" tool-title)
        (let* ((notif-title (or (map-elt raw-input 'title)
                                (map-elt raw-input "title")))
               (notif-message (or (map-elt raw-input 'message)
                                  (map-elt raw-input "message")))
               ;; For completion notifications, enrich with report path
               (enriched-message
                (if (member notif-title '("Task Complete" "Test Results" "Research Complete"))
                    (agent-shell-team--enrich-completion-message
                     agent-shell-team--session-id notif-message)
                  notif-message)))
          (when (and notif-title enriched-message)
            ;; Track group completion if this is a task completion
            (when (member notif-title '("Task Complete" "Test Results" "Research Complete"))
              (when-let ((request-id (agent-shell-team--extract-request-id notif-message)))
                (let ((sid (or (gethash request-id agent-shell-team--request-to-session)
                               agent-shell-team--session-id)))
                  ;; Persist legacy completion (skip knowledge tasks)
                  (when sid
                    (let ((role (plist-get (gethash request-id agent-shell-team--active-tasks) :role)))
                      (unless (equal role "knowledge")
                        (agent-shell-team--persist-task
                         sid
                         (list :request-id request-id
                               :status "finished"
                               :completed-at (float-time))))))
                  (agent-shell-team--handle-task-completion
                   request-id sid (current-buffer)))))
            (agent-shell-team--route-from-acp
             agent-shell-team--session-id
             agent-shell-team--role
             notif-title
             enriched-message))))))))

;;; Routing logic — infer target from sender role + notification title

(defun agent-shell-team--infer-target (from-role title)
  "Infer target role based on FROM-ROLE and notification TITLE."
  (pcase from-role
    ("dev"
     (pcase title
       ("Task Complete" "lead")
       ("Need Verification" "tester")
       (_ "lead")))
    ("tester"
     (pcase title
       ("Test Results" "lead")
       ("Log Report" "lead")
       ("Runtime Check" "lead")
       (_ "lead")))
    ("researcher"
     (pcase title
       (_ "lead")))
    ("knowledge"
     (pcase title
       (_ "lead")))
    ("lead"
     (pcase title
       ("Task Assignment" "dev")
       ("Run Tests" "tester")
       ("Research Request" "researcher")
       ("Status Update" "all")
       ("Need More Agents" "all")
       (_ "all")))))

(defun agent-shell-team--route-from-acp (session-id from-role notif-title notif-message)
  "Route a notification intercepted via ACP.
SESSION-ID identifies the team.
FROM-ROLE is the sender's role.
NOTIF-TITLE and NOTIF-MESSAGE are the notification content."
  (let ((target-role (agent-shell-team--infer-target from-role notif-title)))
    (agent-shell-team--route-notification
     session-id from-role target-role notif-title notif-message)))

(defun agent-shell-team--route-notification (session-id from-role target-role title message)
  "Route notification to the appropriate agent(s).
SESSION-ID identifies the team.
FROM-ROLE is the sender's role.
TARGET-ROLE is the inferred recipient (\"lead\", \"dev\", \"tester\", or \"all\").
TITLE and MESSAGE are the notification content."
  ;; For task assignments and test requests, inject a request ID and report path
  (let* ((needs-report (member title '("Task Assignment" "Run Tests" "Research Request")))
         (request-id (when needs-report (agent-shell-team--generate-request-id)))
         (reports-dir (when needs-report (agent-shell-team--reports-dir session-id)))
         (report-path (when request-id (expand-file-name (concat request-id ".md") reports-dir)))
         (enriched-message
          (if request-id
              (format "%s\n\n[Request ID: %s]\nWrite your detailed report to: %s\nReference this Request ID in your completion notification."
                      message request-id report-path)
            message)))
    ;; Log
    (agent-shell-team--log session-id
                           (format "[%s -> %s] %s: %s%s" from-role target-role title message
                                   (if request-id (format " (request: %s)" request-id) "")))
    ;; Find target agent(s)
    (let ((targets (if (equal target-role "all")
                       (agent-shell-team--get-session-agents session-id)
                     (agent-shell-team--get-agents-by-role session-id target-role))))
      ;; Deliver or queue per target
      (dolist (agent targets)
        (let* ((buf (alist-get 'buffer agent))
               (status (agent-shell-team--agent-status buf)))
          (pcase status
            ('idle
             (agent-shell-team--prompt-agent
              buf (format "Message from %s: %s -- %s" from-role title enriched-message)))
            ((or 'busy 'initializing)
             (agent-shell-team--queue-message
              session-id buf (list :from from-role :title title :message enriched-message)))
            ('dead
             (agent-shell-team--log session-id
                                    (format "WARNING: target %s buffer is dead, message dropped"
                                            target-role)))))))))

;;; Agent dismiss — cleanup after lead approves work

(defun agent-shell-team--pending-tasks-for-agent (session-id target)
  "Count pending tasks in queue targeted at the agent identified by TARGET.
Returns the count of matching tasks (0 if none)."
  (let ((matched-agent
         (cl-find-if
          (lambda (a)
            (let ((wt-name (alist-get 'worktree-name a))
                  (buf (alist-get 'buffer a)))
              (and (not (equal (alist-get 'role a) "lead"))
                   (or (and wt-name (string-match-p (regexp-quote target) wt-name))
                       (and (buffer-live-p buf)
                            (string-match-p (regexp-quote target) (buffer-name buf)))
                       (and (buffer-live-p buf)
                            (eq buf (gethash target agent-shell-team--request-to-buffer)))))))
          (agent-shell-team--get-session-agents session-id)))
        (count 0))
    (when matched-agent
      (let ((agent-buf (alist-get 'buffer matched-agent))
            (agent-wt (alist-get 'worktree-name matched-agent)))
        (dolist (task agent-shell-team--task-queue)
          (let ((task-target (plist-get task :target)))
            (when (and task-target
                       (or (and (buffer-live-p agent-buf)
                                (string-match-p (regexp-quote task-target) (buffer-name agent-buf)))
                           (and agent-wt
                                (string-match-p (regexp-quote task-target) agent-wt))))
              (cl-incf count))))))
    count))

(defun agent-shell-team--handle-dismiss-agent (raw-input)
  "Handle dismissAgent MCP tool call with RAW-INPUT.
Find the agent matching `target' and clean it up immediately.
Only the lead role may call this.  Returns an alist with success/message."
  (let* ((target (or (map-elt raw-input 'target)
                     (map-elt raw-input "target")))
         (session-id (or (map-elt raw-input 'session_id)
                         (map-elt raw-input "session_id")
                         agent-shell-team--session-id))
         (force (or (map-elt raw-input 'force)
                    (map-elt raw-input "force"))))
    (cond
     ;; Guard: need a session
     ((not session-id)
      `((success . nil)
        (message . "No session ID available")))
     ;; Guard: pending tasks in queue targeted at this agent
     ((and (not force)
           (> (agent-shell-team--pending-tasks-for-agent session-id target) 0))
      (let ((pending-count (agent-shell-team--pending-tasks-for-agent session-id target)))
        `((success . nil)
          (message . ,(format "Cannot dismiss: %d pending task(s) targeted at this agent. Cancel or reassign them first."
                              pending-count)))))
     ;; Find and dismiss the matching agent
     (t
      (let ((all-agents (agent-shell-team--get-session-agents session-id))
            (found nil))
        (dolist (agent all-agents)
          (let ((wt-name (alist-get 'worktree-name agent))
                (buf (alist-get 'buffer agent))
                (role (alist-get 'role agent)))
            ;; Never dismiss the lead or knowledge agents (singletons)
            (when (and (not (equal role "lead"))
                       (not (equal role "knowledge"))
                       (not found)
                       (or (and wt-name (string-match-p (regexp-quote target) wt-name))
                           (and (buffer-live-p buf)
                                (string-match-p (regexp-quote target) (buffer-name buf)))
                           (and (buffer-live-p buf)
                                (eq buf (gethash target agent-shell-team--request-to-buffer)))))
              (let ((status (agent-shell-team--agent-status buf)))
                (cond
                 ;; Refuse to dismiss reserved agents without force
                 ((and (eq status 'reserved) (not force))
                  (setq found 'refused-reserved)
                  (agent-shell-team--log session-id
                   (format "[dismissAgent] REFUSED: %s (%s) is reserved"
                           role (buffer-name buf))))
                 ;; Refuse to dismiss busy/initializing agents without force
                 ((and (memq status '(busy initializing))
                       (not force))
                  (let ((current-request-id nil))
                    (maphash (lambda (k v)
                               (when (eq v buf)
                                 (setq current-request-id k)))
                             agent-shell-team--request-to-buffer)
                    (setq found 'refused)
                    (agent-shell-team--log session-id
                     (format "[dismissAgent] REFUSED: %s (%s) is %s, request: %s"
                             role (buffer-name buf) status current-request-id))))
                 ;; OK to dismiss
                 (t
                  (setq found t)
                  (agent-shell-team--log session-id
                   (format "[dismissAgent] Cleaning up %s (%s)" role (buffer-name buf)))
                  (let ((b buf) (sid session-id) (wt (alist-get 'worktree agent)))
                    (run-at-time 0 nil
                                 (lambda ()
                                   (agent-shell-team--cleanup-agent b sid wt))))))))))
        (cond
         ((eq found 'refused-reserved)
          `((success . nil)
            (message . ,(format "Agent '%s' is reserved (has prior task context). Use `target` parameter to route related tasks to this agent. Use force:true to dismiss anyway."
                                target))))
         ((eq found 'refused)
          (let ((current-request-id nil)
                (status nil))
            ;; Re-find the agent to get status info for error message
            (dolist (agent all-agents)
              (let ((wt-name (alist-get 'worktree-name agent))
                    (buf (alist-get 'buffer agent)))
                (when (or (and wt-name (string-match-p (regexp-quote target) wt-name))
                          (and (buffer-live-p buf)
                               (string-match-p (regexp-quote target) (buffer-name buf))))
                  (setq status (agent-shell-team--agent-status buf))
                  (maphash (lambda (k v)
                             (when (eq v buf)
                               (setq current-request-id k)))
                           agent-shell-team--request-to-buffer))))
            `((success . nil)
              (message . ,(format "Cannot dismiss agent '%s': status is %s (request: %s). Use force: true to override."
                                  target status (or current-request-id "unknown"))))))
         ((eq found t)
          `((success . t)
            (message . ,(format "Agent matching '%s' dismissed" target))))
         (t
          (let* ((stale-buf (gethash target agent-shell-team--request-to-buffer))
                 (prev-session (gethash target agent-shell-team--request-to-session))
                 (lead-match
                  (cl-some (lambda (agent)
                             (let ((wt-name (alist-get 'worktree-name agent))
                                   (buf (alist-get 'buffer agent))
                                   (role (alist-get 'role agent)))
                               (when (and (equal role "lead")
                                          (or (and wt-name (string-match-p (regexp-quote target) wt-name))
                                              (and (buffer-live-p buf)
                                                   (string-match-p (regexp-quote target) (buffer-name buf)))))
                                 t)))
                           all-agents))
                 (knowledge-match
                  (cl-some (lambda (agent)
                             (let ((wt-name (alist-get 'worktree-name agent))
                                   (buf (alist-get 'buffer agent))
                                   (role (alist-get 'role agent)))
                               (when (and (equal role "knowledge")
                                          (or (and wt-name (string-match-p (regexp-quote target) wt-name))
                                              (and (buffer-live-p buf)
                                                   (string-match-p (regexp-quote target) (buffer-name buf)))))
                                 t)))
                           all-agents))
                 (active-names
                  (cl-loop for agent in all-agents
                           for role = (alist-get 'role agent)
                           for wt-name = (alist-get 'worktree-name agent)
                           for buf = (alist-get 'buffer agent)
                           unless (equal role "lead")
                           collect (or wt-name
                                       (and (buffer-live-p buf) (buffer-name buf))
                                       "<unknown>")))
                 (agents-str (if active-names
                                 (format " Active non-lead agents: [%s]"
                                         (string-join active-names ", "))
                               " No active non-lead agents."))
                 (reason
                  (cond
                   ((and stale-buf (not (buffer-live-p stale-buf)))
                    "The agent for this request-id has been killed (stale mapping).")
                   ((and prev-session (not stale-buf))
                    "This request-id was previously assigned, but the agent was dismissed or reassigned.")
                   (lead-match
                    "Target matches the lead agent, which cannot be dismissed.")
                   (knowledge-match
                    "Target matches the knowledge agent, which is a singleton and cannot be dismissed.")
                   (t nil))))
            `((success . nil)
              (message . ,(format "No agent found matching '%s'. %s%s"
                                  target
                                  (or reason "No specific reason identified.")
                                  agents-str)))))))))))

;;; Devcontainer lifecycle

(defun agent-shell-team--stop-devcontainer (role worktree-path)
  "Stop the devcontainer for ROLE at WORKTREE-PATH if one is configured."
  (let ((config-path (expand-file-name
                       (format ".devcontainer/%s/devcontainer.json" role)
                       worktree-path)))
    (when (file-exists-p config-path)
      (message "[devcontainer] Stopping container for %s at %s..." role worktree-path)
      (call-process "devcontainer" nil nil nil
                    "down" "--workspace-folder" worktree-path
                    "--config" config-path)
      (message "[devcontainer] Container stopped for %s" role))))

(defun agent-shell-team--cleanup-agent (buffer session-id worktree-path)
  "Clean up BUFFER: unregister from session, kill buffer, optionally remove worktree."
  (let ((agent-role (and (buffer-live-p buffer)
                         (buffer-local-value 'agent-shell-team--role buffer)))
        (agent-wt-name (and (buffer-live-p buffer)
                            (buffer-local-value 'agent-shell-team--worktree-name buffer))))
  (agent-shell-team--log session-id
   (format "[cleanup] Killing agent buffer %s%s"
           (if (buffer-live-p buffer) (buffer-name buffer) "(already dead)")
           (if worktree-path (format ", removing worktree %s" worktree-path) "")))
  ;; Broadcast dismiss to namespace peers (before cleanup removes registry entry)
  (when (fboundp 'agent-shell-namespace-emit-dismiss)
    (agent-shell-namespace-emit-dismiss
     (agent-shell-team--buffer-worktree-name buffer)))
  ;; Strip :target from queued tasks that targeted this agent (before mappings are removed)
  (let ((buf-name (and (buffer-live-p buffer) (buffer-name buffer)))
        (wt-name (agent-shell-team--buffer-worktree-name buffer))
        (agent-request-ids (let (ids)
                             (maphash (lambda (k v)
                                        (when (eq v buffer) (push k ids)))
                                      agent-shell-team--request-to-buffer)
                             ids)))
    (dolist (task agent-shell-team--task-queue)
      (when-let ((target (plist-get task :target)))
        (when (or (and buf-name (string-match-p (regexp-quote target) buf-name))
                  (and buf-name (string-match-p (regexp-quote buf-name) target))
                  (and wt-name (not (equal wt-name "main"))
                       (or (string-match-p (regexp-quote target) wt-name)
                           (string-match-p (regexp-quote wt-name) target)))
                  (member target agent-request-ids))
          (agent-shell-team--log session-id
           (format "[cleanup] Clearing target %S from queued task %s (agent dismissed)"
                   target (plist-get task :request-id)))
          (plist-put task :target nil)))))
  ;; Clean up request-to-buffer and request-to-session mappings for this agent
  (let ((removed-request-ids nil))
    (maphash (lambda (k v)
               (when (eq v buffer)
                 (push k removed-request-ids)
                 (remhash k agent-shell-team--request-to-buffer)
                 (remhash k agent-shell-team--request-to-session)
                 (remhash k agent-shell-team--active-tasks)))
             (copy-hash-table agent-shell-team--request-to-buffer))
    ;; Clean up group tracking for removed request-ids
    (dolist (rid removed-request-ids)
      (when-let ((group-id (gethash rid agent-shell-team--request-to-group)))
        (let ((group (gethash group-id agent-shell-team--task-groups)))
          (when group
            (plist-put group :pending (delete rid (plist-get group :pending)))
            (agent-shell-team--log session-id
             (format "[cleanup] Removed request %s from group %s, %d pending"
                     rid group-id (length (plist-get group :pending))))
            (when (null (plist-get group :pending))
              (agent-shell-team--notify-group-complete session-id group-id group)
              (dolist (completed-rid (plist-get group :completed))
                (remhash completed-rid agent-shell-team--request-to-group))
              (remhash group-id agent-shell-team--task-groups))))
        (remhash rid agent-shell-team--request-to-group))))
  (remhash buffer agent-shell-team--last-activity)
  (remhash buffer agent-shell-team--last-compact-time)
  (when (buffer-live-p buffer)
    (agent-shell-team--mark-agent-idle (buffer-name buffer))
    (agent-shell-team--unregister-agent buffer)
    (with-current-buffer buffer
      (setq agent-shell-team--cleanup-in-progress t))
    (kill-buffer buffer))
  ;; Stop devcontainer before worktree removal (container bind-mounts the worktree)
  (when (and agent-role worktree-path)
    (agent-shell-team--stop-devcontainer agent-role worktree-path))
  ;; Remove worktree if it exists
  (when (and worktree-path (file-directory-p worktree-path))
    (let ((default-directory (file-name-parent-directory worktree-path)))
      (shell-command-to-string
       (format "git worktree remove --force %s 2>&1"
               (shell-quote-argument worktree-path)))
      ;; Verify removal — fallback to delete-directory + prune if git failed
      (when (file-directory-p worktree-path)
        (agent-shell-team--log session-id
         (format "[cleanup] WARNING: git worktree remove failed for %s, falling back to delete-directory"
                 worktree-path))
        (delete-directory worktree-path t)
        (shell-command-to-string "git worktree prune 2>&1")))))) ;; close outer let + defun

;;; Task queue — enqueue, assign, group tracking

(defun agent-shell-team--handle-tasks-put (raw-input)
  "Process a tasksPut tool call with RAW-INPUT.
Extract tasks, generate IDs, register groups, and enqueue for assignment.
Return the number of tasks actually enqueued, or signal an error if
`agent-shell-team--session-id' is nil."
  (let ((session-id agent-shell-team--session-id))
    (unless session-id
      (error "Team session not initialized (session-id is nil)"))
    (let ((tasks (or (map-elt raw-input 'tasks)
                     (map-elt raw-input "tasks")))
          (enqueued 0)
          (skipped 0))
      (when tasks
        (dolist (task (append tasks nil))  ;; convert vector to list
          (let* ((role (or (map-elt task 'role) (map-elt task "role")))
                 (message (or (map-elt task 'message) (map-elt task "message")))
                 (group-id (or (map-elt task 'group_id) (map-elt task "group_id")))
                 (target (or (map-elt task 'target) (map-elt task "target")))
                 (priority (or (map-elt task 'priority) (map-elt task "priority")))
                 (caller-request-id (or (map-elt task 'request_id) (map-elt task "request_id")))
                 (request-id (or caller-request-id
                                 (agent-shell-team--generate-request-id)))
                 ;; Content-based dedup: check queued and in-flight tasks
                 (content-dup-queued
                  (cl-find-if (lambda (e)
                                (and (equal (plist-get e :role) role)
                                     (equal (plist-get e :message) message)))
                              agent-shell-team--task-queue))
                 (content-dup-active
                  (let ((found nil))
                    (maphash (lambda (_k v)
                               (when (and (equal (plist-get v :role) role)
                                          (equal (plist-get v :message) message))
                                 (setq found v)))
                             agent-shell-team--active-tasks)
                    found)))
            (cond
             ;; 1. Request-id dedup (existing)
             ((and caller-request-id
                   (or (gethash caller-request-id agent-shell-team--request-to-buffer)
                       (cl-find caller-request-id agent-shell-team--task-queue
                                :key (lambda (e) (plist-get e :request-id))
                                :test #'string=)))
              (agent-shell-team--log session-id
                                     (format "[tasksPut] Skipping duplicate request-id: %s"
                                             caller-request-id))
              (cl-incf skipped))
             ;; 2. Content-based dedup (new)
             ((or content-dup-queued content-dup-active)
              (agent-shell-team--log session-id
                                     (format "[tasksPut] Skipping content-duplicate: role=%s msg-prefix=%.60s"
                                             role (or message "")))
              (cl-incf skipped))
             ;; 3. Normal enqueue
             (t
              (let* ((reports-dir (agent-shell-team--reports-dir session-id))
                     (report-path (unless (equal role "knowledge")
                                    (expand-file-name (concat request-id ".md") reports-dir)))
                     (entry (list :role role
                                  :message message
                                  :request-id request-id
                                  :group-id group-id
                                  :target target
                                  :priority priority
                                  :session-id session-id
                                  :report-path report-path)))
                ;; Persist to disk (skip for knowledge — they're long-lived and silent)
                (plist-put entry :created-at (float-time))
                (unless (equal role "knowledge")
                  (agent-shell-team--persist-task
                   session-id
                   (list :request-id request-id
                         :role role
                         :message (truncate-string-to-width (or message "") 200 nil nil "...")
                         :group-id group-id
                         :target target
                         :session-id session-id
                         :status "queued"
                         :created-at (plist-get entry :created-at))))
                ;; Register in group tracker if group_id is present
                (when group-id
                  (let ((group (or (gethash group-id agent-shell-team--task-groups)
                                   (list :pending nil :completed nil :session-id session-id))))
                    (plist-put group :pending (cons request-id (plist-get group :pending)))
                    (puthash group-id group agent-shell-team--task-groups))
                  (puthash request-id group-id agent-shell-team--request-to-group))
                ;; Track request → session for taskUpdate resolution
                (puthash request-id session-id agent-shell-team--request-to-session)
                ;; Append to FIFO queue
                (setq agent-shell-team--task-queue
                      (append agent-shell-team--task-queue (list entry)))
                (cl-incf enqueued)
                (agent-shell-team--log session-id
                                       (format "[tasksPut] Queued %s task: %s (request: %s%s)"
                                               role
                                               (truncate-string-to-width message 60 nil nil "...")
                                               request-id
                                               (if group-id (format ", group: %s" group-id) "")))))))))
      ;; Defer assignment out of websocket process filter so that
      ;; agent spawning, shell-maker-submit, and D-Bus calls don't
      ;; block Emacs while the filter is running.
      (let ((sid session-id))
        (run-at-time 0 nil
                     (lambda ()
                       (condition-case err
                           (agent-shell-team--try-assign-tasks)
                         (error
                          (agent-shell-team--log sid
                           (format "[tasksPut] Error in try-assign-tasks (tasks are queued, will retry): %s"
                                   (error-message-string err)))))
                       (condition-case nil
                           (agent-shell-team--start-drain-timer)
                         (error nil)))))
      enqueued)))

(defun agent-shell-team--handle-task-update (raw-input)
  "Process a taskUpdate tool call with RAW-INPUT.
Route the status update directly to the lead agent's queue."
  (let* ((request-id (or (map-elt raw-input 'request_id)
                         (map-elt raw-input "request_id")))
         (status (or (map-elt raw-input 'status)
                     (map-elt raw-input "status")))
         (content (or (map-elt raw-input 'content)
                      (map-elt raw-input "content")))
         (commit (or (map-elt raw-input 'commit)
                     (map-elt raw-input "commit")))
         (report-path (or (map-elt raw-input 'report_path)
                          (map-elt raw-input "report_path")))
         (session-id (or (gethash request-id agent-shell-team--request-to-session)
                        (map-elt raw-input 'session_id)
                        (map-elt raw-input "session_id")
                        (agent-shell-team--find-session-for-request request-id)
                        agent-shell-team--session-id))
         (lead-buf (when session-id
                     (agent-shell-team--get-lead session-id))))
    ;; Build the message text regardless of whether lead-buf exists
    (let* ((agent-buf (gethash request-id agent-shell-team--request-to-buffer))
           (agent-wt (when agent-buf
                       (cl-loop for agent in (agent-shell-team--get-session-agents session-id)
                                when (eq (alist-get 'buffer agent) agent-buf)
                                return (alist-get 'worktree-name agent))))
           (agent-role (when (and agent-buf (buffer-live-p agent-buf))
                         (buffer-local-value 'agent-shell-team--role agent-buf)))
           (agent-branch
            (ignore-errors
              (when (and agent-buf (buffer-live-p agent-buf))
                (let ((wt-path (buffer-local-value 'agent-shell-team--worktree-path agent-buf)))
                  (when (and wt-path (file-directory-p wt-path))
                    (let ((branch (string-trim
                                   (shell-command-to-string
                                    (format "git -C %s branch --show-current"
                                            (shell-quote-argument wt-path))))))
                      (unless (string-empty-p branch) branch)))))))
           (message-text (format "Task Update [%s] — %s\nRequest ID: %s%s%s%s%s%s\n\n%s"
                                 status
                                 request-id
                                 request-id
                                 (if commit (format "\nCommit: %s" commit) "")
                                 (if agent-branch (format "\nBranch: %s" agent-branch) "")
                                 (if report-path (format "\nReport: %s" report-path) "")
                                 (if agent-wt (format "\nAgent: %s" agent-wt) "")
                                 (if agent-role (format "\nRole: %s" agent-role) "")
                                 content))
           ;; Check report for Knowledge Discoveries on finished tasks
           (message-text
            (if (and (equal status "finished")
                     report-path
                     (file-readable-p report-path))
                (let ((has-discoveries
                       (with-temp-buffer
                         (insert-file-contents report-path)
                         (goto-char (point-min))
                         (when (re-search-forward "^## Knowledge Discoveries" nil t)
                           (let ((section-start (match-end 0)))
                             (goto-char section-start)
                             (let ((section-end (if (re-search-forward "^## " nil t)
                                                    (match-beginning 0)
                                                  (point-max))))
                               (let ((text (string-trim (buffer-substring-no-properties
                                                         section-start section-end))))
                                 (and (not (string-empty-p text))
                                      (not (string-match-p "\\`\\(?:none\\|n/a\\)\\'" (downcase text)))))))))))
                  (if has-discoveries
                      (let* ((role (when (and agent-buf (buffer-live-p agent-buf))
                                     (buffer-local-value 'agent-shell-team--role agent-buf)))
                             (knowledge-path (when role
                                               (agent-shell-team--knowledge-file role))))
                        (concat (format "⚠️ This report contains Knowledge Discoveries. Update the knowledge file at %s before proceeding.\n\n"
                                        (or knowledge-path "the relevant role knowledge file"))
                                message-text))
                    message-text))
              message-text)))
      ;; Log it (fast, no UI)
      (agent-shell-team--log (or session-id "<nil>")
                             (format "[taskUpdate] %s from request %s"
                                     status request-id))
      ;; Defer all side effects (notify, deliver, persist, group completion)
      ;; out of the websocket process filter to avoid blocking Emacs.
      (let* ((msg message-text)
             (sid session-id)
             (lbuf lead-buf)
             (rid request-id)
             (st status)
             (cmt commit)
             (knowledge-p (or (string-prefix-p "kb-auto-" rid)
                              (equal "knowledge"
                                     (plist-get (gethash rid agent-shell-team--active-tasks) :role)))))
        (run-at-time 0 nil
                     (lambda ()
                       (unless knowledge-p
                         ;; Desktop notification for task lifecycle events
                         (when (member st '("finished" "blocked"))
                           (agent-shell-team--notify
                            (format "Task %s" (capitalize st))
                            (format "%s" rid)))
                         (if lbuf
                             ;; Deliver or queue to lead
                             (let ((lead-status (agent-shell-team--agent-status lbuf)))
                               (pcase lead-status
                                 ('idle (agent-shell-team--prompt-agent lbuf msg))
                                 ((or 'busy 'initializing)
                                  (agent-shell-team--queue-message sid lbuf
                                                                   (list :from "agent" :title "Task Update" :message msg)))
                                 ('dead (agent-shell-team--log sid "WARNING: lead buffer is dead"))))
                           ;; No lead yet — queue for later delivery
                           (when sid
                             (agent-shell-team--log sid "taskUpdate queued pending lead registration")
                             (let ((existing (gethash sid agent-shell-team--pending-for-lead)))
                               (puthash sid (append existing (list msg))
                                        agent-shell-team--pending-for-lead))
                             (agent-shell-team--start-drain-timer))))
                       ;; Persist task status update (skip knowledge tasks)
                       (when sid
                         (let ((role (plist-get (gethash rid agent-shell-team--active-tasks) :role)))
                           (unless (equal role "knowledge")
                             (agent-shell-team--persist-task
                              sid
                              (list :request-id rid
                                    :status st
                                    :commit cmt
                                    :completed-at (float-time))))))
                       ;; Clean up tracking tables and handle group completion when finished.
                       ;; NOTE: We only remove from active-tasks here. The request-to-buffer
                       ;; and request-to-session mappings are kept so that dismissAgent can
                       ;; still find agents by request-id after task completion. Those entries
                       ;; are cleaned up by cleanup-agent when the agent is actually dismissed,
                       ;; and by assign-task-to-agent which proactively clears stale entries.
                       (when (equal st "finished")
                         (remhash rid agent-shell-team--active-tasks)
                         (when-let ((group-id (gethash rid agent-shell-team--request-to-group)))
                           (agent-shell-team--handle-task-completion rid sid nil))))))
      t)))

(defun agent-shell-team--find-idle-agent (session-id role)
  "Find an idle agent in SESSION-ID matching ROLE."
  (cl-find-if
   (lambda (a)
     (and (equal (alist-get 'role a) role)
          (eq (agent-shell-team--agent-status (alist-get 'buffer a)) 'idle)))
   (agent-shell-team--get-session-agents session-id)))

(defun agent-shell-team--auto-spawn-agent (session-id role)
  "Auto-spawn a new agent for ROLE in SESSION-ID.
Devs and testers get isolated mode (worktree).
Researchers get neighbor mode.
Returns the new agent buffer."
  ;; Pin default-directory to the main repo root so git commands in
  ;; create-worktree always run from the correct context, not from
  ;; an agent's worktree CWD.
  (message "[auto-spawn] Starting for role=%s session=%s" role session-id)
  (let* ((default-directory (or (agent-shell-worktree--git-repo-root)
                                default-directory))
         (mode (if (member role '("dev" "tester")) "isolated" "neighbor"))
         worktree-path worktree-name directory)
    (message "[auto-spawn] Mode for role=%s: %s (default-directory=%s)" role mode default-directory)
    (pcase mode
      ("isolated"
       (message "[auto-spawn] Creating worktree for role=%s..." role)
       (let ((wt (agent-shell-team--create-worktree session-id role)))
         (message "[auto-spawn] Worktree created: path=%s name=%s" (car wt) (cdr wt))
         (setq worktree-path (car wt)
               worktree-name (cdr wt)
               directory worktree-path)))
      ("neighbor"
       (message "[auto-spawn] Neighbor mode, using directory=%s" default-directory)
       (setq directory default-directory)))
    (message "[auto-spawn] Calling start-agent for role=%s mode=%s dir=%s" role mode directory)
    (let ((buffer (agent-shell-team--start-agent
                   session-id role mode directory worktree-path worktree-name
                   :no-focus t)))
      (with-current-buffer buffer
        (unless (equal role "knowledge")
          (setq agent-shell-team--ephemeral t)))
      (agent-shell-team--start-drain-timer)
      (agent-shell-team--log session-id
       (format "Auto-spawned %s agent (%s mode%s) buffer=%s"
               role mode
               (if worktree-name (format ", worktree: %s" worktree-name) "")
               (buffer-name buffer)))
      buffer)))

(defun agent-shell-team--try-assign-tasks ()
  "Try to assign queued tasks to idle agents.
When no idle agent exists for a non-lead role and the role hasn't
reached its max agent count, auto-spawn a new agent."
  (if agent-shell-team--assigning-p
      (message "[try-assign] BLOCKED: assigning-p is t, skipping")
    (unwind-protect
        (progn
          (setq agent-shell-team--assigning-p t)
          (message "[try-assign] Starting. Queue length: %d" (length agent-shell-team--task-queue))
          (let ((remaining nil)
                (just-assigned (make-hash-table :test 'eq)))
            (dolist (task agent-shell-team--task-queue)
              ;; Fix: skip tasks already assigned (defense against re-queue leaks)
              (if (gethash (plist-get task :request-id) agent-shell-team--active-tasks)
                  (progn
                    (message "[try-assign] Task %s already active, dropping"
                             (plist-get task :request-id))
                    nil) ;; already assigned — drop from queue silently
                ;; Fix: isolate per-task errors so the loop always completes
                (condition-case err
                    (let* ((role (plist-get task :role))
                           (session-id (plist-get task :session-id))
                           (target (plist-get task :target))
                           (_ (message "[try-assign] Processing task %s: role=%s target=%s session=%s"
                                       (plist-get task :request-id) role target session-id))
                           (targeted-agent
                            (when target
                              (cl-find-if
                               (lambda (a)
                                 (let ((buf (alist-get 'buffer a)))
                                   (and (buffer-live-p buf)
                                        (or (string-match-p (regexp-quote target) (buffer-name buf))
                                            (let ((wt (alist-get 'worktree-name a)))
                                              (and wt (string-match-p (regexp-quote target) wt)))
                                            (eq buf (gethash target agent-shell-team--request-to-buffer))))))
                               (agent-shell-team--get-agents-by-role session-id role)))))
                      (cond
                       ;; Targeted assignment: agent found and idle/reserved — assign directly
                       ((and targeted-agent
                             (memq (agent-shell-team--agent-status (alist-get 'buffer targeted-agent)) '(idle reserved))
                             (not (gethash (alist-get 'buffer targeted-agent) just-assigned)))
                        (agent-shell-team--assign-task-to-agent targeted-agent task)
                        (puthash (alist-get 'buffer targeted-agent) t just-assigned))
                       ;; Targeted assignment: agent found but busy (or just-assigned)
                       ((and targeted-agent
                             (or (memq (agent-shell-team--agent-status (alist-get 'buffer targeted-agent))
                                       '(busy initializing))
                                 (gethash (alist-get 'buffer targeted-agent) just-assigned)))
                        (if (equal (plist-get task :priority) "interrupt")
                            ;; Interrupt priority: queue for immediate delivery when agent goes idle
                            (let* ((buf (alist-get 'buffer targeted-agent))
                                   (existing (assq buf agent-shell-team--interrupt-queue)))
                              (if existing
                                  (setcdr existing (append (cdr existing) (list task)))
                                (push (cons buf (list task)) agent-shell-team--interrupt-queue))
                              (agent-shell-team--log session-id
                               (format "[assign] Interrupt task %s queued for %s (agent busy)"
                                       (plist-get task :request-id) (buffer-name buf)))
                              ;; Notify lead that interrupt is queued
                              (when-let ((lead-buf (agent-shell-team--get-lead session-id)))
                                (agent-shell-team--queue-message
                                 session-id lead-buf
                                 (list :from "system" :title "Interrupt Queued"
                                       :message (format "[request-id: %s] queued for immediate delivery when agent finishes current turn"
                                                        (plist-get task :request-id))))))
                          ;; Normal priority: re-queue as before
                          (push task remaining)))
                       ;; Targeted assignment: agent gone — clear target for reassignment
                       (target
                        (agent-shell-team--log session-id
                         (format "[assign] Targeted agent %S gone for role %s, clearing target for reassignment" target role))
                        (plist-put task :target nil)
                        (push task remaining))
                       ;; Normal assignment: find any idle agent for this role
                       (t
                        (let* ((all-agents (agent-shell-team--get-session-agents session-id))
                               (_ (message "[try-assign] All session agents: %s"
                                           (mapcar (lambda (a)
                                                     (list (buffer-name (alist-get 'buffer a))
                                                           (alist-get 'role a)
                                                           (agent-shell-team--agent-status (alist-get 'buffer a))))
                                                   all-agents)))
                               (idle-agent
                                (cl-find-if
                                 (lambda (a)
                                   (let ((buf (alist-get 'buffer a)))
                                     (and (equal (alist-get 'role a) role)
                                          (eq (agent-shell-team--agent-status buf) 'idle)
                                          (not (gethash buf just-assigned)))))
                                 all-agents)))
                          (if idle-agent
                              (progn
                                (message "[try-assign] Found idle agent for role=%s: %s"
                                         role (buffer-name (alist-get 'buffer idle-agent)))
                                (agent-shell-team--assign-task-to-agent idle-agent task)
                                (puthash (alist-get 'buffer idle-agent) t just-assigned))
                            ;; No idle agent — try auto-spawning if allowed
                            (let ((role-agents (agent-shell-team--get-agents-by-role session-id role)))
                              (message "[try-assign] No idle agent for role=%s. Role agents count=%d: %s"
                                       role (length role-agents)
                                       (mapcar (lambda (a)
                                                 (let ((buf (alist-get 'buffer a)))
                                                   (list (buffer-name buf)
                                                         (agent-shell-team--agent-status buf)
                                                         (format "ephemeral=%s" (buffer-local-value 'agent-shell-team--ephemeral buf)))))
                                               role-agents))
                              (let ((is-not-lead (not (equal role "lead")))
                                    (under-max (< (length role-agents) agent-shell-team-max-agents-per-role))
                                    (has-initializing
                                     (cl-some
                                      (lambda (a)
                                        (and (buffer-local-value 'agent-shell-team--ephemeral
                                                                (alist-get 'buffer a))
                                             (memq (agent-shell-team--agent-status
                                                    (alist-get 'buffer a))
                                                   '(initializing))))
                                      role-agents))
                                    ;; For knowledge role: singleton — never spawn if ANY knowledge agent exists
                                    (is-not-singleton (not (and (equal role "knowledge")
                                                                (cl-some (lambda (a)
                                                                           (equal (alist-get 'role a) "knowledge"))
                                                                         all-agents)))))
                                (message "[try-assign] Spawn decision: not-lead=%s under-max=%s(max=%d) no-initializing=%s singleton-ok=%s"
                                         is-not-lead under-max agent-shell-team-max-agents-per-role (not has-initializing) is-not-singleton)
                                (if (and is-not-lead under-max (not has-initializing) is-not-singleton)
                                    (progn
                                      (agent-shell-team--log session-id
                                       (format "[auto-spawn] No idle %s agent, spawning new one" role))
                                      (message "[try-assign] >>> SPAWNING new %s agent" role)
                                      (agent-shell-team--auto-spawn-agent session-id role)
                                      ;; Push task back — new agent is still initializing,
                                      ;; it will be assigned on the next drain timer tick
                                      (push task remaining))
                                  (message "[try-assign] Cannot spawn role=%s, re-queuing task %s"
                                           role (plist-get task :request-id))
                                  (push task remaining)))))))))
                  (error
                   (agent-shell-team--log (plist-get task :session-id)
                    (format "[assign] Error processing task %s: %s, re-queuing"
                            (plist-get task :request-id) (error-message-string err)))
                   (push task remaining)))))
            (setq agent-shell-team--task-queue (nreverse remaining))))
      (setq agent-shell-team--assigning-p nil))))

(defun agent-shell-team--assign-task-to-agent (agent task)
  "Assign TASK to AGENT by delivering enriched message."
  (let* ((buf (alist-get 'buffer agent))
         (request-id (plist-get task :request-id))
         (report-path (plist-get task :report-path))
         (session-id (plist-get task :session-id))
         (role (plist-get task :role))
         (message (plist-get task :message))
         (enriched (if report-path
                      (format "%s\n\n[Request ID: %s]\nWrite your detailed report to: %s\nReference this Request ID in your completion notification."
                              message request-id report-path)
                    (format "%s\n\n[Request ID: %s]\nReference this Request ID in your completion notification."
                            message request-id)))
         (enriched (if (buffer-local-value 'agent-shell-team--reserved-p buf)
                       (concat enriched "\n\n[Reserved Agent] You are a reserved agent. After completing this task, do NOT look for more work. Simply report completion and wait.")
                     enriched)))
    (agent-shell-team--log session-id
                           (format "[assign] %s -> %s (request: %s)"
                                   (plist-get task :role)
                                   (buffer-name buf)
                                   request-id))
    ;; Remove stale request-id mappings for this buffer before adding the new one
    (maphash (lambda (k v)
               (when (eq v buf)
                 (remhash k agent-shell-team--request-to-buffer)
                 (remhash k agent-shell-team--request-to-session)
                 (remhash k agent-shell-team--active-tasks)))
             (copy-hash-table agent-shell-team--request-to-buffer))
    (puthash request-id buf agent-shell-team--request-to-buffer)
    (puthash request-id task agent-shell-team--active-tasks)
    ;; Persist assignment (skip for knowledge — not shown in sidebar)
    (unless (equal role "knowledge")
      (let ((wt-name (alist-get 'worktree-name agent)))
        (agent-shell-team--persist-task
         session-id
         (list :request-id request-id
               :status "assigned"
               :agent-worktree wt-name
               :assigned-at (float-time)))))
    (agent-shell-team--prompt-agent
     buf (format "Task Assignment -- %s" enriched))
    ;; Notify the lead about the assignment (skip knowledge housekeeping)
    (unless (equal role "knowledge")
      (when-let ((lead-buf (agent-shell-team--get-lead session-id)))
        (agent-shell-team--queue-message
         session-id lead-buf
         (list :from "system"
               :title "Task Assigned"
               :message (format "[request-id: %s]\nAgent: %s\nRole: %s"
                                request-id
                                (or (alist-get 'worktree-name agent)
                                   (buffer-name (alist-get 'buffer agent)))
                                role)))))))

(defun agent-shell-team--handle-task-completion (request-id session-id from-buffer)
  "Mark REQUEST-ID as complete.  If its group is fully done, notify lead.
SESSION-ID identifies the team.  FROM-BUFFER is the completing agent."
  (when-let ((group-id (gethash request-id agent-shell-team--request-to-group)))
    (let ((group (gethash group-id agent-shell-team--task-groups)))
      (when group
        (plist-put group :completed (cons request-id (plist-get group :completed)))
        (plist-put group :pending (delete request-id (plist-get group :pending)))
        (agent-shell-team--log session-id
                               (format "[group %s] %s complete, %d pending"
                                       group-id request-id
                                       (length (plist-get group :pending))))
        (when (null (plist-get group :pending))
          ;; ALL tasks in group complete — notify lead
          (agent-shell-team--notify-group-complete session-id group-id group)
          ;; Cleanup tracking
          (dolist (rid (plist-get group :completed))
            (remhash rid agent-shell-team--request-to-group))
          (remhash group-id agent-shell-team--task-groups))))))

(defun agent-shell-team--notify-group-complete (session-id group-id group)
  "Notify the lead that all tasks in GROUP-ID are done.
SESSION-ID identifies the team.  GROUP contains the completed request IDs."
  (let* ((completed (plist-get group :completed))
         (reports-dir (agent-shell-team--reports-dir session-id))
         (report-lines (mapcar (lambda (rid)
                                 (format "- %s: %s"
                                         rid
                                         (expand-file-name (concat rid ".md") reports-dir)))
                               completed))
         (lead-buf (agent-shell-team--get-lead session-id)))
    (when lead-buf
      (let ((message (format "All %d tasks in group `%s` are complete.\n\nReports:\n%s"
                             (length completed) group-id
                             (string-join report-lines "\n"))))
        (agent-shell-team--log session-id
                               (format "[group %s] ALL COMPLETE, notifying lead" group-id))
        (agent-shell-team--notify
         "Group Complete"
         (format "All %d tasks in group `%s` done" (length completed) group-id))
        (if (eq (agent-shell-team--agent-status lead-buf) 'idle)
            (agent-shell-team--prompt-agent
             lead-buf (format "Group Complete -- %s" message))
          (agent-shell-team--queue-message
           session-id lead-buf
           (list :from "system" :title "Group Complete" :message message)))))))

;;; Message delivery

(defun agent-shell-team--user-has-pending-input-p (buffer)
  "Return non-nil if BUFFER has user-typed text at the prompt."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((proc (get-buffer-process buffer))
             (busy shell-maker--busy)
             (pm (and proc (marker-position (process-mark proc))))
             (pmax (point-max))
             (text (when (and pm (> pmax pm))
                     (string-trim (buffer-substring-no-properties pm pmax))))
             (result (and proc (not busy) pm (> pmax pm)
                         text (not (string-empty-p text)))))
        (message "pending-input-check: proc=%s busy=%s pm=%s pmax=%s text-len=%s result=%s"
                 (not (null proc)) busy pm pmax (and text (length text)) result)
        result))))

(defun agent-shell-team--prompt-agent (buffer message)
  "Deliver MESSAGE to BUFFER's agent via shell-maker-submit.
This goes through shell-maker's normal prompt flow so that:
- The message appears in the shell buffer
- shell-maker--busy is set correctly
- ACP notifications render in-buffer instead of as stale minibuffer messages.
If the user has uncommitted text at the prompt, defer delivery by re-queuing."
  (when (buffer-live-p buffer)
    (let ((has-input (agent-shell-team--user-has-pending-input-p buffer)))
      (message "prompt-guard: buffer=%s has-pending-input=%s" (buffer-name buffer) has-input)
      (if has-input
          (progn
            (message "prompt-guard: DEFERRING message to %s" (buffer-name buffer))
            (agent-shell-team--queue-message
             nil buffer
             (list :from "system" :title "Deferred" :message message))
            (agent-shell-team--start-drain-timer))
        (message "prompt-guard: DELIVERING to %s" (buffer-name buffer))
        (with-current-buffer buffer
          (shell-maker-submit :input (format "«TEAM»\n%s\n«/TEAM»" message)))))))

(defun agent-shell-team--prompt-agent-silent (buffer message)
  "Deliver MESSAGE to BUFFER's agent via raw ACP request.
The message is processed by the LLM but does not appear in the shell buffer.
Use for background context like team roster updates and announcements."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (boundp 'agent-shell--state)
                 agent-shell--state)
        (let ((session-id (map-nested-elt agent-shell--state '(:session :id)))
              (client (map-elt agent-shell--state :client)))
          (when (and session-id client)
            (let ((content-blocks (list `((type . "text") (text . ,message)))))
              (acp-send-request
               :client client
               :request (acp-make-session-prompt-request
                         :session-id session-id
                         :prompt content-blocks)
               :buffer buffer
               :on-success (lambda (_acp-response)
                             (message "[agent-shell-team] silent prompt delivered to %s" buffer))
               :on-failure (lambda (acp-error &optional _raw-message)
                             (message "[agent-shell-team] silent prompt failed for %s: %s"
                                      buffer acp-error))))))))))

;;; Message queue & drain

(defun agent-shell-team--queue-message (_session-id buffer msg)
  "Queue MSG for BUFFER for later delivery.
_SESSION-ID is unused but kept for consistency."
  (let ((existing (gethash buffer agent-shell-team--message-queue)))
    (puthash buffer (append existing (list msg)) agent-shell-team--message-queue)
    (agent-shell-team--start-drain-timer)))

(defun agent-shell-team--drain-queue (buffer)
  "Deliver any queued messages to BUFFER now that agent is idle."
  (when-let ((messages (gethash buffer agent-shell-team--message-queue)))
    (remhash buffer agent-shell-team--message-queue)
    (let ((combined (mapconcat
                     (lambda (msg)
                       (format "[%s] %s: %s"
                               (plist-get msg :from)
                               (plist-get msg :title)
                               (plist-get msg :message)))
                     messages "\n")))
      (agent-shell-team--prompt-agent buffer
                                      (format "Queued messages while you were busy:\n%s" combined)))))

;;; Team log buffer

(defun agent-shell-team--log-buffer-name (session-id)
  "Return the log buffer name for SESSION-ID."
  (format "*team:%s:log*" (agent-shell-team--short-session-id session-id)))

(defun agent-shell-team--log (session-id message)
  "Log MESSAGE to team SESSION-ID's log buffer."
  (let ((buf (get-buffer-create (agent-shell-team--log-buffer-name session-id))))
    (with-current-buffer buf
      (goto-char (point-max))
      (insert (format "[%s] %s\n"
                      (format-time-string "%H:%M:%S")
                      message)))))

;;; Drain timer — periodic check for idle agents with pending messages

(defvar agent-shell-team--drain-timer nil
  "Timer for periodic queue drain checks.")

(defvar agent-shell-team--last-activity (make-hash-table :test 'eq)
  "Map buffer -> float-time of last ACP notification received.
Used to detect truly stuck agents (no output while busy).")

(defcustom agent-shell-team--stuck-timeout 180
  "Seconds of no ACP output after which a busy agent is considered stuck."
  :type 'integer
  :group 'agent-shell-team)

(defun agent-shell-team--track-activity (&rest _)
  "Record that the current buffer received ACP activity."
  (when (buffer-live-p (current-buffer))
    (puthash (current-buffer) (float-time) agent-shell-team--last-activity)))

(advice-add 'agent-shell--on-notification :before #'agent-shell-team--track-activity)

(defun agent-shell-team--maybe-auto-compact ()
  "Check if the current buffer is a lead agent needing compaction.
Called after usage_update notification arrives.  Only acts when:
- Buffer is a lead agent
- Agent is idle (not busy)
- Context usage >= threshold
- Cooldown has elapsed since last compact"
  (when (and (boundp 'agent-shell-team--role)
             agent-shell-team--role
             (string= agent-shell-team--role "lead")
             (boundp 'agent-shell--state)
             agent-shell--state
             (not shell-maker--busy))
    (let* ((usage (map-elt agent-shell--state :usage))
           (used (or (map-elt usage :context-used) 0))
           (size (or (map-elt usage :context-size) 0))
           (pct (if (> size 0) (* 100.0 (/ (float used) size)) 0.0))
           (last-compact (gethash (current-buffer) agent-shell-team--last-compact-time 0))
           (cooldown-elapsed (> (- (float-time) last-compact)
                                agent-shell-team-compact-cooldown)))
      (when (and (>= pct agent-shell-team-auto-compact-threshold)
                 cooldown-elapsed)
        (agent-shell-team--log agent-shell-team--session-id
          (format "[auto-compact] Lead context at %.0f%% (%d/%d tokens), triggering /compact"
                  pct used size))
        (puthash (current-buffer) (float-time) agent-shell-team--last-compact-time)
        ;; Use run-at-time 0 to avoid re-entrancy issues
        (let ((buf (current-buffer)))
          (run-at-time 0 nil
            (lambda ()
              (when (and (buffer-live-p buf)
                         (not (with-current-buffer buf shell-maker--busy))
                         (not (agent-shell-team--user-has-pending-input-p buf)))
                (with-current-buffer buf
                  (shell-maker-submit :input "/compact"))))))))))

(advice-add 'agent-shell--update-usage-from-notification :after
  (lambda (&rest _)
    (agent-shell-team--maybe-auto-compact)))

(defun agent-shell-team--find-agent-by-buffer (buf)
  "Find the agent alist entry for BUF across all sessions."
  (catch 'found
    (maphash (lambda (_session-id agents)
               (dolist (agent agents)
                 (when (eq (alist-get 'buffer agent) buf)
                   (throw 'found agent))))
             agent-shell-team--sessions)
    nil))

(defun agent-shell-team--deliver-interrupt-tasks (&rest _)
  "Deliver interrupt-priority tasks when an agent finishes its turn.
Added as :after advice on `shell-maker-finish-output'."
  (when-let* ((buf (current-buffer))
              (tasks (alist-get buf agent-shell-team--interrupt-queue)))
    ;; Remove from interrupt queue first
    (setf (alist-get buf agent-shell-team--interrupt-queue nil 'remove) nil)
    ;; Deliver each task via normal assignment (agent is now idle)
    (dolist (task tasks)
      (let ((agent (agent-shell-team--find-agent-by-buffer buf)))
        (when agent
          (agent-shell-team--assign-task-to-agent agent task))))))

(advice-add 'shell-maker-finish-output :after #'agent-shell-team--deliver-interrupt-tasks)

(defun agent-shell-team--start-drain-timer ()
  "Start periodic drain timer."
  (unless agent-shell-team--drain-timer
    (setq agent-shell-team--drain-timer
          (run-with-timer 3 3 #'agent-shell-team--check-all-queues))))

(defun agent-shell-team--stop-drain-timer ()
  "Stop periodic drain timer."
  (when agent-shell-team--drain-timer
    (cancel-timer agent-shell-team--drain-timer)
    (setq agent-shell-team--drain-timer nil)))

(defun agent-shell-team--check-all-queues ()
  "Check all queued messages and tasks, drain idle agents, assign pending tasks.
Also detects agents stuck in busy state with no ACP output for
`agent-shell-team--stuck-timeout' seconds and force-resets them."
  ;; --- Stuck-busy detection across all sessions ---
  (maphash
   (lambda (_session-id agents)
     (dolist (agent agents)
       (let ((buf (alist-get 'buffer agent)))
         (when (buffer-live-p buf)
           (if (eq (agent-shell-team--agent-status buf) 'busy)
               (let ((last-act (gethash buf agent-shell-team--last-activity)))
                 (if (and last-act
                          (> (- (float-time) last-act)
                             agent-shell-team--stuck-timeout))
                     ;; Truly stuck: no output for N seconds while busy
                     (progn
                       (message "[agent-shell-team] Force-resetting truly stuck agent %s (no output for %ds)"
                                (buffer-name buf)
                                (round (- (float-time) last-act)))
                       (remhash buf agent-shell-team--last-activity)
                       (with-current-buffer buf
                         (when (fboundp 'agent-shell-heartbeat-stop)
                           (agent-shell-heartbeat-stop))
                         (shell-maker-interrupt t)
                         (shell-maker-finish-output
                          :config shell-maker--config
                          :success nil)))
                   ;; Still receiving output or first time — seed if needed
                   (unless last-act
                     (puthash buf (float-time) agent-shell-team--last-activity))))
             ;; Agent is not busy — clear any tracked timestamp
             (remhash buf agent-shell-team--last-activity))))))
   agent-shell-team--sessions)
  ;; --- Drain pending-for-lead queue (messages queued before lead registered) ---
  (let ((delivered-sessions nil))
    (maphash (lambda (sid messages)
               (when-let ((lead-buf (agent-shell-team--get-lead sid)))
                 (push sid delivered-sessions)
                 (let ((combined (mapconcat #'identity messages "\n\n")))
                   (pcase (agent-shell-team--agent-status lead-buf)
                     ('idle (agent-shell-team--prompt-agent lead-buf combined))
                     ((or 'busy 'initializing)
                      (agent-shell-team--queue-message sid lead-buf
                        (list :from "agent" :title "Task Update (delayed)" :message combined)))
                     ('dead (agent-shell-team--log sid "WARNING: lead is dead, dropping pending messages"))))))
             agent-shell-team--pending-for-lead)
    (dolist (sid delivered-sessions)
      (remhash sid agent-shell-team--pending-for-lead)))
  ;; --- Drain message queues for idle agents (skip busy and initializing) ---
  (maphash (lambda (buffer _messages)
             (when (eq (agent-shell-team--agent-status buffer) 'idle)
               (agent-shell-team--drain-queue buffer)))
           agent-shell-team--message-queue)
  ;; --- Safety net: deliver interrupt tasks for any idle agents ---
  (let ((delivered nil))
    (dolist (entry agent-shell-team--interrupt-queue)
      (let ((buf (car entry))
            (tasks (cdr entry)))
        (when (and (buffer-live-p buf)
                   (eq (agent-shell-team--agent-status buf) 'idle)
                   tasks)
          (push buf delivered)
          (dolist (task tasks)
            (let ((agent (agent-shell-team--find-agent-by-buffer buf)))
              (when agent
                (agent-shell-team--assign-task-to-agent agent task)))))))
    (dolist (buf delivered)
      (setf (alist-get buf agent-shell-team--interrupt-queue nil 'remove) nil)))
  ;; Try to assign pending tasks (errors must not kill the drain timer)
  (when agent-shell-team--task-queue
    (message "[check-all-queues] Task queue has %d items, calling try-assign-tasks"
             (length agent-shell-team--task-queue)))
  (condition-case err
      (agent-shell-team--try-assign-tasks)
    (error
     (message "[check-all-queues] ERROR in try-assign-tasks: %s" (error-message-string err))
     (agent-shell-team--log agent-shell-team--session-id
      (format "[drain] Error in try-assign-tasks: %s" (error-message-string err)))))
  ;; Sync idle inhibit with actual agent busy states
  (agent-shell-team--sync-idle-inhibit)
  ;; Stop timer if no more queued messages, pending-for-lead, AND no pending tasks
  (when (and (zerop (hash-table-count agent-shell-team--message-queue))
             (zerop (hash-table-count agent-shell-team--pending-for-lead))
             (null agent-shell-team--task-queue)
             (null agent-shell-team--interrupt-queue)
             (zerop (hash-table-count agent-shell-team--idle-inhibit-tracked)))
    (message "[check-all-queues] All queues empty, stopping drain timer")
    (agent-shell-team--stop-drain-timer)))

;;; Cleanup

(defun agent-shell-team--buffer-kill-hook ()
  "Clean up team registration when buffer is killed.
Also removes the git worktree if the agent was in isolated mode."
  (message "[agent-shell-team] buffer-kill-hook fired for %s\nBacktrace:\n%s"
           (buffer-name)
           (backtrace-to-string (backtrace-frames 'agent-shell-team--buffer-kill-hook)))
  (when agent-shell-team--session-id
    ;; Capture worktree path BEFORE unregister removes the agent from sessions
    (let ((worktree-path agent-shell-team--worktree-path))
      ;; Mark agent idle (remove busy sentinel file) before unregistering
      (agent-shell-team--mark-agent-idle (buffer-name (current-buffer)))
      (agent-shell-team--unregister-agent (current-buffer))
      ;; Clean up any queued messages, interrupt tasks, and activity tracking for this buffer
      (remhash (current-buffer) agent-shell-team--message-queue)
      (setf (alist-get (current-buffer) agent-shell-team--interrupt-queue nil 'remove) nil)
      (remhash (current-buffer) agent-shell-team--last-activity)
      (remhash (current-buffer) agent-shell-team--last-compact-time)
      ;; Stop devcontainer before worktree removal (container bind-mounts the worktree)
      (when (and (bound-and-true-p agent-shell-team--role)
                 (bound-and-true-p agent-shell-team--worktree-path))
        (agent-shell-team--stop-devcontainer agent-shell-team--role agent-shell-team--worktree-path))
      ;; Remove worktree if it exists
      (when (and worktree-path (file-directory-p worktree-path))
        (let ((default-directory (file-name-parent-directory worktree-path)))
          (shell-command-to-string
           (format "git worktree remove --force %s 2>&1"
                   (shell-quote-argument worktree-path)))
          ;; Verify removal — fallback to delete-directory + prune if git failed
          (when (file-directory-p worktree-path)
            (message "[agent-shell-team] WARNING: git worktree remove failed for %s, falling back to delete-directory"
                     worktree-path)
            (delete-directory worktree-path t)
            (shell-command-to-string "git worktree prune 2>&1")))))))

(add-hook 'kill-buffer-hook #'agent-shell-team--buffer-kill-hook)

;;; Agent spawning

(cl-defun agent-shell-team--start-agent (session-id role mode &optional directory worktree-path worktree-name &key no-focus)
  "Start a team agent and return its buffer.
SESSION-ID is the team session UUID.
ROLE is \"lead\", \"dev\", \"tester\", or \"researcher\".
MODE is \"isolated\" or \"neighbor\".
DIRECTORY is the working directory.
WORKTREE-PATH and WORKTREE-NAME are for isolated mode."
  ;; Ensure namespace is initialized (idempotent, uses directory for locate-dominating-file)
  (let ((default-directory (or directory default-directory)))
    (when (fboundp 'agent-shell-namespace-init)
      (agent-shell-namespace-init)))
  (message "agent-shell-team: start-agent called for role=%s mode=%s" role mode)
  (let* ((buf-name (agent-shell-team--buffer-name session-id role worktree-name))
         (default-directory (or directory default-directory))
         (system-prompt (agent-shell-team--get-system-prompt
                         role mode session-id worktree-path worktree-name default-directory))
         (config (agent-shell-team--make-config session-id role buf-name)))
    (message "agent-shell-team: about to call agent-shell--start with buffer-name=%s" buf-name)
    (let ((buffer (let ((my/agent-shell-pending-worktree-path worktree-path))
                   (agent-shell--start
                    :config config
                    :no-focus no-focus
                    :new-session t
                    :session-strategy 'new
                    :outgoing-request-decorator
                    (agent-shell-team--make-request-decorator system-prompt)))))
      (message "agent-shell-team: agent-shell--start returned buffer=%s (process=%s)"
               buffer (get-buffer-process buffer))
      ;; Register in team session
      (message "agent-shell-team: registering agent...")
      (agent-shell-team--register-agent session-id buffer role mode worktree-path worktree-name)
      (message "agent-shell-team: agent registered")
      ;; Subscribe to tool-call-update events for notification routing
      ;; and notify existing team members about the new agent
      (agent-shell-subscribe-to
       :shell-buffer buffer
       :event 'init-finished
       :on-event (lambda (_event)
                   (message "agent-shell-team: init-finished fired for %s (process=%s)"
                            buffer (get-buffer-process buffer))
                   ;; Guard: only set up tool-call watcher once per buffer
                   (unless (buffer-local-value 'agent-shell-team--watcher-setup-p buffer)
                     (message "agent-shell-team: setting up watcher...")
                     (agent-shell-team--setup-tool-call-watcher buffer)
                     (with-current-buffer buffer
                       (setq agent-shell-team--watcher-setup-p t)))
                   ;; NOTE: Team announcements removed — they caused infinite
                   ;; busy/idle loops as agents responded to roster updates.
                   ;; Emacs already tracks agent status via the task queue.
                   (agent-shell-team--log session-id
                    (format "Agent joined: %s (%s mode%s) buffer=%s"
                            role mode
                            (if worktree-name (format ", worktree: %s" worktree-name) "")
                            (buffer-name buffer)))
                   ;; Activate custom doom-modeline
                   (when (fboundp 'doom-modeline-set-modeline)
                     (with-current-buffer buffer
                       (doom-modeline-set-modeline 'agent-shell-team)))
                   ;; Broadcast spawn to namespace peers
                   (when (fboundp 'agent-shell-namespace-emit-spawn)
                     (agent-shell-namespace-emit-spawn
                      (or role "unknown")
                      (or worktree-name "main")))
                   (message "agent-shell-team: init-finished complete for %s" buffer)
                   ;; Mark ACP init as done so --agent-status returns 'idle
                   (with-current-buffer buffer
                     (setq agent-shell-team--init-finished-p t))
                   ;; Immediately try assigning queued tasks to this newly ready agent
                   ;; instead of waiting up to 3s for the next drain timer tick
                   (agent-shell-team--try-assign-tasks)))
      buffer)))

(defun agent-shell-team--make-config (session-id role buffer-name)
  "Create agent-shell config for a team agent.
SESSION-ID, ROLE, and BUFFER-NAME customize the config."
  (agent-shell-emacs-mcp--ensure-mcp-ready)
  (agent-shell-make-agent-config
   :identifier 'claude-code-emacs-mcp
   :mode-line-name (format "Team:%s:%s" (agent-shell-team--short-session-id session-id) role)
   :buffer-name buffer-name
   :shell-prompt "Claude> "
   :shell-prompt-regexp "Claude> "
   :icon-name "anthropic.png"
   :welcome-function #'agent-shell-emacs-mcp--welcome-message
   :client-maker #'agent-shell-emacs-mcp--make-client
   :default-model-id (let ((model (or (cdr (assoc role agent-shell-team-role-models))
                               agent-shell-anthropic-default-model-id)))
                       (lambda () model))
   :default-session-mode-id (lambda () (or (and agent-shell-team-skip-permissions "bypassPermissions")
                                            agent-shell-anthropic-default-session-mode-id))
   :install-instructions "See https://github.com/zed-industries/claude-code-acp for installation."))

;;; Team membership announcements

(defun agent-shell-team--announce-agent (session-id buffer role mode worktree-name)
  "Announce a newly initialized agent to existing team members.
SESSION-ID is the team session. BUFFER is the new agent's buffer.
ROLE, MODE, and WORKTREE-NAME describe the new agent."
  (let ((agents (agent-shell-team--get-session-agents session-id))
        (announcement (format "Team update: %s agent joined (%s mode%s). Buffer: %s"
                              role mode
                              (if worktree-name (format ", worktree: %s" worktree-name) "")
                              (buffer-name buffer))))
    ;; Log the announcement
    (agent-shell-team--log session-id announcement)
    ;; Notify all OTHER agents (not the one that just joined)
    (dolist (agent agents)
      (let ((agent-buf (alist-get 'buffer agent)))
        (when (and (buffer-live-p agent-buf)
                   (not (eq agent-buf buffer)))
          ;; Build a team roster for context
          (let ((roster (agent-shell-team--build-roster session-id)))
            (agent-shell-team--queue-message
             session-id agent-buf
             (list :from "system"
                   :title "Team Update"
                   :message (format "TEAM UPDATE: A new %s agent has joined the session.\n\nCurrent team roster:\n%s"
                                    role roster)))))))))

(defun agent-shell-team--build-roster (session-id)
  "Build a human-readable roster of all agents in SESSION-ID."
  (let ((agents (agent-shell-team--get-session-agents session-id))
        (lines '()))
    (dolist (agent agents)
      (let* ((buf (alist-get 'buffer agent))
             (r (alist-get 'role agent))
             (m (alist-get 'mode agent))
             (wt (alist-get 'worktree-name agent))
             (status (agent-shell-team--agent-status buf)))
        (push (format "- %s (%s%s) [%s]"
                      r m
                      (if wt (format ", worktree: %s" wt) "")
                      status)
              lines)))
    (string-join (nreverse lines) "\n")))

;;; Interactive commands

;;;###autoload
(defun agent-shell-team ()
  "Start or extend a multi-agent team session.

When called from a non-team buffer:
  - Prompts for role (lead/dev/tester)
  - Creates a new session UUID
  - Starts the agent in the appropriate mode

When called from an existing team buffer:
  - Inherits the session UUID
  - Prompts for role and mode (isolated/neighbor)
  - Adds the new agent to the existing session"
  (interactive)
  (let* ((session-id (or agent-shell-team--session-id
                        (setq agent-shell-team--session-id
                              (agent-shell-team--generate-session-id))))
         (in-team-buffer (not (null (gethash session-id agent-shell-team--sessions))))
         (role (completing-read "Role: " '("lead" "dev" "tester" "researcher" "knowledge") nil t))
         (mode (if (member role '("lead" "researcher" "knowledge"))
                   "neighbor"  ;; Lead and researcher always work on main tree
                 (if in-team-buffer
                     (completing-read "Mode: " '("isolated" "neighbor") nil t)
                   "isolated"))) ;; Default to isolated for new sessions
         (parent-dir default-directory)
         worktree-path worktree-name directory)

    (message "agent-shell-team: start called, session=%s role=%s mode=%s"
             (agent-shell-team--short-session-id session-id) role mode)

    ;; Determine working directory
    (pcase mode
      ("isolated"
       (message "agent-shell-team: creating worktree for %s..." role)
       (let ((wt (agent-shell-team--create-worktree session-id role)))
         (setq worktree-path (car wt)
               worktree-name (cdr wt)
               directory worktree-path)
         (message "agent-shell-team: worktree created: %s" worktree-name)))
      ("neighbor"
       (setq directory parent-dir)))

    ;; Start the agent
    (message "agent-shell-team: spawning %s agent..." role)
    (let ((buffer (agent-shell-team--start-agent
                   session-id role mode directory worktree-path worktree-name)))
      ;; Start drain timer if we have team agents
      (agent-shell-team--start-drain-timer)
      ;; Switch to the new buffer
      (switch-to-buffer buffer)
      ;; Auto-show team sidebar for lead agent
      (when (equal role "lead")
        (when (fboundp 'my/team-sidebar--show)
          (my/team-sidebar--show)))
      (message "Team %s: %s agent started (%s mode)"
               (agent-shell-team--short-session-id session-id)
               role mode))))

;;; Team dashboard (transient menu)

(defun agent-shell-team--status-string ()
  "Generate the team status display string."
  (let ((lines '()))
    (maphash
     (lambda (session-id agents)
       (push (format "Session: %s" session-id) lines)
       (push (make-string 50 ?-) lines)
       (dolist (agent agents)
         (let* ((buf (alist-get 'buffer agent))
                (role (alist-get 'role agent))
                (wt-name (alist-get 'worktree-name agent))
                (status (agent-shell-team--agent-status buf))
                (status-str (pcase status
                              ('idle "  idle")
                              ('busy "* busy")
                              ('initializing "~ init")
                              ('dead "x dead"))))
           (push (format "  [%-6s] %-40s %s"
                         role
                         (if (buffer-live-p buf)
                             (buffer-name buf)
                           "(killed)")
                         status-str)
                 lines)))
       (push "" lines))
     agent-shell-team--sessions)
    (if lines
        (string-join (nreverse lines) "\n")
      "No active team sessions.")))

(transient-define-prefix agent-shell-team-status ()
  "Team dashboard."
  [:description
   (lambda () (agent-shell-team--status-string))
   ("n" "New agent" agent-shell-team)
   ("s" "Switch to agent" agent-shell-team-switch)
   ("k" "Kill agent" agent-shell-team-kill-agent)
   ("l" "View log" agent-shell-team-view-log)])

(defun agent-shell-team-switch ()
  "Switch to a team agent buffer."
  (interactive)
  (let ((buffers '()))
    (maphash
     (lambda (_session-id agents)
       (dolist (agent agents)
         (let ((buf (alist-get 'buffer agent)))
           (when (buffer-live-p buf)
             (push (buffer-name buf) buffers)))))
     agent-shell-team--sessions)
    (if buffers
        (switch-to-buffer (completing-read "Switch to agent: " buffers nil t))
      (user-error "No active team agents"))))

(defun agent-shell-team-kill-agent ()
  "Kill a team agent buffer."
  (interactive)
  (let ((buffers '()))
    (maphash
     (lambda (_session-id agents)
       (dolist (agent agents)
         (let ((buf (alist-get 'buffer agent)))
           (when (buffer-live-p buf)
             (push (buffer-name buf) buffers)))))
     agent-shell-team--sessions)
    (if buffers
        (let ((buf-name (completing-read "Kill agent: " buffers nil t)))
          (kill-buffer buf-name))
      (user-error "No active team agents"))))

(defun agent-shell-team-view-log ()
  "View the team log for the current or selected session."
  (interactive)
  (let ((sessions '()))
    (maphash (lambda (id _) (push id sessions)) agent-shell-team--sessions)
    (cond
     ;; In a team buffer — use its session
     (agent-shell-team--session-id
      (switch-to-buffer-other-window
       (agent-shell-team--log-buffer-name agent-shell-team--session-id)))
     ;; One session — use it
     ((= (length sessions) 1)
      (switch-to-buffer-other-window
       (agent-shell-team--log-buffer-name (car sessions))))
     ;; Multiple — prompt
     (sessions
      (let ((session (completing-read "Session: " sessions nil t)))
        (switch-to-buffer-other-window
         (agent-shell-team--log-buffer-name session))))
     (t (user-error "No active team sessions")))))

;;; Eager session-id initialization
;; One session per Emacs instance — generate at load time so MCP handlers
;; never encounter a nil session-id.
(unless agent-shell-team--session-id
  (setq agent-shell-team--session-id (agent-shell-team--generate-session-id)))

(require 'agent-shell-namespace nil t)  ;; soft require

(provide 'agent-shell-team)
;;; agent-shell-team.el ends here
