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
;; Supports four roles:
;;   - lead: Supervisor — reviews, merges, dispatches, assigns tasks
;;   - dev: Implements features in isolated worktrees
;;   - tester: Runs tests/validation, reports results
;;   - researcher: Explores codebase, finds code, answers questions about the project
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
(require 'acp)
(require 'transient)

;;; Customization

(defgroup agent-shell-team nil
  "Multi-agent team orchestration for agent-shell."
  :group 'agent-shell
  :prefix "agent-shell-team-")

(defcustom agent-shell-team-skip-permissions nil
  "When non-nil, spawn team agents with --dangerously-skip-permissions.
This gives agents full trust to edit files, run commands, etc.
without prompting for confirmation."
  :type 'boolean
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

(defface agent-shell-team-info-face
  '((t :background "#3b4252" :foreground "#88c0d0" :weight normal))
  "Face for team info (session, worktree) in mode line."
  :group 'agent-shell-team)

;;; Buffer-local variables

(defvar-local agent-shell-team--session-id nil
  "UUID grouping this agent with its team.")

(defvar-local agent-shell-team--role nil
  "Role: dev, lead, tester, or researcher.")

(defvar-local agent-shell-team--mode nil
  "Mode: isolated or neighbor.")

(defvar-local agent-shell-team--worktree-path nil
  "Git worktree path (isolated mode only).")

(defvar-local agent-shell-team--worktree-name nil
  "Git worktree name (isolated mode only).")

;;; Global registry

(defvar agent-shell-team--sessions (make-hash-table :test 'equal)
  "Session-uuid -> list of agent alists.
Each entry is: ((buffer . #<buffer>) (role . \"dev\") (mode . \"isolated\")
                (worktree . \"/path\") (worktree-name . \"focused-turing\"))")

(defvar agent-shell-team--message-queue (make-hash-table :test 'equal)
  "Buffer -> list of pending messages waiting for agent to become idle.")

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
  (substring session-id 0 (min 4 (length session-id))))

(defun agent-shell-team--generate-request-id ()
  "Generate a short unique request ID for task tracking."
  (substring (agent-shell-team--generate-session-id) 0 8))

(defun agent-shell-team--reports-dir (session-id)
  "Return reports directory for SESSION-ID, creating it if needed."
  (let ((dir (expand-file-name
              (format ".agent-shell/reports/%s/" session-id)
              (or (projectile-project-root) default-directory))))
    (unless (file-directory-p dir)
      (make-directory dir t))
    dir))

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
      (setq agent-shell-team--session-id session-id
            agent-shell-team--role role
            agent-shell-team--mode mode
            agent-shell-team--worktree-path worktree
            agent-shell-team--worktree-name worktree-name))))

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

(defun agent-shell-team--agent-status (buffer)
  "Determine if BUFFER's agent is idle, busy, or dead."
  (cond
   ((not (buffer-live-p buffer)) 'dead)
   ((agent-shell-team--buffer-busy-p buffer) 'busy)
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
  (let* ((repo-root (agent-shell-worktree--git-repo-root))
         (wt-name (agent-shell-worktree--generate-name))
         (wt-path (expand-file-name
                   (file-name-concat repo-root
                                     agent-shell-worktree--subdirectory
                                     wt-name))))
    (unless repo-root
      (user-error "Not in a git repository"))
    ;; Create parent directory if needed
    (make-directory (file-name-directory wt-path) t)
    ;; Create the worktree
    (let ((output (shell-command-to-string
                   (format "git worktree add %s 2>&1"
                           (shell-quote-argument wt-path)))))
      (unless (file-exists-p wt-path)
        (user-error "Failed to create worktree: %s" output))
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
  (format "You are the LEAD agent in a team session %s.

## CRITICAL RULE: You are a MANAGER, not an implementer.
NEVER write code, edit files, or implement tasks yourself.
Your ONLY job is to decompose work, delegate to dev agents, review results,
and coordinate the team. When you receive a task from the user, IMMEDIATELY
break it down and assign subtasks to dev agents via sendNotification.
Do NOT ask the user whether to delegate — just do it. That is your purpose.

Your responsibilities:
- Decompose tasks and assign them to dev agents immediately
- Review commits from dev agents when they notify you
- Merge approved worktree branches to the main branch
- Dispatch tester agents to validate merged code

Use sendNotification to communicate with other agents. Emacs routes messages
based on your role automatically. Use clear, structured notification titles:
- \"Task Assignment\" — assign work to a dev
- \"Run Tests\" — request testing
- \"Research Request\" — ask researcher to find/analyze something

When a dev signals completion, review their branch with:
  git diff main...{branch-name}
If approved: git merge {branch-name}, then notify the dev:
  title: \"Status Update\", message: \"Merged {branch-name}. Good work.\"
  Then notify the tester if needed.
If changes needed: notify the dev with specific feedback:
  title: \"Task Assignment\", message: \"Fix: {what needs changing} [Request ID: {original-id}]\"

## Sub-Tasking
You own ALL task decomposition. When you receive ANY task:
1. IMMEDIATELY break it into atomic, independently implementable subtasks
2. Assign each subtask to an idle dev via sendNotification:
   title: \"Task Assignment\", message: \"Subtask: {description}\"
3. If no idle devs are available, notify:
   title: \"Need More Agents\", message: \"N subtasks pending, only M devs available\"
4. Track which subtasks belong to the same parent task so you know when
   ALL subtasks are done before requesting a test run.
Devs never split tasks — they receive atomic units and execute them.
NEVER implement subtasks yourself — always delegate to dev agents.
Use the researcher agent when you need codebase exploration, finding files,
or understanding code before assigning tasks to devs.

## Reports
Task assignments include a Request ID and a report file path.
When an agent reports completion, their message includes a path to a detailed
report file (.agent-shell/reports/{session-id}/{request-id}.md).
ALWAYS read the report file to review the agent's work before proceeding."
          session-id))

(defun agent-shell-team--dev-prompt (session-id worktree-path worktree-name)
  "Generate dev system prompt for SESSION-ID.
WORKTREE-PATH and WORKTREE-NAME identify the dev's workspace."
  (format "You are a DEV agent in a team session %s.
Your working directory is a git worktree: %s
Your responsibilities:
- Implement the assigned task
- Commit your work when done (git add + git commit)
- Write a detailed report to the file path specified in your task assignment
  Include: what was done, files changed, any issues or decisions made
- Signal completion by calling sendNotification with:
  title: \"Task Complete\"
  message: \"dev:%s finished: {brief description} [Request ID: {id from assignment}]\"
- If you need logs or test output, request it via sendNotification:
  title: \"Need Verification\"
  message: \"Please run X and report results\"
- The lead will review and merge your work, or request fixes if needed.
- You receive atomic tasks from the lead. Do not split or delegate — just implement."
          session-id worktree-path worktree-name))

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
- Report results via sendNotification:
  title: \"Test Results\"
  message: \"PASS\" or \"FAIL: {details} [Request ID: {id from request}]\"
- You are the team's log detective. Collect, analyze, diagnose."
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
- Report findings via sendNotification:
  title: \"Log Report\" / \"Test Results\" / \"Runtime Check\"
  message: \"{brief summary} [Request ID: {id from request}]\"
- You are the team's log detective. Collect, analyze, diagnose."
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
- Report findings via sendNotification:
  title: \"Research Complete\"
  message: \"{brief summary of findings} [Request ID: {id from request}]\"
- You are the team's knowledge scout. Search, read, analyze, report."
          session-id working-dir))

(defun agent-shell-team--get-system-prompt (role mode session-id &optional worktree-path worktree-name working-dir)
  "Generate system prompt for ROLE in MODE within SESSION-ID.
WORKTREE-PATH, WORKTREE-NAME, WORKING-DIR depend on role/mode."
  (pcase role
    ("lead" (agent-shell-team--lead-prompt session-id))
    ("dev" (agent-shell-team--dev-prompt session-id worktree-path worktree-name))
    ("tester" (pcase mode
                ("isolated" (agent-shell-team--tester-isolated-prompt session-id worktree-path))
                (_ (agent-shell-team--tester-neighbor-prompt session-id (or working-dir default-directory)))))
    ("researcher" (agent-shell-team--researcher-prompt session-id (or working-dir default-directory)))))

;;; Doom modeline integration

(defun agent-shell-team--doom-modeline-role ()
  "Generate role badge segment for doom-modeline."
  (when agent-shell-team--role
    (let ((face (pcase agent-shell-team--role
                  ("lead" 'agent-shell-team-role-lead-face)
                  ("dev" 'agent-shell-team-role-dev-face)
                  ("tester" 'agent-shell-team-role-tester-face)
                  ("researcher" 'agent-shell-team-role-researcher-face))))
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
  "Handle tool-call-update EVENT. Route sendNotification calls between team agents."
  (let* ((data (map-elt event :data))
         (tool-call (alist-get :tool-call data))
         (tool-title (alist-get :title tool-call))
         (status (alist-get :status tool-call))
         (raw-input (alist-get :raw-input tool-call)))
    ;; Only intercept completed sendNotification tool calls
    (when (and tool-title
               (string-match-p "sendNotification" tool-title)
               (equal status "completed")
               agent-shell-team--session-id)
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
          (agent-shell-team--route-from-acp
           agent-shell-team--session-id
           agent-shell-team--role
           notif-title
           enriched-message))))))

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
            ('busy
             (agent-shell-team--queue-message
              session-id buf (list :from from-role :title title :message enriched-message)))
            ('dead
             (agent-shell-team--log session-id
                                    (format "WARNING: target %s buffer is dead, message dropped"
                                            target-role)))))))))

;;; Message delivery

(defun agent-shell-team--prompt-agent (buffer message)
  "Deliver MESSAGE to BUFFER's agent via shell-maker-submit.
This goes through shell-maker's normal prompt flow so that:
- The message appears in the shell buffer
- shell-maker--busy is set correctly
- ACP notifications render in-buffer instead of as stale minibuffer messages."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (shell-maker-submit :input (format "«TEAM»\n%s\n«/TEAM»" message)))))

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
               :buffer buffer))))))))

;;; Message queue & drain

(defun agent-shell-team--queue-message (_session-id buffer msg)
  "Queue MSG for BUFFER for later delivery.
_SESSION-ID is unused but kept for consistency."
  (let ((existing (gethash buffer agent-shell-team--message-queue)))
    (puthash buffer (append existing (list msg)) agent-shell-team--message-queue)))

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
  "Check all queued messages across all team sessions and drain idle agents."
  (maphash (lambda (buffer _messages)
             (when (and (buffer-live-p buffer)
                        (not (agent-shell-team--buffer-busy-p buffer)))
               (agent-shell-team--drain-queue buffer)))
           agent-shell-team--message-queue)
  ;; Stop timer if no more queued messages
  (when (zerop (hash-table-count agent-shell-team--message-queue))
    (agent-shell-team--stop-drain-timer)))

;;; Cleanup

(defun agent-shell-team--buffer-kill-hook ()
  "Clean up team registration when buffer is killed."
  (when agent-shell-team--session-id
    (agent-shell-team--unregister-agent (current-buffer))
    ;; Clean up any queued messages for this buffer
    (remhash (current-buffer) agent-shell-team--message-queue)))

(add-hook 'kill-buffer-hook #'agent-shell-team--buffer-kill-hook)

;;; Agent spawning

(defun agent-shell-team--start-agent (session-id role mode &optional directory worktree-path worktree-name)
  "Start a team agent and return its buffer.
SESSION-ID is the team session UUID.
ROLE is \"lead\", \"dev\", \"tester\", or \"researcher\".
MODE is \"isolated\" or \"neighbor\".
DIRECTORY is the working directory.
WORKTREE-PATH and WORKTREE-NAME are for isolated mode."
  (let* ((agent-shell-anthropic-claude-acp-command
          (if agent-shell-team-skip-permissions
              (append agent-shell-anthropic-claude-acp-command
                      '("--dangerously-skip-permissions"))
            agent-shell-anthropic-claude-acp-command))
         (buf-name (agent-shell-team--buffer-name session-id role worktree-name))
         (default-directory (or directory default-directory))
         (system-prompt (agent-shell-team--get-system-prompt
                         role mode session-id worktree-path worktree-name default-directory))
         (config (agent-shell-team--make-config session-id role buf-name))
         ;; Use agent-shell--start directly to force session-strategy 'new
         ;; This prevents hanging on session selection prompts
         (buffer (agent-shell--start
                  :config config
                  :no-focus nil
                  :new-session t
                  :session-strategy 'new
                  :outgoing-request-decorator
                  (agent-shell-team--make-request-decorator system-prompt))))
    ;; Register in team session
    (agent-shell-team--register-agent session-id buffer role mode worktree-path worktree-name)
    ;; Subscribe to tool-call-update events for notification routing
    ;; and notify existing team members about the new agent
    (agent-shell-subscribe-to
     :shell-buffer buffer
     :event 'init-finished
     :on-event (lambda (_event)
                 (agent-shell-team--setup-tool-call-watcher buffer)
                 ;; Notify existing agents about the new team member
                 (agent-shell-team--announce-agent session-id buffer role mode worktree-name)
                 ;; Activate custom doom-modeline
                 (when (fboundp 'doom-modeline-set-modeline)
                   (with-current-buffer buffer
                     (doom-modeline-set-modeline 'agent-shell-team)))))
    buffer))

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
   :default-model-id (lambda () agent-shell-anthropic-default-model-id)
   :default-session-mode-id (lambda () agent-shell-anthropic-default-session-mode-id)
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
            (agent-shell-team--prompt-agent-silent
             agent-buf
             (format "TEAM UPDATE: A new %s agent has joined the session.\n\nCurrent team roster:\n%s"
                     role roster))))))))

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
  (let* ((in-team-buffer (and agent-shell-team--session-id t))
         (session-id (if in-team-buffer
                         agent-shell-team--session-id
                       (agent-shell-team--generate-session-id)))
         (role (completing-read "Role: " '("lead" "dev" "tester" "researcher") nil t))
         (mode (if (member role '("lead" "researcher"))
                   "neighbor"  ;; Lead and researcher always work on main tree
                 (if in-team-buffer
                     (completing-read "Mode: " '("isolated" "neighbor") nil t)
                   "isolated"))) ;; Default to isolated for new sessions
         (parent-dir default-directory)
         worktree-path worktree-name directory)

    ;; Determine working directory
    (pcase mode
      ("isolated"
       (let ((wt (agent-shell-team--create-worktree session-id role)))
         (setq worktree-path (car wt)
               worktree-name (cdr wt)
               directory worktree-path)))
      ("neighbor"
       (setq directory parent-dir)))

    ;; Start the agent
    (let ((buffer (agent-shell-team--start-agent
                   session-id role mode directory worktree-path worktree-name)))
      ;; Start drain timer if we have team agents
      (agent-shell-team--start-drain-timer)
      ;; Switch to the new buffer
      (switch-to-buffer buffer)
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

(provide 'agent-shell-team)
;;; agent-shell-team.el ends here
