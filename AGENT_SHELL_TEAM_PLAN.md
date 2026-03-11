# Plan: agent-shell-team — Multi-Agent Team Workflow

## Goal
Build a team orchestration layer on top of `agent-shell-emacs-mcp` that lets multiple Claude Code agents work together with defined roles, session grouping, and two cooperation modes.

## Core Concepts

### Roles
- **dev** — Implements features/fixes. Works in its own worktree (isolated mode). Commits when done, notifies lead.
- **lead** — Supervisor. Reviews dev commits, merges to main tree, dispatches tester agents, assigns new tasks to idle devs.
- **tester** — Runs tests/validation on merged code. Reports results back to lead.

### Session Group
- First `agent-shell-team` call generates a **UUID session ID**
- All subsequent team agents spawned from that session inherit the same UUID
- Session ID stored as buffer-local var + tracked in a global registry

### Modes (when spawning from an existing team buffer)
- **isolated** — New agent gets its own git worktree. No file locking needed. Agent commits to its worktree branch, lead merges.
- **neighbor** — Agent shares the parent's working directory. No worktree, no file locking. Used for **read-only assistance**: running commands, grabbing logs, checking browser output, inspecting state. The neighbor doesn't write code — it observes and reports back.

### Neighbor Mode — Details

**Primary use case:** Testers and debug helpers that need to run in the same directory as a dev or lead to:
- Execute test suites / linters / build commands
- Open a browser and grab screenshots or console logs
- Tail log files, check process output, inspect runtime state
- Run `curl` / API calls against a locally running server
- Any read-heavy, observe-and-report task

**Why no locking:** Neighbor agents are not expected to modify source files. They run commands, collect output, and report back via `sendNotification`. If a neighbor does write (e.g., a test fixture), that's the user's responsibility to coordinate — we don't enforce locks in v1.

**Typical flow:**
1. Dev is implementing a feature in isolated mode
2. Dev needs to verify something → asks lead (or user spawns manually)
3. Lead/user spawns a tester in **neighbor** mode targeting the dev's worktree directory
4. Tester runs commands, grabs logs, sends results back to dev via notification
5. Dev continues based on tester's feedback

**Neighbor agents can target any directory** — not just the main tree. When spawned from a dev's buffer in isolated mode, the neighbor runs in that dev's worktree. When spawned from the lead, it runs in the main tree.

## Architecture — Pure ACP Approach

### Key Insight: No MCP Modifications Needed

Agent-shell uses ACP (Agent Client Protocol) for all communication between Emacs and Claude Code CLI processes. ACP already provides:

1. **Full visibility into agent activity** — `agent-shell--on-notification` sees every tool call (including `sendNotification`) with full `rawInput` arguments via the `tool-call-update` event
2. **Event subscription system** — `agent-shell-subscribe-to` lets us hook into per-buffer events like `tool-call-update`
3. **Programmatic prompt injection** — `acp-send-request` with `acp-make-session-prompt-request` sends prompts to any agent
4. **System prompt at session creation** — `acp-make-session-new-request` accepts `:meta '((systemPrompt . "..."))` to set role instructions

This means **all orchestration lives in Emacs**. No changes to the MCP server (TypeScript) or MCP tool schemas are required.

### Communication Flow

```
Agent A calls sendNotification(title: "Task Complete", message: "...")
    │
    ▼  (ACP notification — Emacs sees the tool call with full rawInput)
    │
    ▼  agent-shell-team intercepts via tool-call-update subscription
    │
    ▼  Routing logic: sender's role + notification title → determine target
    │
    ▼  acp-send-request + acp-make-session-prompt-request → inject into Agent B
```

### Why This Works

- **Outbound (agent → Emacs):** The agent calls `sendNotification` (standard MCP tool, no changes). ACP mirrors the tool call to Emacs with full arguments in `rawInput`. Our `tool-call-update` subscription intercepts it.
- **Routing (Emacs decides):** Emacs knows each buffer's role and session. It inspects the notification title/message and the sender's role to determine routing.
- **Delivery (Emacs → agent):** Emacs sends a prompt to the target agent via ACP's `session/prompt` request — a first-class ACP operation, not a shell-maker hack.
- **System prompts:** Set at session creation via ACP `:meta systemPrompt`, not injected as a first user message.

```
┌─────────────────────────────────────────────────────────────────┐
│                  agent-shell-team registry                       │
│  Hash table: session-uuid → list of (buffer, role, mode, wt)   │
└──────────────────────┬──────────────────────────────────────────┘
                       │
        ┌──────────────┼──────────────┐
        ▼              ▼              ▼
   ┌─────────┐   ┌─────────┐   ┌─────────┐
   │ lead     │   │ dev #1  │   │ dev #2  │
   │ (main)   │   │ (wt-1)  │   │ (wt-2)  │
   └────┬─────┘   └────┬────┘   └────┬────┘
        │              │              │
        ▼              ▼              ▼
   ACP client      ACP client     ACP client
   (each buffer has its own ACP connection to its Claude Code CLI)
```

