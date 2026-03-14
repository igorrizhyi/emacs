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

(defvar-local agent-shell-team--ephemeral nil
  "When non-nil, this agent was auto-spawned and should be dismissed after task completion.")

(defvar-local agent-shell-team--watcher-setup-p nil
  "When non-nil, the tool-call watcher has already been set up for this buffer.")

;;; Global registry

(defvar agent-shell-team--sessions (make-hash-table :test 'equal)
  "Session-uuid -> list of agent alists.
Each entry is: ((buffer . #<buffer>) (role . \"dev\") (mode . \"isolated\")
                (worktree . \"/path\") (worktree-name . \"focused-turing\"))")

(defvar agent-shell-team--message-queue (make-hash-table :test 'equal)
  "Buffer -> list of pending messages waiting for agent to become idle.")

(defvar agent-shell-team--task-queue nil
  "FIFO queue of pending tasks.  Each entry is a plist:
\(:role ROLE :message MSG :request-id ID :group-id GID :session-id SID :report-path PATH\)")

(defvar agent-shell-team--task-groups (make-hash-table :test 'equal)
  "Group ID -> plist (:pending (id1 id2) :completed (id3) :session-id SID).")

(defvar agent-shell-team--request-to-group (make-hash-table :test 'equal)
  "Request ID -> group ID mapping for completion lookups.")

(defvar agent-shell-team--request-to-buffer (make-hash-table :test 'equal)
  "Map request-id to the agent buffer it was assigned to.")

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

(defun agent-shell-team--knowledge-dir ()
  "Return knowledge directory path, creating it and seeding role files if needed."
  (let ((dir (expand-file-name
              ".agent-shell/knowledge/"
              (or (projectile-project-root) default-directory))))
    (unless (file-directory-p dir)
      (make-directory dir t))
    (dolist (role '("dev" "tester" "researcher"))
      (let ((file (expand-file-name (format "%s.md" role) dir)))
        (unless (file-exists-p file)
          (with-temp-file file
            (insert (format "# %s Knowledge\n" (capitalize role)))))))
    dir))

(defun agent-shell-team--knowledge-file (role)
  "Return the knowledge file path for ROLE."
  (expand-file-name (format "%s.md" role)
                    (agent-shell-team--knowledge-dir)))

(defun agent-shell-team--notify (title message)
  "Send a desktop notification for team events."
  (if (fboundp 'alert)
      (alert message
             :title title
             :category 'agent-shell-team)
    (message "[%s] %s" title message)))

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
  ],
  \"session_id\": \"%s\"          // optional: for multi-session routing
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

When a dev signals completion, review their branch with:
  git diff main...{branch-name}
If approved: git merge {branch-name}, then dismiss the dev:
  dismissAgent(target: \"request-id\")
  The `target` parameter accepts a request ID (preferred), worktree name, or buffer name.
  Request ID is the most reliable identifier since agents may rename their branches.
  This immediately cleans up the agent buffer and worktree. No notifications are sent.
  Then dispatch a tester if needed via tasksPut.
If changes needed: send a new tasksPut with fix instructions and the `target` field set to the
agent's request ID, worktree name, or buffer name — this routes the task directly to that agent
(useful for follow-up fixes where the agent already has context).

Use `dismissAgent` for any role (dev, tester, researcher) when their work is complete.
The `target` parameter accepts a request ID (preferred), worktree name, or buffer name (substring match).

## Sub-Tasking
You own ALL task decomposition. When you receive ANY task:
1. IMMEDIATELY break it into atomic, independently implementable subtasks
2. Submit ALL subtasks via a single `tasksPut` call with the same `group_id`
3. Emacs assigns them to idle agents automatically — no need to check availability
4. You receive a \"Group Complete\" notification when all subtasks finish
Devs never split tasks — they receive atomic units and execute them.
NEVER implement subtasks yourself — always delegate to dev agents.

## Research Workflows
Two patterns for using researchers before assigning dev tasks:

1. **Single researcher:** When you don't know the codebase well enough, dispatch ONE
   researcher to investigate and return a plan. Then use that plan to assign dev tasks.

2. **Parallel researchers:** When you already have a plan (or got one from step 1),
   break the research into multiple independent questions and dispatch them to MULTIPLE
   researchers simultaneously via `tasksPut` with the same `group_id`. Wait for the
   \"Group Complete\" notification, then use the combined findings to assign dev tasks.

Each research task should be atomic and independent. If you already know enough
to assign dev tasks directly, skip research entirely — the same parallel pattern
works for dev tasks too.

## Reports
Task assignments include a Request ID and a report file path (auto-injected by Emacs).
When an agent reports completion, their message includes a path to a detailed
report file (.agent-shell/reports/{session-id}/{request-id}.md).
ALWAYS read the report file to review the agent's work before proceeding.

## Knowledge Base
The team maintains a shared knowledge base at `.agent-shell/knowledge/`.
Role-specific files (e.g., `dev.md`, `tester.md`, `researcher.md`) store
project-specific nuances, patterns, and lessons learned.

Your responsibilities:
- When reviewing reports, extract reusable insights (gotchas, conventions,
  architecture decisions, environment quirks) and append them to the
  appropriate knowledge file.
- When assigning tasks, if a relevant knowledge file exists, include its path
  in the task message and instruct the agent to read it first.
  Example: \"Before starting, read the knowledge file: %s/dev.md\"
- Knowledge from the user (preferences, constraints) should also be captured.
- Keep knowledge files concise and organized by topic — not a raw log."
          (agent-shell-team--knowledge-dir)
          session-id session-id))

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
- Signal completion by calling the `taskUpdate` MCP tool:
  request_id: The Request ID from your task assignment
  status: \"finished\" (or \"updated\" for progress, \"blocked\" if stuck)
  content: Summary of what was done, files changed, decisions made
  commit: Your commit hash (if you committed code)
  report_path: Path to your report file (from the task assignment)
  session_id: \"%s\" (for multi-session routing)
- Use `sendNotification` only for non-task communication (e.g., asking the lead a question).
- The lead will review and merge your work, or request fixes if needed.
- You receive atomic tasks from the lead. Do not split or delegate — just implement.

## Branch Naming (do this FIRST)
Immediately after receiving a task, rename your branch before any other work:
  git branch -m <prefix>/<short-slug>
Prefixes: feature/, fix/, refactor/, docs/, test/, chore/
Slug: 2-4 word kebab-case summary (e.g. feature/dark-mode-toggle, fix/auth-token-expiry).
Include the new branch name in your taskUpdate so the lead knows what to merge.

## Knowledge Base
- If the lead points you to a knowledge file, read it BEFORE starting work.
- In your report, include a `## Knowledge Discoveries` section at the end.
  List any reusable insights: gotchas, conventions, environment quirks,
  architecture decisions. Use bullet points. If none, write \"None\".
  The lead will extract these into the shared knowledge base."
          session-id worktree-path worktree-name session-id))

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
  session_id: \"%s\" (for multi-session routing)
- Use `sendNotification` only for non-task communication.
- You are the team's log detective. Collect, analyze, diagnose.

## Knowledge Base
- If the lead points you to a knowledge file, read it BEFORE starting work.
- In your report, include a `## Knowledge Discoveries` section at the end.
  List any reusable insights: gotchas, conventions, environment quirks,
  architecture decisions. Use bullet points. If none, write \"None\".
  The lead will extract these into the shared knowledge base."
          session-id worktree-path session-id))

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
  session_id: \"%s\" (for multi-session routing)
- Use `sendNotification` only for non-task communication.
- You are the team's log detective. Collect, analyze, diagnose.

## Knowledge Base
- If the lead points you to a knowledge file, read it BEFORE starting work.
- In your report, include a `## Knowledge Discoveries` section at the end.
  List any reusable insights: gotchas, conventions, environment quirks,
  architecture decisions. Use bullet points. If none, write \"None\".
  The lead will extract these into the shared knowledge base."
          session-id working-dir session-id))

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
  session_id: \"%s\" (for multi-session routing)
- Use `sendNotification` only for non-task communication.
- You are the team's knowledge scout. Search, read, analyze, report.

## Knowledge Base
- If the lead points you to a knowledge file, read it BEFORE starting work.
- In your report, include a `## Knowledge Discoveries` section at the end.
  List any reusable insights: gotchas, conventions, environment quirks,
  architecture decisions. Use bullet points. If none, write \"None\".
  The lead will extract these into the shared knowledge base."
          session-id working-dir session-id))

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
                (agent-shell-team--handle-task-completion
                 request-id agent-shell-team--session-id (current-buffer))))
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

