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

## Architecture

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
   agent-shell-emacs-mcp (existing — handles ACP + MCP per buffer)
```

Communication between agents goes through Emacs:
- Agents use MCP `sendNotification` with a **target role** field
- Emacs routes the message to the right agent(s) based on target role + agent status
- If the target agent is busy, the message queues in the team log until the agent is idle

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
6. Inject system prompt with role instructions (via initial message or CLAUDE.md in worktree)

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

Each role gets instructions injected as the first message (or via a `.claude/CLAUDE.md` dropped into the worktree):

### Lead prompt
```
You are the LEAD agent in a team session {session-id}.
Your responsibilities:
- Review commits from dev agents when they notify you
- Merge approved worktree branches to the main branch
- Dispatch tester agents to validate merged code
- Assign new tasks to idle dev agents
- Handle task split requests from devs (see Sub-Tasking below)

All communication uses sendNotification with targetRole:
- To assign work to a dev:
  title: "Task Assignment", message: "...", targetRole: "dev"
- To request testing:
  title: "Run Tests", message: "Test branch {X} merged to main", targetRole: "tester"
- To report status to user:
  title: "Status Update", message: "...", targetRole: "all"

When a dev signals completion, review their branch with:
  git diff main...{branch-name}
If approved: git merge {branch-name}
Then notify the tester.

## Sub-Tasking
You own ALL task decomposition. When you receive a broad task:
1. Break it into atomic, independently implementable subtasks
2. Assign each subtask to an idle dev:
   title: "Task Assignment", message: "Subtask: {description}", targetRole: "dev"
3. If no idle devs are available, ask the user to spawn more:
   title: "Need More Agents", message: "N subtasks pending, only M devs available", targetRole: "all"
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
  targetRole: "lead"
- If you need logs or test output, request it from a tester:
  title: "Need Verification"
  message: "Please run X and report results"
  targetRole: "tester"
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
  targetRole: "lead"
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
  targetRole: "dev" (if helping a dev) or "lead" (if reporting to lead)
- You are the team's eyes and hands for observation. Run, observe, report.
```

---

## Phase 5: Notification Routing & Emacs Orchestration

### Extended `sendNotification` Schema

Every team notification includes a **target role**:

```
sendNotification({
  title: "Task Complete",
  message: "Implemented auth module, all commits pushed",
  targetRole: "lead"       // who should receive this
})
```

Valid `targetRole` values: `"lead"`, `"dev"`, `"tester"`, `"all"` (broadcast).

The MCP tool handler detects team context from the calling buffer's buffer-local vars (`agent-shell-team--session-id`, `agent-shell-team--role`) and routes accordingly.

### Emacs Orchestration Logic

Emacs acts as the message router. When a `sendNotification` with `targetRole` arrives:

```elisp
(defun agent-shell-team--route-notification (session-id from-role target-role title message)
  "Route notification to the appropriate agent(s) based on target role and status."
  ;; 1. Always log to shared team buffer
  (agent-shell-team--log session-id
    (format "[%s → %s] %s: %s" from-role target-role title message))

  ;; 2. Find target agent(s)
  (let ((targets (if (equal target-role "all")
                     (agent-shell-team--get-session-agents session-id)
                   (agent-shell-team--get-agents-by-role session-id target-role))))

    ;; 3. For each target: deliver or queue based on status
    (dolist (agent targets)
      (let ((buf (alist-get 'buffer agent))
            (status (agent-shell-team--agent-status buf)))
        (pcase status
          ('idle
           ;; Agent is waiting — inject message directly into their comint input
           (agent-shell-team--prompt-agent buf
             (format "Message from %s: %s — %s" from-role title message)))
          ('busy
           ;; Agent is mid-task — queue for delivery when they become idle
           (agent-shell-team--queue-message session-id buf
             (list :from from-role :title title :message message)))
          ('dead
           ;; Buffer killed — log warning, skip
           (agent-shell-team--log session-id
             (format "WARNING: target %s buffer is dead, message dropped" target-role))))))))
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

The drain hook attaches to `shell-maker-output-filter-functions` or agent-shell's section completion hook to detect when the agent finishes its current task.

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

| From | Target | Behavior |
|------|--------|----------|
| From | Target | Behavior |
| dev | lead | Task done, needs review |
| dev | tester | Need logs/verification from neighbor tester |
| tester | dev | Test results, logs, runtime observations |
| tester | lead | Test pass/fail report |
| lead | dev | Task assignment, subtask assignment, feedback |
| lead | tester | Run tests on branch X |
| lead | all | Status update, need more agents |
| any | all | Broadcast to all agents in session |

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
| `modules/agent-shell-team.el` | **NEW** — Core team orchestration |
| `modules/agent-shell-emacs-mcp.el` | **MODIFY** — Accept team context (session-id, role, worktree) |
| `config.el` | **MODIFY** — Load agent-shell-team, add keybinding |

MCP tools require a small extension — `sendNotification` gains an optional `targetRole` parameter. The MCP server (Node.js) passes `targetRole` through to Emacs, where the elisp orchestration layer routes it.

| File | Action |
|------|--------|
| `claude-emacs-mcp-server/src/tools/notification-tools.ts` | **MODIFY** — Add `targetRole` param to `sendNotification` |
| `modules/claude-code-emacs/claude-code-mcp-tools.el` | **MODIFY** — Handle `targetRole` in notification handler, delegate to team router |

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
4. Role-specific system prompts (injected as first message)
5. Notification routing to team log buffer
6. Team dashboard (transient menu)
7. Wire into `config.el` with keybinding