Emacs is the orchestrator. It watches all ACP streams, routes messages between agents, and delivers via ACP prompts. MCP is untouched.

---

## Phase 1: Data Model & Registry

### New file: `modules/agent-shell-team.el`

**Buffer-local variables per team agent:**
```elisp
(defvar-local agent-shell-team--session-id nil "UUID grouping this agent with its team.")
(defvar-local agent-shell-team--role nil "Role: dev, lead, or tester.")
(defvar-local agent-shell-team--mode nil "Mode: isolated or neighbor.")
(defvar-local agent-shell-team--worktree-path nil "Git worktree path (isolated mode only).")
```

**Global registry:**
```elisp
(defvar agent-shell-team--sessions (make-hash-table :test 'equal)
  "session-uuid → alist of agent info:
   ((buffer . #<buffer>) (role . dev) (mode . isolated) (worktree . \"/path\"))")
```

**Helper functions:**
- `agent-shell-team--generate-session-id` — `(org-id-uuid)` or `uuidgen` fallback
- `agent-shell-team--register-agent (session-id buffer role mode &optional worktree)` — add to registry
- `agent-shell-team--unregister-agent (buffer)` — remove on buffer kill
- `agent-shell-team--get-session-agents (session-id)` — list all agents in session
- `agent-shell-team--get-lead (session-id)` — find the lead buffer
- `agent-shell-team--get-idle-devs (session-id)` — devs not currently busy

---

## Phase 2: `agent-shell-team` Interactive Command

### Entry point: `M-x agent-shell-team`

**When called standalone (not from a team buffer):**
1. Prompt for role: `(completing-read "Role: " '("lead" "dev" "tester"))`
2. Generate new session UUID
3. If role is `dev` or `tester` → prompt: create worktree? (default yes for isolated mode)
4. Start `agent-shell-emacs-mcp` in the appropriate directory
5. Set buffer-local vars, register in global session
6. Set system prompt via ACP `:meta systemPrompt` at session creation

**When called from an existing team buffer:**
1. Inherit session UUID from parent buffer
2. Prompt for role
3. Prompt for mode: `(completing-read "Mode: " '("isolated" "neighbor"))`
4. If isolated → create worktree via `agent-shell-worktree` machinery, register
5. If neighbor → start in same directory (defer locking for now)
6. Register new agent in same session group

### Buffer naming
```
*team:{session-short}:{role}:{worktree-name}*
```
Example: `*team:a1b2:dev:focused-turing*`, `*team:a1b2:lead:main*`

---

## Phase 3: Worktree Integration

Leverage existing `agent-shell-worktree.el` for isolated mode:

```elisp
(defun agent-shell-team--create-worktree (session-id role)
  "Create a worktree for a team agent, return path."
  (let* ((repo-root (agent-shell-worktree--git-repo-root))
         (wt-name (agent-shell-worktree--generate-name))
         (wt-path (file-name-concat repo-root
                                     ".agent-shell/worktrees"
                                     wt-name)))
    (make-directory (file-name-directory wt-path) t)
    (shell-command-to-string
     (format "git worktree add %s 2>&1"
             (shell-quote-argument wt-path)))
    wt-path))
```

The lead always works on the main tree. Devs and testers get worktrees.

---

## Phase 4: Role-Specific System Prompts

System prompts are injected via ACP's `:meta systemPrompt` parameter in `acp-make-session-new-request`, which appends to the agent's default system prompt at session creation time. This is cleaner than sending it as a first user message.

### Lead prompt
```
You are the LEAD agent in a team session {session-id}.
Your responsibilities:
- Review commits from dev agents when they notify you
- Merge approved worktree branches to the main branch
- Dispatch tester agents to validate merged code
- Assign new tasks to idle dev agents
- Handle task split requests from devs (see Sub-Tasking below)

Use sendNotification to communicate with other agents. Emacs routes messages
based on your role automatically. Use clear, structured notification titles:
- "Task Assignment" — assign work to a dev
- "Run Tests" — request testing
- "Status Update" — broadcast to all

When a dev signals completion, review their branch with:
  git diff main...{branch-name}
If approved: git merge {branch-name}
Then notify the tester.

## Sub-Tasking
You own ALL task decomposition. When you receive a broad task:
1. Break it into atomic, independently implementable subtasks
2. Assign each subtask to an idle dev via sendNotification:
   title: "Task Assignment", message: "Subtask: {description}"
3. If no idle devs are available, notify:
   title: "Need More Agents", message: "N subtasks pending, only M devs available"
4. Track which subtasks belong to the same parent task so you know when
   ALL subtasks are done before requesting a test run.
Devs never split tasks — they receive atomic units and execute them.
```