(defun agent-shell-team--handle-dismiss-agent (raw-input)
  "Handle dismissAgent MCP tool call with RAW-INPUT.
Find the agent matching `target' and clean it up immediately.
Only the lead role may call this.  Returns an alist with success/message."
  (let* ((target (or (map-elt raw-input 'target)
                     (map-elt raw-input "target")))
         (session-id (or (map-elt raw-input 'session_id)
                         (map-elt raw-input "session_id")
                         agent-shell-team--session-id))
         (_warn (unless session-id
                  (message "[agent-shell-team] WARNING: dismissAgent has no session-id, dropping"))))
    (cond
     ;; Guard: need a session
     ((not session-id)
      `((success . nil)
        (message . "No session ID available")))
     ;; Find and dismiss the matching agent
     (t
      (let ((all-agents (agent-shell-team--get-session-agents session-id))
            (found nil))
        (dolist (agent all-agents)
          (let ((wt-name (alist-get 'worktree-name agent))
                (buf (alist-get 'buffer agent))
                (role (alist-get 'role agent)))
            ;; Never dismiss the lead
            (when (and (not (equal role "lead"))
                       (not found)
                       (or (and wt-name (string-match-p (regexp-quote target) wt-name))
                           (and (buffer-live-p buf)
                                (string-match-p (regexp-quote target) (buffer-name buf)))
                           (and (buffer-live-p buf)
                                (eq buf (gethash target agent-shell-team--request-to-buffer)))))
              (setq found t)
              (agent-shell-team--log session-id
               (format "[dismissAgent] Cleaning up %s (%s)" role (buffer-name buf)))
              (agent-shell-team--cleanup-agent
               buf session-id (alist-get 'worktree agent)))))
        (if found
            `((success . t)
              (message . ,(format "Agent matching '%s' dismissed" target)))
          `((success . nil)
            (message . ,(format "No agent found matching '%s'" target)))))))))

(defun agent-shell-team--cleanup-agent (buffer session-id worktree-path)
  "Clean up BUFFER: unregister from session, kill buffer, optionally remove worktree."
  (agent-shell-team--log session-id
   (format "[cleanup] Killing agent buffer %s%s"
           (if (buffer-live-p buffer) (buffer-name buffer) "(already dead)")
           (if worktree-path (format ", removing worktree %s" worktree-path) "")))
  ;; Clean up request-to-buffer mappings for this agent
  (maphash (lambda (k v)
             (when (eq v buffer)
               (remhash k agent-shell-team--request-to-buffer)))
           (copy-hash-table agent-shell-team--request-to-buffer))
  (when (buffer-live-p buffer)
    (agent-shell-team--unregister-agent buffer)
    (kill-buffer buffer))
  ;; Remove worktree if it exists
  (when (and worktree-path (file-directory-p worktree-path))
    (let ((default-directory (file-name-parent-directory worktree-path)))
      (shell-command-to-string
       (format "git worktree remove --force %s 2>&1"
               (shell-quote-argument worktree-path))))))

;;; Task queue — enqueue, assign, group tracking

(defun agent-shell-team--handle-tasks-put (raw-input)
  "Process a tasksPut tool call with RAW-INPUT.
Extract tasks, generate IDs, register groups, and enqueue for assignment."
  (let ((tasks (or (map-elt raw-input 'tasks)
                   (map-elt raw-input "tasks"))))
    (when tasks
      (dolist (task (append tasks nil))  ;; convert vector to list
        (let* ((role (or (map-elt task 'role) (map-elt task "role")))
               (message (or (map-elt task 'message) (map-elt task "message")))
               (group-id (or (map-elt task 'group_id) (map-elt task "group_id")))
               (target (or (map-elt task 'target) (map-elt task "target")))
               (request-id (or (map-elt task 'request_id) (map-elt task "request_id")
                               (agent-shell-team--generate-request-id)))
               (session-id (or (map-elt task 'session_id)
                               (map-elt task "session_id")
                               agent-shell-team--session-id))
               (_warn (unless session-id
                        (message "[agent-shell-team] WARNING: tasksPut has no session-id, dropping")))
               (reports-dir (agent-shell-team--reports-dir session-id))
               (report-path (expand-file-name (concat request-id ".md") reports-dir))
               (entry (list :role role
                            :message message
                            :request-id request-id
                            :group-id group-id
                            :target target
                            :session-id session-id
                            :report-path report-path)))
          ;; Register in group tracker if group_id is present
          (when group-id
            (let ((group (or (gethash group-id agent-shell-team--task-groups)
                             (list :pending nil :completed nil :session-id session-id))))
              (plist-put group :pending (cons request-id (plist-get group :pending)))
              (puthash group-id group agent-shell-team--task-groups))
            (puthash request-id group-id agent-shell-team--request-to-group))
          ;; Append to FIFO queue
          (setq agent-shell-team--task-queue
                (append agent-shell-team--task-queue (list entry)))
          (agent-shell-team--log session-id
                                 (format "[tasksPut] Queued %s task: %s (request: %s%s)"
                                         role
                                         (truncate-string-to-width message 60 nil nil "...")
                                         request-id
                                         (if group-id (format ", group: %s" group-id) "")))))
      ;; Try to assign immediately
      (agent-shell-team--try-assign-tasks)
      ;; Ensure drain timer is running for retries
      (agent-shell-team--start-drain-timer))))

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
         (session-id (or (map-elt raw-input 'session_id)
                        (map-elt raw-input "session_id")
                        agent-shell-team--session-id))
         (_warn (unless session-id
                  (message "[agent-shell-team] WARNING: taskUpdate has no session-id, dropping")))
         (lead-buf (when session-id
                     (agent-shell-team--get-lead session-id))))
    (when lead-buf
      (let* ((message (format "Task Update [%s] — %s\nRequest ID: %s%s%s\n\n%s"
                              status
                              request-id
                              request-id
                              (if commit (format "\nCommit: %s" commit) "")
                              (if report-path (format "\nReport: %s" report-path) "")
                              content))
             (lead-status (agent-shell-team--agent-status lead-buf)))
        ;; Log it
        (agent-shell-team--log session-id
                               (format "[taskUpdate] %s from request %s"
                                       status request-id))
        ;; Desktop notification for task lifecycle events
        (when (member status '("finished" "blocked"))
          (agent-shell-team--notify
           (format "Task %s" (capitalize status))
           (format "%s" request-id)))
        ;; Deliver or queue to lead
        (pcase lead-status
          ('idle (agent-shell-team--prompt-agent lead-buf message))
          ((or 'busy 'initializing)
           (agent-shell-team--queue-message session-id lead-buf
                                            (list :from "agent" :title "Task Update" :message message)))
          ('dead (agent-shell-team--log session-id "WARNING: lead buffer is dead")))
        ;; Handle group completion tracking if status is "finished"
        (when (equal status "finished")
          (when-let ((group-id (gethash request-id agent-shell-team--request-to-group)))
            (agent-shell-team--handle-task-completion request-id session-id nil)))))))

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
  (let* ((mode (if (member role '("dev" "tester")) "isolated" "neighbor"))
         worktree-path worktree-name directory)
    (pcase mode
      ("isolated"
       (let ((wt (agent-shell-team--create-worktree session-id role)))
         (setq worktree-path (car wt)
               worktree-name (cdr wt)
               directory worktree-path)))
      ("neighbor"
       (setq directory default-directory)))
    (let ((buffer (agent-shell-team--start-agent
                   session-id role mode directory worktree-path worktree-name)))
      (with-current-buffer buffer
        (setq agent-shell-team--ephemeral t))
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
  (let ((remaining nil))
    (dolist (task agent-shell-team--task-queue)
      (let* ((role (plist-get task :role))
             (session-id (plist-get task :session-id))
             (target (plist-get task :target))
             (targeted-agent
              (when target
                (cl-find-if
                 (lambda (a)
                   (let ((buf (alist-get 'buffer a)))
                     (and (buffer-live-p buf)
                          (or (string-match-p (regexp-quote target) (buffer-name buf))
                              (let ((wt (alist-get 'worktree-name a)))
                                (and wt (string-match-p (regexp-quote target) wt)))))))
                 (agent-shell-team--get-agents-by-role session-id role)))))
        (cond
         ;; Targeted assignment: agent found and idle — assign directly
         ((and targeted-agent
               (eq (agent-shell-team--agent-status (alist-get 'buffer targeted-agent)) 'idle))
          (agent-shell-team--assign-task-to-agent targeted-agent task))
         ;; Targeted assignment: agent found but busy — wait for it
         ((and targeted-agent
               (memq (agent-shell-team--agent-status (alist-get 'buffer targeted-agent))
                     '(busy initializing)))
          (push task remaining))
         ;; Normal assignment: find any idle agent for this role
         (t
          (let ((idle-agent (agent-shell-team--find-idle-agent session-id role)))
            (if idle-agent
                (agent-shell-team--assign-task-to-agent idle-agent task)
              ;; No idle agent — try auto-spawning if allowed
              (let ((role-agents (agent-shell-team--get-agents-by-role session-id role)))
                (if (and (not (equal role "lead"))
                         (< (length role-agents) agent-shell-team-max-agents-per-role)
                         ;; Don't spawn if an ephemeral agent is still initializing
                         ;; (prevents race: spawn fires every tick while agent starts up)
                         (not (cl-some
                               (lambda (a)
                                 (and (buffer-local-value 'agent-shell-team--ephemeral
                                                         (alist-get 'buffer a))
                                      (memq (agent-shell-team--agent-status
                                             (alist-get 'buffer a))
                                            '(initializing))))
                               role-agents)))
                    (progn
                      (agent-shell-team--log session-id
                       (format "[auto-spawn] No idle %s agent, spawning new one" role))
                      (agent-shell-team--auto-spawn-agent session-id role)
                      ;; Push task back — new agent is still initializing,
                      ;; it will be assigned on the next drain timer tick
                      (push task remaining))
                  (push task remaining)))))))))
    (setq agent-shell-team--task-queue (nreverse remaining))))

(defun agent-shell-team--assign-task-to-agent (agent task)
  "Assign TASK to AGENT by delivering enriched message."
  (let* ((buf (alist-get 'buffer agent))
         (request-id (plist-get task :request-id))
         (report-path (plist-get task :report-path))
         (session-id (plist-get task :session-id))
         (role (plist-get task :role))
         (message (plist-get task :message))
         (knowledge-path (agent-shell-team--knowledge-file role))
         (enriched (format "%s\n\nBefore starting, read the knowledge file for your role: %s\n\n[Request ID: %s]\nWrite your detailed report to: %s\nReference this Request ID in your completion notification."
                           message knowledge-path request-id report-path)))
    (agent-shell-team--log session-id
                           (format "[assign] %s -> %s (request: %s)"
                                   (plist-get task :role)
                                   (buffer-name buf)
                                   request-id))
    (puthash request-id buf agent-shell-team--request-to-buffer)
    (agent-shell-team--prompt-agent
     buf (format "Task Assignment -- %s" enriched))))

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

(defun agent-shell-team--prompt-agent (buffer message)
  "Deliver MESSAGE to BUFFER's agent via shell-maker-submit.
This goes through shell-maker's normal prompt flow so that:
- The message appears in the shell buffer
- shell-maker--busy is set correctly
- ACP notifications render in-buffer instead of as stale minibuffer messages."
  (when (buffer-live-p buffer)
    (message "agent-shell-team: prompt-agent to %s (process=%s, status=%s)"
             (buffer-name buffer) (get-buffer-process buffer)
             (agent-shell-team--agent-status buffer))
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
               :buffer buffer
               :on-success (lambda (_acp-response)
                             (when (buffer-live-p buffer)
                               (with-current-buffer buffer
                                 (shell-maker-finish-output
                                  :config shell-maker--config
                                  :success t))))
               :on-failure (lambda (_acp-error &optional _raw-message)
                             (when (buffer-live-p buffer)
                               (with-current-buffer buffer
                                 (shell-maker-finish-output
                                  :config shell-maker--config
                                  :success nil))))))))))))

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

(defvar agent-shell-team--busy-since (make-hash-table :test 'equal)
  "Buffer -> timestamp (float-time) when the agent was first seen busy.
Used by `agent-shell-team--check-all-queues' to detect stuck-busy agents.")

(defconst agent-shell-team--stuck-busy-timeout 90
  "Seconds after which a continuously busy agent is force-reset.")

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
Also detects agents stuck in busy state longer than
`agent-shell-team--stuck-busy-timeout' seconds and force-resets them."
  ;; --- Stuck-busy detection across all sessions ---
  (maphash
   (lambda (_session-id agents)
     (dolist (agent agents)
       (let ((buf (alist-get 'buffer agent)))
         (when (buffer-live-p buf)
           (let ((status (agent-shell-team--agent-status buf)))
             (if (eq status 'busy)
                 (let ((since (gethash buf agent-shell-team--busy-since)))
                   (if since
                       ;; Already tracked — check if stuck
                       (when (> (- (float-time) since)
                                agent-shell-team--stuck-busy-timeout)
                         (message "[agent-shell-team] Force-resetting stuck-busy agent %s (busy for %ds)"
                                  (buffer-name buf)
                                  (round (- (float-time) since)))
                         (remhash buf agent-shell-team--busy-since)
                         (with-current-buffer buf
                           (shell-maker-finish-output
                            :config shell-maker--config
                            :success nil)))
                     ;; First time seeing this agent busy — record timestamp
                     (puthash buf (float-time) agent-shell-team--busy-since)))
               ;; Agent is not busy — clear any tracked timestamp
               (remhash buf agent-shell-team--busy-since)))))))
   agent-shell-team--sessions)
  ;; --- Drain message queues for idle agents (skip busy and initializing) ---
  (maphash (lambda (buffer _messages)
             (when (eq (agent-shell-team--agent-status buffer) 'idle)
               (agent-shell-team--drain-queue buffer)))
           agent-shell-team--message-queue)
  ;; Try to assign pending tasks
  (agent-shell-team--try-assign-tasks)
  ;; Stop timer if no more queued messages AND no pending tasks
  (when (and (zerop (hash-table-count agent-shell-team--message-queue))
             (null agent-shell-team--task-queue))
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
  (message "agent-shell-team: start-agent called for role=%s mode=%s" role mode)
  (let* ((buf-name (agent-shell-team--buffer-name session-id role worktree-name))
         (default-directory (or directory default-directory))
         (system-prompt (agent-shell-team--get-system-prompt
                         role mode session-id worktree-path worktree-name default-directory))
         (config (agent-shell-team--make-config session-id role buf-name)))
    (message "agent-shell-team: about to call agent-shell--start with buffer-name=%s" buf-name)
    (let ((buffer (agent-shell--start
                   :config config
                   :no-focus nil
                   :new-session t
                   :session-strategy 'new
                   :outgoing-request-decorator
                   (agent-shell-team--make-request-decorator system-prompt))))
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
                   (message "agent-shell-team: init-finished complete for %s" buffer)
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
   :default-model-id (lambda () agent-shell-anthropic-default-model-id)
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

(provide 'agent-shell-team)
;;; agent-shell-team.el ends here