### Dev prompt
```
You are a DEV agent in a team session {session-id}.
Your working directory is a git worktree: {worktree-path}
Your responsibilities:
- Implement the assigned task
- Commit your work when done (git add + git commit)
- Signal completion by calling sendNotification with:
  title: "Task Complete"
  message: "dev:{worktree-name} finished: {brief description}"
- If you need logs or test output, request it via sendNotification:
  title: "Need Verification"
  message: "Please run X and report results"
- Wait for lead's feedback. Fix issues if requested.
- You receive atomic tasks from the lead. Do not split or delegate — just implement.
```

### Tester prompt (isolated mode — own worktree)
```
You are a TESTER agent in a team session {session-id}.
Mode: isolated (own worktree: {worktree-path})
Your responsibilities:
- Run the test suite on the merged code in your worktree
- Report results via sendNotification:
  title: "Test Results"
  message: "PASS" or "FAIL: {details}"
- If tests fail, provide detailed diagnostics
```

### Tester prompt (neighbor mode — shared directory)
```
You are a TESTER agent in a team session {session-id}.
Mode: neighbor (shared directory: {working-dir})
You are a READ-ONLY assistant. Do NOT modify source files.
Your responsibilities:
- Run commands to gather information: tests, linters, builds, curl, browser checks
- Tail log files, inspect running processes, check runtime state
- Grab screenshots or console output from browser if needed
- Report findings via sendNotification:
  title: "Log Report" / "Test Results" / "Runtime Check"
  message: "{detailed findings}"
- You are the team's eyes and hands for observation. Run, observe, report.
```

---

## Phase 5: ACP-Based Notification Routing

### Intercepting Tool Calls via ACP Events

Each team agent buffer gets a `tool-call-update` subscription. When the agent calls `sendNotification`, ACP mirrors the tool call to Emacs with full `rawInput` (title, message). Our subscription handler inspects it and routes.

```elisp
(defun agent-shell-team--setup-tool-call-watcher (buffer)
  "Subscribe to tool-call-update events on BUFFER for team routing."
  (agent-shell-subscribe-to
   :shell-buffer buffer
   :event 'tool-call-update
   :on-event #'agent-shell-team--on-tool-call-update))

(defun agent-shell-team--on-tool-call-update (event)
  "Handle tool-call-update EVENT. Route sendNotification calls between team agents."
  (let* ((data (map-elt event :data))
         (tool-call (cdr (assq :tool-call data)))
         (title (cdr (assq :title tool-call)))
         (raw-input (cdr (assq :raw-input tool-call)))
         (status (cdr (assq :status tool-call))))
    ;; Only intercept sendNotification tool calls that have completed
    (when (and (equal title "sendNotification")
               (equal status "completed")  ;; or check for appropriate status
               agent-shell-team--session-id)
      (let ((notif-title (cdr (assq 'title raw-input)))
            (notif-message (cdr (assq 'message raw-input))))
        (when (and notif-title notif-message)
          (agent-shell-team--route-from-acp
           agent-shell-team--session-id
           agent-shell-team--role
           notif-title
           notif-message))))))
```

### Routing Logic (Role-Based)

Instead of `targetRole` in the notification, Emacs infers the target from the **sender's role** and **notification title**:

```elisp
(defun agent-shell-team--infer-target (from-role title)
  "Infer target role based on FROM-ROLE and notification TITLE."
  (pcase from-role
    ("dev"
     (pcase title
       ("Task Complete" "lead")
       ("Need Verification" "tester")
       (_ "lead")))  ;; dev messages default to lead
    ("tester"
     (pcase title
       ("Test Results" "lead")
       ("Log Report" "lead")
       ("Runtime Check" "lead")
       (_ "lead")))  ;; tester messages default to lead
    ("lead"
     (pcase title
       ("Task Assignment" "dev")
       ("Run Tests" "tester")
       ("Status Update" "all")
       ("Need More Agents" "all")
       (_ "all")))))  ;; lead broadcasts by default
```

### Message Delivery via ACP

```elisp
(defun agent-shell-team--prompt-agent (buffer message)
  "Deliver MESSAGE to BUFFER's agent via ACP session/prompt."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let ((session-id (map-nested-elt (agent-shell--state) '(:session :id)))
                 (client (map-elt (agent-shell--state) :client)))
        (acp-send-request
         :client client
         :request (acp-make-session-prompt-request
                   :session-id session-id
                   :prompt message)
         :buffer buffer)))))
```

### Agent Status Detection

```elisp
(defun agent-shell-team--agent-status (buffer)
  "Determine if BUFFER's agent is idle, busy, or dead."
  (cond
   ((not (buffer-live-p buffer)) 'dead)
   ;; Check if agent-shell process is currently processing
   ;; (agent-shell exposes this via shell-maker's busy state)
   ((agent-shell-team--buffer-busy-p buffer) 'busy)
   (t 'idle)))
```

### Message Queue & Drain

When a busy agent becomes idle, Emacs drains its pending messages:

```elisp
(defvar agent-shell-team--message-queue (make-hash-table :test 'equal)
  "buffer → list of pending messages waiting for agent to become idle.")

(defun agent-shell-team--drain-queue (buffer)
  "Deliver any queued messages to BUFFER now that agent is idle.
Hooked into agent-shell's post-response or idle detection."
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
```

The drain hook uses a periodic timer to check for idle agents with pending messages.

### Sub-Tasking Flow (Lead-Driven)

The lead owns all task decomposition. No back-and-forth with devs.

```
  User / Task Queue          Lead                    Dev A     Dev B
        │                      │                       │         │
        ├─ "Build auth" ──────►│                       │         │
        │                      │ (decomposes)          │         │
        │                      │                       │         │
        │                      ├── "Task Assignment" ─►│         │
        │                      │   (subtask 1: models) │         │
        │                      │                       │         │
        │                      ├── "Task Assignment" ──────────►│
        │                      │   (subtask 2: routes) │         │
        │                      │                       │         │
        │                      │◄── "Task Complete" ───┤         │
        │                      │◄── "Task Complete" ─────────────┤
        │                      │ (all subtasks done → merge + test)
```

The lead tracks parent→subtask relationships. When all subtasks for a parent task are complete (all devs report "Task Complete"), the lead knows the full task is done and can proceed to merge + test.

### Routing Rules Summary

| From | Target (inferred) | Trigger (title) | Behavior |
|------|-------------------|-----------------|----------|
| dev | lead | "Task Complete" | Task done, needs review |
| dev | tester | "Need Verification" | Need logs/verification from neighbor tester |
| dev | lead | (default) | Any other dev notification goes to lead |
| tester | lead | "Test Results" | Test pass/fail report |
| tester | lead | "Log Report" / "Runtime Check" | Observation results |
| lead | dev | "Task Assignment" | Subtask assignment |
| lead | tester | "Run Tests" | Run tests on branch X |
| lead | all | "Status Update" / "Need More Agents" | Broadcast |
| lead | all | (default) | Any other lead notification broadcasts |

---

## Phase 6: Team Dashboard (Transient Menu)

`M-x agent-shell-team-status` or keybinding in team buffers:

```
┌─ Team Session: a1b2c3d4 ──────────────────────┐
│                                                 │
│  [lead]   *team:a1b2:lead:main*      ● active  │
│  [dev]    *team:a1b2:dev:focused-turing*  idle  │
│  [dev]    *team:a1b2:dev:clever-curie*  ● busy  │
│  [tester] *team:a1b2:tester:zen-euler*    idle  │
│                                                 │
│  [n] New agent  [s] Switch  [k] Kill  [l] Log  │
└─────────────────────────────────────────────────┘
```

Implemented as a `transient` menu for consistency with agent-shell's existing UI.

---

## File Changes Summary

| File | Action |
|------|--------|
| `modules/agent-shell-team.el` | **NEW** — Core team orchestration (pure Emacs Lisp, ACP-based) |
| `config.el` | **MODIFY** — Load agent-shell-team, add keybinding |

**No MCP server changes required.** All routing and orchestration happens in Emacs via ACP event subscriptions and ACP prompt delivery.

---

## What's Deferred

- **Neighbor mode file locking** — Neighbor agents are expected to be read-only (run commands, grab logs). No write locking enforced in v1. If two devs ever need to work in neighbor mode (same dir, both writing), that's a future concern.
- **Auto-spawn** — Lead automatically spawning devs/testers. Start with manual spawning, lead gives instructions.
- **Task queue** — Formal task assignment system. Start with lead prompting devs directly via `sendNotification`.
- **Cross-session communication** — Agents from different sessions talking to each other.

---

## Implementation Order

1. `agent-shell-team.el` — data model, registry, session UUID
2. `agent-shell-team` command — role prompt, mode prompt, worktree creation
3. Buffer naming + buffer-local vars
4. System prompts via ACP `:meta systemPrompt`
5. ACP tool-call-update subscription for notification interception
6. Routing logic + message delivery via ACP `session/prompt`
7. Message queue + drain timer
8. Team dashboard (transient menu)
9. Wire into `config.el` with keybinding
