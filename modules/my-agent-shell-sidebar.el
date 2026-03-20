;;; my-agent-shell-sidebar.el --- Team sidebar for agent-shell lead buffer -*- lexical-binding: t; -*-

;; Author: Igor Rizhyi
;; Keywords: tools, ai, team

;;; Commentary:

;; Buffer-specific sidebar that auto-shows/hides when switching to/from
;; the lead agent shell buffer.  Displays team status with keyboard
;; navigation and an inline prompt mode.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'url)

(defvar url-request-method)
(defvar url-request-extra-headers)
(defvar url-request-data)
(defvar json-object-type)
(defvar json-key-type)

(declare-function shell-maker-submit "shell-maker")
(declare-function evil-define-key* "evil-core")
(declare-function evil-set-initial-state "evil-core")
(declare-function evil-emacs-state "evil-states")
(declare-function evil-normal-state "evil-states")
(defvar agent-shell-team--session-id)
(defvar agent-shell-team--sessions)
(declare-function agent-shell-team--agent-status "agent-shell-team")
(declare-function agent-shell-team--short-session-id "agent-shell-team")
(defvar agent-shell-team--task-queue)
(defvar agent-shell-team--message-queue)
(defvar agent-shell-team--request-to-buffer)
(defvar agent-shell-team--task-groups)
(defvar agent-shell-team--request-to-group)
(declare-function agent-shell-team--load-all-sessions "agent-shell-team")
(declare-function agent-shell-team--load-tasks "agent-shell-team")
(declare-function agent-shell-team--get-lead "agent-shell-team")
(declare-function agent-shell-team--queue-message "agent-shell-team")
(declare-function agent-shell-team--start-drain-timer "agent-shell-team")
(defvar agent-shell--state)
(defvar agent-shell-team--role)
(declare-function agent-shell--format-number-compact "agent-shell-usage")
(declare-function agent-shell--update-usage-from-notification "agent-shell-usage")

;;; ---- Constants & Buffer Name ------------------------------------------------

(defconst my/team-sidebar-buffer-name " *team-sidebar*"
  "Space-prefixed to hide from ibuffer.")

(defconst my/team-sidebar-width 40
  "Width of the sidebar window in columns.")

;;; ---- Faces ------------------------------------------------------------------

(defface my/team-sidebar-session-face
  '((t :weight bold :height 1.05))
  "Face for session headers in the team sidebar.")

(defface my/team-sidebar-role-face
  '((t :weight bold))
  "Face for agent role labels.")

(defface my/team-sidebar-status-idle
  '((t :foreground "#33ff33"))
  "Face for idle status.")

(defface my/team-sidebar-status-busy
  '((t :foreground "#ffb000"))
  "Face for busy status.")

(defface my/team-sidebar-status-init
  '((t :foreground "#cc8800"))
  "Face for initializing status.")

(defface my/team-sidebar-status-pending
  '((t :foreground "#88aaff"))
  "Face for pending (user typing) status.")

(defface my/team-sidebar-status-dead
  '((t :foreground "#ff3333"))
  "Face for dead status.")

(defface my/team-sidebar-history-header
  '((t :weight bold :foreground "#806000"))
  "Face for history section header.")

(defface my/team-sidebar-history-session
  '((t :foreground "#705500"))
  "Face for history session headers.")

(defface my/team-sidebar-history-finished
  '((t :foreground "#33ff33"))
  "Face for finished task indicator.")

(defface my/team-sidebar-history-blocked
  '((t :foreground "#ff3333"))
  "Face for blocked task indicator.")

(defface my/team-sidebar-history-assigned
  '((t :foreground "#ffb000"))
  "Face for assigned/in-progress task indicator.")

(defface my/team-sidebar-history-pending
  '((t :foreground "#cc8800"))
  "Face for pending task indicator.")

(defface my/team-sidebar-quota-ok
  '((t :foreground "#33ff33"))
  "Face for quota bar when utilization < 50%.")

(defface my/team-sidebar-quota-warn
  '((t :foreground "#ffb000"))
  "Face for quota bar when utilization 50-80%.")

(defface my/team-sidebar-quota-critical
  '((t :foreground "#ff3333"))
  "Face for quota bar when utilization > 80%.")

(defface my/team-sidebar-quota-empty
  '((t :foreground "#555555"))
  "Face for unfilled portion of quota bar.")

(defface my/team-sidebar-quota-label
  '((t :foreground "#cc8800"))
  "Face for quota label text.")

(defface my/team-sidebar-foreign-face
  '((t :foreground "#8888bb" :italic t))
  "Face for foreign (namespace peer) agent entries.")

(defface my/team-sidebar-quota-reset
  '((t :foreground "#806000" :slant italic))
  "Face for quota reset time text.")

;;; ---- Quota State (Global) --------------------------------------------------

(defvar my/team-sidebar--quota-5h-util nil
  "Float 0-1 for 5-hour utilization, or nil if unknown.")
(defvar my/team-sidebar--quota-7d-util nil
  "Float 0-1 for 7-day utilization, or nil if unknown.")
(defvar my/team-sidebar--quota-5h-reset nil
  "Unix timestamp (seconds) for 5-hour reset, or nil.")
(defvar my/team-sidebar--quota-7d-reset nil
  "Unix timestamp (seconds) for 7-day reset, or nil.")
(defvar my/team-sidebar--quota-error nil
  "String error message if quota fetch failed, or nil.")
(defvar my/team-sidebar--quota-timer nil
  "30-second timer for quota refresh.")
(defvar my/team-sidebar--quota-fetching nil
  "Non-nil when a quota fetch is in progress.")
(defvar my/team-sidebar--quota-fetch-started nil
  "Timestamp when current fetch began, for timeout detection.")

(defvar my/team-sidebar--quota-retry-p nil
  "Non-nil when a 401 retry is in progress. Prevents infinite retry loops.")

(defvar my/team-sidebar--quota-last-token nil
  "The access token used for the most recent quota fetch, for 401 comparison.")

(defconst my/team-sidebar--quota-cache-file
  (expand-file-name "~/.claude/.quota-cache.json")
  "Shared cache file for quota data across Emacs instances.")

(defconst my/team-sidebar--quota-cache-ttl 25
  "Cache TTL in seconds. Slightly less than the 30s timer interval
to avoid edge cases where cache expires between check and next tick.")

;;; ---- Foreign Agents State (Namespace) --------------------------------------

(defvar my/team-sidebar--foreign-agents nil
  "Alist of (peer-pid . agent-list) for namespace peers.
Each agent-list contains alists with keys: role, worktree-name, status, hostname.")

(defvar my/team-sidebar--namespace-active nil
  "Non-nil when a namespace is active and foreign agents should be displayed.")

;;; ---- Quota Cache -----------------------------------------------------------

(defun my/team-sidebar--quota-cache-read ()
  "Read quota cache file. Return alist if fresh, nil if stale/missing."
  (condition-case nil
      (when (file-exists-p my/team-sidebar--quota-cache-file)
        (let* ((json-object-type 'alist)
               (json-key-type 'symbol)
               (data (json-read-file my/team-sidebar--quota-cache-file))
               (fetched-at (alist-get 'fetched_at data)))
          (when (and fetched-at
                     (< (- (float-time) fetched-at)
                        my/team-sidebar--quota-cache-ttl))
            data)))
    (error nil)))

(defun my/team-sidebar--quota-cache-write (util-5h util-7d reset-5h reset-7d)
  "Write quota data to shared cache file atomically.
UTIL-5H, UTIL-7D are floats; RESET-5H, RESET-7D are unix timestamps."
  (condition-case nil
      (let* ((data (json-encode
                    `((fetched_at . ,(float-time))
                      (util_5h . ,util-5h)
                      (util_7d . ,util-7d)
                      (reset_5h . ,reset-5h)
                      (reset_7d . ,reset-7d))))
             (tmp-file (concat my/team-sidebar--quota-cache-file ".tmp")))
        (with-temp-file tmp-file
          (insert data))
        (rename-file tmp-file my/team-sidebar--quota-cache-file t))
    (error nil)))

(defun my/team-sidebar--quota-apply-cache (data)
  "Apply cached quota DATA (alist) to buffer-local state and re-render."
  (let ((u5 (alist-get 'util_5h data))
        (u7 (alist-get 'util_7d data))
        (r5 (alist-get 'reset_5h data))
        (r7 (alist-get 'reset_7d data)))
    (when u5 (setq my/team-sidebar--quota-5h-util u5))
    (when u7 (setq my/team-sidebar--quota-7d-util u7))
    (when r5 (setq my/team-sidebar--quota-5h-reset r5))
    (when r7 (setq my/team-sidebar--quota-7d-reset r7))
    (setq my/team-sidebar--quota-error nil))
  (my/team-sidebar--render))

;;; ---- OAuth Token Refresh ---------------------------------------------------

(cl-defun my/team-sidebar--refresh-token (callback)
  "Refresh the OAuth access token asynchronously.
CALLBACK is called with the new access token on success, or nil on failure.
Reads the refresh token from ~/.claude/.credentials.json, posts to the
OAuth token endpoint, and atomically updates the credentials file."
  (condition-case err
      (let* ((cred-file (expand-file-name "~/.claude/.credentials.json"))
             (json-object-type 'alist)
             (json-key-type 'symbol)
             (creds (json-read-file cred-file))
             (oauth (alist-get 'claudeAiOauth creds))
             (refresh-token (alist-get 'refreshToken oauth)))
        (unless refresh-token
          (funcall callback nil)
          (cl-return-from my/team-sidebar--refresh-token nil))
        (let ((url-request-method "POST")
              (url-request-extra-headers
               '(("Content-Type" . "application/json")
                 ("Authorization" . "Bearer none")))
              (url-request-data
               (encode-coding-string
                (json-encode
                 `((grant_type . "refresh_token")
                   (refresh_token . ,refresh-token)
                   (client_id . "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
                   (scope . "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload")))
                'utf-8)))
          (url-retrieve
           "https://platform.claude.com/v1/oauth/token"
           (lambda (status)
             (my/team-sidebar--refresh-token-callback status callback))
           nil t t)))
    (error
     (message "OAuth refresh error: %s" err)
     (funcall callback nil))))

(defun my/team-sidebar--refresh-token-callback (status callback)
  "Handle OAuth token refresh response.
STATUS is the url-retrieve status plist. CALLBACK receives the new token or nil."
  (condition-case err
      (if (plist-get status :error)
          (progn
            (message "OAuth refresh failed: %s" (plist-get status :error))
            (funcall callback nil))
        (goto-char (point-min))
        (re-search-forward "\n\n" nil t)
        (let* ((json-object-type 'alist)
               (json-key-type 'symbol)
               (resp (json-read))
               (new-access (alist-get 'access_token resp))
               (new-refresh (alist-get 'refresh_token resp))
               (expires-in (alist-get 'expires_in resp)))
          (if (not new-access)
              (progn
                (message "OAuth refresh: no access_token in response")
                (funcall callback nil))
            (let* ((new-expires-at (floor (* (+ (float-time) expires-in) 1000)))
                   (cred-file (expand-file-name "~/.claude/.credentials.json"))
                   (json-object-type 'alist)
                   (json-key-type 'symbol)
                   (creds (json-read-file cred-file))
                   (oauth (alist-get 'claudeAiOauth creds)))
              (setf (alist-get 'accessToken oauth) new-access)
              (when new-refresh
                (setf (alist-get 'refreshToken oauth) new-refresh))
              (setf (alist-get 'expiresAt oauth) new-expires-at)
              (setf (alist-get 'claudeAiOauth creds) oauth)
              (let ((tmp-file (concat cred-file ".tmp")))
                (with-temp-file tmp-file
                  (insert (json-encode creds)))
                (rename-file tmp-file cred-file t))
              (funcall callback new-access)))))
    (error
     (message "OAuth refresh parse error: %s" err)
     (funcall callback nil)))
  (when (buffer-live-p (current-buffer))
    (kill-buffer (current-buffer))))

;;; ---- Quota API -------------------------------------------------------------

(defun my/team-sidebar--quota-read-token ()
  "Read OAuth access token from ~/.claude/.credentials.json.
Returns the token string if valid and not near-expiry (>5 min remaining),
or nil if unavailable, expired, or within 5 minutes of expiry."
  (condition-case nil
      (let* ((cred-file (expand-file-name "~/.claude/.credentials.json"))
             (json-object-type 'alist)
             (json-key-type 'symbol)
             (creds (json-read-file cred-file))
             (oauth (alist-get 'claudeAiOauth creds))
             (token (alist-get 'accessToken oauth))
             (expires-at (alist-get 'expiresAt oauth)))
        (if (and expires-at (> (+ (float-time) 300) (/ expires-at 1000.0)))
            (progn
              (setq my/team-sidebar--quota-error "Token expired")
              nil)
          token))
    (error nil)))

(defun my/team-sidebar--network-available-p ()
  "Return non-nil if any non-loopback network interface is up.
Lightweight check to avoid doomed fetches after suspend/resume."
  (cl-some (lambda (iface)
             (not (member (car iface) '("lo" "lo0"))))
           (network-interface-list)))

(cl-defun my/team-sidebar--quota-fetch ()
  "Fetch quota utilization, using shared file cache when fresh.
Only makes an API call if the cache is stale or missing, so multiple
Emacs instances share a single fetch per cycle."
  ;; Skip fetch when network is unavailable (e.g. right after suspend/resume)
  (unless (my/team-sidebar--network-available-p)
    (cl-return-from my/team-sidebar--quota-fetch nil))
  ;; Timeout recovery: if a fetch has been running > 15s, force-clear the guard
  (when (and my/team-sidebar--quota-fetching
             my/team-sidebar--quota-fetch-started
             (> (- (float-time) my/team-sidebar--quota-fetch-started) 15))
    (setq my/team-sidebar--quota-fetching nil
          my/team-sidebar--quota-fetch-started nil
          my/team-sidebar--quota-retry-p nil
          my/team-sidebar--quota-error "Fetch timeout"))
  (when my/team-sidebar--quota-fetching
    (cl-return-from my/team-sidebar--quota-fetch nil))
  ;; Check shared cache first
  (let ((cached (my/team-sidebar--quota-cache-read)))
    (when cached
      (my/team-sidebar--quota-apply-cache cached)
      (cl-return-from my/team-sidebar--quota-fetch nil)))
  ;; Cache miss — do the actual API call
  (let ((token (my/team-sidebar--quota-read-token)))
    (if token
        (my/team-sidebar--quota-do-fetch token)
      ;; Token expired or near-expiry — refresh then fetch
      (my/team-sidebar--refresh-token
       (lambda (new-token)
         (if new-token
             (my/team-sidebar--quota-do-fetch new-token)
           (setq my/team-sidebar--quota-error "Token refresh failed"
                 my/team-sidebar--quota-fetching nil
                 my/team-sidebar--quota-fetch-started nil)))))))

(defun my/team-sidebar--quota-do-fetch (token)
  "Perform the actual quota API call using TOKEN.
Sets fetching guards and stores TOKEN for 401 comparison."
  (condition-case err
      (progn
        (setq my/team-sidebar--quota-fetching t
              my/team-sidebar--quota-fetch-started (float-time)
              my/team-sidebar--quota-last-token token)
        (let ((url-request-method "POST")
              (url-request-extra-headers
               `(("x-api-key" . ,token)
                 ("Authorization" . ,(concat "Bearer " token))
                 ("anthropic-version" . "2023-06-01")
                 ("content-type" . "application/json")))
              (url-request-data
               (encode-coding-string
                (json-encode '((model . "claude-haiku-4-5-20251001")
                               (max_tokens . 1)
                               (messages . [((role . "user")
                                             (content . "q"))])))
                'utf-8)))
          (url-retrieve
           "https://api.anthropic.com/v1/messages"
           #'my/team-sidebar--quota-callback
           nil t t)))
    (error
     (setq my/team-sidebar--quota-fetching nil
           my/team-sidebar--quota-fetch-started nil
           my/team-sidebar--quota-error (format "%s" err)))))

(defun my/team-sidebar--quota-get-http-status ()
  "Extract HTTP status code from the current url-retrieve response buffer.
Returns the status as an integer, or nil if not found."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^HTTP/[0-9.]+ \\([0-9]+\\)" nil t)
      (string-to-number (match-string 1)))))

(defun my/team-sidebar--quota-handle-401 ()
  "Handle 401 response by refreshing credentials and retrying.
Returns non-nil if a retry was initiated, nil otherwise."
  (when (buffer-live-p (current-buffer))
    (kill-buffer (current-buffer)))
  (if my/team-sidebar--quota-retry-p
      ;; Already retried once — give up
      (progn
        (setq my/team-sidebar--quota-fetching nil
              my/team-sidebar--quota-fetch-started nil
              my/team-sidebar--quota-retry-p nil
              my/team-sidebar--quota-error "Auth failed after retry")
        (my/team-sidebar--render)
        nil)
    (setq my/team-sidebar--quota-retry-p t)
    ;; Re-read credentials in case CLI already refreshed
    (let ((fresh-token (my/team-sidebar--quota-read-token)))
      (if (and fresh-token
               (not (equal fresh-token my/team-sidebar--quota-last-token)))
          ;; CLI refreshed the token — retry immediately
          (my/team-sidebar--quota-do-fetch fresh-token)
        ;; Same token or nil — do our own refresh
        (my/team-sidebar--refresh-token
         (lambda (new-token)
           (if new-token
               (my/team-sidebar--quota-do-fetch new-token)
             (setq my/team-sidebar--quota-fetching nil
                   my/team-sidebar--quota-fetch-started nil
                   my/team-sidebar--quota-retry-p nil
                   my/team-sidebar--quota-error "Token refresh failed")
             (my/team-sidebar--render))))))
    t))

(cl-defun my/team-sidebar--quota-callback (status)
  "Handle quota API response. STATUS is the url-retrieve status plist."
  (condition-case nil
      (if (plist-get status :error)
          (let ((http-status (my/team-sidebar--quota-get-http-status)))
            (if (eq http-status 401)
                (when (my/team-sidebar--quota-handle-401)
                  (cl-return-from my/team-sidebar--quota-callback nil))
              (setq my/team-sidebar--quota-fetching nil
                    my/team-sidebar--quota-fetch-started nil
                    my/team-sidebar--quota-error "API error")))
        ;; Check HTTP status even when url-retrieve doesn't report :error
        (let ((http-status (my/team-sidebar--quota-get-http-status)))
          (when (eq http-status 401)
            (when (my/team-sidebar--quota-handle-401)
              (cl-return-from my/team-sidebar--quota-callback nil))))
        ;; Parse headers — we're in the HTTP response buffer
        (let ((util-5h (mail-fetch-field "anthropic-ratelimit-unified-5h-utilization"))
              (util-7d (mail-fetch-field "anthropic-ratelimit-unified-7d-utilization"))
              (reset-5h (mail-fetch-field "anthropic-ratelimit-unified-5h-reset"))
              (reset-7d (mail-fetch-field "anthropic-ratelimit-unified-7d-reset")))
          (when util-5h
            (setq my/team-sidebar--quota-5h-util (string-to-number util-5h)))
          (when util-7d
            (setq my/team-sidebar--quota-7d-util (string-to-number util-7d)))
          (when reset-5h
            (setq my/team-sidebar--quota-5h-reset (string-to-number reset-5h)))
          (when reset-7d
            (setq my/team-sidebar--quota-7d-reset (string-to-number reset-7d)))
          (setq my/team-sidebar--quota-fetching nil
                my/team-sidebar--quota-fetch-started nil
                my/team-sidebar--quota-error nil
                my/team-sidebar--quota-retry-p nil)
          ;; Write to shared cache so other instances can skip the API call
          (my/team-sidebar--quota-cache-write
           my/team-sidebar--quota-5h-util my/team-sidebar--quota-7d-util
           my/team-sidebar--quota-5h-reset my/team-sidebar--quota-7d-reset)))
    (error (setq my/team-sidebar--quota-fetching nil
                 my/team-sidebar--quota-fetch-started nil
                 my/team-sidebar--quota-error "Parse error")))
  (when (buffer-live-p (current-buffer))
    (kill-buffer (current-buffer)))
  ;; Trigger sidebar re-render
  (my/team-sidebar--render))

(defun my/team-sidebar--quota-format-reset (timestamp)
  "Format TIMESTAMP (unix seconds) as a human-readable reset time."
  (when timestamp
    (let* ((reset-time (seconds-to-time timestamp))
           (now (current-time))
           (diff (float-time (time-subtract reset-time now))))
      (if (< diff (* 24 3600))
          (format-time-string "Resets %-l:%M%P" reset-time)
        (format-time-string "Resets %b %-d, %-l%P" reset-time)))))

(defun my/team-sidebar--quota-bar-face (util)
  "Return the appropriate face for UTIL (0-1 float)."
  (cond
   ((> util 0.8) 'my/team-sidebar-quota-critical)
   ((> util 0.5) 'my/team-sidebar-quota-warn)
   (t 'my/team-sidebar-quota-ok)))

(defun my/team-sidebar--quota-render-bar (label util reset-ts)
  "Insert a quota progress bar line for LABEL with UTIL and RESET-TS."
  (let* ((bar-width 20)
         (filled (round (* util bar-width)))
         (empty (- bar-width filled))
         (pct (round (* util 100)))
         (face (my/team-sidebar--quota-bar-face util))
         (filled-str (propertize (make-string filled ?█) 'face face))
         (empty-str (propertize (make-string empty ?░) 'face 'my/team-sidebar-quota-empty))
         (reset-str (my/team-sidebar--quota-format-reset reset-ts)))
    (insert (propertize (format "%-3s " label) 'face 'my/team-sidebar-quota-label)
            filled-str empty-str
            (propertize (format " %d%%" pct) 'face face)
            "\n")
    (when reset-str
      (insert "    " (propertize reset-str 'face 'my/team-sidebar-quota-reset) "\n"))))

(defun my/team-sidebar--insert-quota ()
  "Insert quota progress bars at point. Returns non-nil if anything was inserted."
  (cond
   ;; Error state
   (my/team-sidebar--quota-error
    (insert " " (propertize my/team-sidebar--quota-error
                             'face 'my/team-sidebar-quota-reset)
            "\n\n")
    t)
   ;; Data available
   ((and my/team-sidebar--quota-5h-util my/team-sidebar--quota-7d-util)
    (my/team-sidebar--quota-render-bar
     "5h" my/team-sidebar--quota-5h-util my/team-sidebar--quota-5h-reset)
    (my/team-sidebar--quota-render-bar
     "7d" my/team-sidebar--quota-7d-util my/team-sidebar--quota-7d-reset)
    (insert "\n")
    t)
   ;; Loading
   (t
    (insert " " (propertize "Loading quota..." 'face 'my/team-sidebar-quota-reset) "\n\n")
    t)))

;;; ---- Context Usage Bar -----------------------------------------------------

(defun my/team-sidebar--lead-context-usage ()
  "Return (USED . SIZE) for the lead agent's context, or nil."
  (when-let* ((session-id (and (boundp 'agent-shell-team--session-id)
                               agent-shell-team--session-id))
              (lead-buf (my/team-sidebar--find-lead-buffer session-id))
              ((buffer-live-p (get-buffer lead-buf))))
    (with-current-buffer lead-buf
      (when (and (boundp 'agent-shell--state) agent-shell--state)
        (let* ((usage (map-elt agent-shell--state :usage))
               (used (or (map-elt usage :context-used) 0))
               (size (or (map-elt usage :context-size) 0)))
          (when (> size 0)
            (cons used size)))))))

(defun my/team-sidebar--insert-context-bar ()
  "Insert context usage bar. Returns non-nil if inserted."
  (when-let* ((ctx (my/team-sidebar--lead-context-usage))
              (used (car ctx))
              (size (cdr ctx)))
    (let* ((util (/ (float used) size))
           (bar-width 20)
           (filled (round (* util bar-width)))
           (empty (- bar-width filled))
           (pct (round (* util 100)))
           (face (cond ((>= pct 85) 'my/team-sidebar-quota-critical)
                       ((>= pct 60) 'my/team-sidebar-quota-warn)
                       (t 'my/team-sidebar-quota-ok)))
           (filled-str (propertize (make-string filled ?█) 'face face))
           (empty-str (propertize (make-string empty ?░) 'face 'my/team-sidebar-quota-empty))
           (label (format "%s/%s"
                          (agent-shell--format-number-compact used)
                          (agent-shell--format-number-compact size))))
      (insert (propertize "ctx " 'face 'my/team-sidebar-quota-label)
              filled-str empty-str
              (propertize (format " %d%%" pct) 'face face)
              "  " (propertize label 'face 'font-lock-comment-face)
              "\n")
      t)))

;;; ---- Quota Timer -----------------------------------------------------------

(defun my/team-sidebar--quota-ensure-timer ()
  "Start the 30-second quota refresh timer if not already running."
  (unless (and my/team-sidebar--quota-timer
               (timerp my/team-sidebar--quota-timer)
               (memq my/team-sidebar--quota-timer timer-list))
    (my/team-sidebar--quota-fetch)  ; immediate first fetch
    (setq my/team-sidebar--quota-timer
          (run-with-timer 30 30 #'my/team-sidebar--quota-timer-tick))))

(defun my/team-sidebar--quota-stop-timer ()
  "Stop the quota refresh timer."
  (when (timerp my/team-sidebar--quota-timer)
    (cancel-timer my/team-sidebar--quota-timer)
    (setq my/team-sidebar--quota-timer nil)))

(defun my/team-sidebar--quota-timer-tick ()
  "Timer callback: fetch quota if sidebar buffer exists."
  (if (get-buffer my/team-sidebar-buffer-name)
      (my/team-sidebar--quota-fetch)
    (my/team-sidebar--quota-stop-timer)))

;;; ---- Sidebar Buffer Local State ---------------------------------------------

(defvar-local my/team-sidebar--refresh-timer nil
  "Timer for periodic refresh.")

(defvar-local my/team-sidebar--history-cache nil
  "Cached result of `agent-shell-team--load-all-sessions'.")

(defvar-local my/team-sidebar--history-cache-time 0
  "Time when history cache was last updated.")

(defvar-local my/team-sidebar--expanded-sessions nil
  "List of session IDs whose history sections are expanded.")

(defvar-local my/team-sidebar--manually-collapsed nil
  "List of session IDs the user has manually collapsed.")

;;; ---- Utility ----------------------------------------------------------------

(defun my/team-sidebar--lead-buffer-p (buf)
  "Return non-nil if BUF is a team lead buffer."
  (and (buffer-live-p buf)
       (string-match-p "\\*team:[a-z0-9]\\{4\\}:lead:" (buffer-name buf))))

(defun my/team-sidebar--any-lead-visible-p ()
  "Return the first visible lead buffer in the selected frame, or nil."
  (cl-loop for win in (window-list nil 'no-minibuf)
           for buf = (window-buffer win)
           when (my/team-sidebar--lead-buffer-p buf)
           return buf))

(defun my/team-sidebar--any-team-buffer-visible-p ()
  "Return the first visible team buffer in the selected frame, or nil."
  (cl-loop for win in (window-list nil 'no-minibuf)
           for buf = (window-buffer win)
           when (or (and (buffer-live-p buf)
                        (string-match-p "\\*team:[a-z0-9]\\{4\\}:" (buffer-name buf)))
                   (equal buf (get-buffer my/team-sidebar-buffer-name)))
           return buf))

(defun my/team-sidebar--find-lead-buffer (session-id)
  "Find the lead buffer for SESSION-ID."
  (when (and session-id (boundp 'agent-shell-team--sessions))
    (let ((agents (gethash session-id agent-shell-team--sessions)))
      (cl-loop for agent in agents
               when (equal (alist-get 'role agent) "lead")
               return (alist-get 'buffer agent)))))

;;; ---- History Helpers --------------------------------------------------------

(defun my/team-sidebar--get-history (&optional force)
  "Return cached history sessions, refreshing if stale or FORCE is non-nil."
  (when (fboundp 'agent-shell-team--load-all-sessions)
    (let ((now (float-time)))
      (when (or force
                (null my/team-sidebar--history-cache)
                (> (- now my/team-sidebar--history-cache-time) 30))
        (setq my/team-sidebar--history-cache
              (agent-shell-team--load-all-sessions)
              my/team-sidebar--history-cache-time now)))
    my/team-sidebar--history-cache))

(defun my/team-sidebar--task-status-indicator (task)
  "Return a status indicator string for TASK plist."
  (let ((status (plist-get task :status)))
    (pcase status
      ("finished"  (propertize "✓" 'face 'my/team-sidebar-history-finished))
      ("blocked"   (propertize "✗" 'face 'my/team-sidebar-history-blocked))
      ((or "assigned" "in-progress")
       (propertize "●" 'face 'my/team-sidebar-history-assigned))
      (_           (propertize "○" 'face 'my/team-sidebar-history-pending)))))

(defun my/team-sidebar--task-label (task)
  "Return a short label for TASK from :request-id or :message."
  (or (plist-get task :request-id)
      (let ((msg (or (plist-get task :message) "")))
        (truncate-string-to-width msg 25 nil nil "…"))))

(defun my/team-sidebar--session-date (tasks)
  "Extract a date string from TASKS list using :created-at of first task."
  (let ((ts (cl-loop for task in tasks
                     for ca = (plist-get task :created-at)
                     when ca minimize ca)))
    (if ts
        (format-time-string "%Y-%m-%d" (seconds-to-time ts))
      "unknown")))

(defun my/team-sidebar--insert-history ()
  "Insert history section with collapsible sessions."
  (let ((sessions (my/team-sidebar--get-history)))
    (when sessions
      (insert (propertize "── History ──────────────"
                          'face 'my/team-sidebar-history-header)
              "\n")
      ;; Auto-expand top 3 sessions unless manually collapsed
      (let ((top-3-sids (mapcar #'car (seq-take sessions 3))))
        (dolist (sid top-3-sids)
          (when (and (not (member sid my/team-sidebar--expanded-sessions))
                     (not (member sid my/team-sidebar--manually-collapsed)))
            (push sid my/team-sidebar--expanded-sessions))))
      (let ((expand-count 0))
        (dolist (entry sessions)
          (let* ((sid (car entry))
                 (tasks (cdr entry))
                 (short-id (if (> (length sid) 8) (substring sid 0 8) sid))
                 (date (my/team-sidebar--session-date tasks))
                 (expanded (or (and (< expand-count 3)
                                    (not (memq 'initialized
                                               my/team-sidebar--expanded-sessions)))
                               (member sid my/team-sidebar--expanded-sessions)))
                 (toggle-char (if expanded "▾" "▸"))
                 (inv-sym (intern (format "session-%s" sid)))
                 (header-start (point)))
            ;; Session header line
            (insert (propertize (format "%s %s (%s)" toggle-char date short-id)
                                'face 'my/team-sidebar-history-session)
                    "\n")
            (put-text-property header-start (1- (point))
                               'my/sidebar-session sid)
            ;; Task lines (with invisible property for collapsing)
            (let ((tasks-start (point)))
              (dolist (task tasks)
                ;; Reconstruct :report-path for history tasks
                (let* ((root (or (and (fboundp 'projectile-project-root) (projectile-project-root))
                                 default-directory))
                       (report-path (expand-file-name
                                     (concat (plist-get task :request-id) ".md")
                                     (expand-file-name
                                      (format ".agent-shell/reports/%s/" sid)
                                      root))))
                  (when (file-exists-p report-path)
                    (setq task (plist-put (copy-sequence task) :report-path report-path))))
                (let ((indicator (my/team-sidebar--task-status-indicator task))
                      (label (my/team-sidebar--task-label task))
                      (role (or (plist-get task :role) "?"))
                      (task-line-start (point)))
                  (insert (format "  %s %s [%s]\n" indicator label role))
                  (put-text-property task-line-start (1- (point))
                                     'my/sidebar-task task)))
              ;; Apply invisible property to task lines
              (put-text-property tasks-start (point) 'invisible inv-sym)
              ;; Set up visibility
              (if expanded
                  (remove-from-invisibility-spec inv-sym)
                (add-to-invisibility-spec inv-sym)))
            ;; Auto-expand the first 3 sessions on initial render
            (when (and (< expand-count 3)
                       (not (memq 'initialized my/team-sidebar--expanded-sessions)))
              (unless (member sid my/team-sidebar--expanded-sessions)
                (push sid my/team-sidebar--expanded-sessions))
              (cl-incf expand-count))))
        ;; Mark as initialized so auto-expand only happens on first render
        (unless (memq 'initialized my/team-sidebar--expanded-sessions)
          (push 'initialized my/team-sidebar--expanded-sessions))
        (insert "\n")))))

;;; ---- Status Rendering -------------------------------------------------------

(defun my/team-sidebar--status-indicator (status)
  "Return a string indicator for agent STATUS symbol."
  (pcase status
    ('idle  (propertize "●" 'face 'my/team-sidebar-status-idle))
    ('busy  (propertize "◉" 'face 'my/team-sidebar-status-busy))
    ('pending (propertize "◎" 'face 'my/team-sidebar-status-pending))
    ('initializing (propertize "○" 'face 'my/team-sidebar-status-init))
    ('dead  (propertize "✕" 'face 'my/team-sidebar-status-dead))
    (_      "?")))

(defun my/team-sidebar--insert-foreign-agents ()
  "Insert namespace peer agents section.
Returns t if anything was inserted, nil otherwise."
  (when (and my/team-sidebar--namespace-active
             my/team-sidebar--foreign-agents)
    (insert (propertize " Namespace Peers\n" 'face 'my/team-sidebar-session-face))
    (dolist (peer my/team-sidebar--foreign-agents)
      (let ((pid (car peer))
            (agents (cdr peer)))
        (let* ((hostname (or (alist-get 'hostname (car agents)) "unknown"))
               (project-root (and (boundp 'agent-shell-namespace--peer-projects)
                                  (gethash pid agent-shell-namespace--peer-projects)))
               (project-name (when project-root
                               (file-name-nondirectory (directory-file-name project-root))))
               (header (if project-name
                           (format "  %s · %s" project-name hostname)
                         (format "  %s (pid %s)" hostname pid))))
          (insert (propertize (concat header "\n")
                              'face 'font-lock-comment-face))
          (dolist (agent agents)
            (let* ((role (or (alist-get 'role agent) "?"))
                   (wt-name (or (alist-get 'worktree-name agent) "main"))
                   (status (or (alist-get 'status agent) 'idle))
                   (indicator (my/team-sidebar--status-indicator status))
                   (line-start (point)))
              (insert (propertize (format "    %s %-10s  %s\n" indicator role wt-name)
                                  'face 'my/team-sidebar-foreign-face))
              (put-text-property line-start (1- (point))
                                 'my/sidebar-foreign-agent agent))))))
    (insert "\n")
    t))

(defun my/team-sidebar--render ()
  "Render team status into the sidebar buffer."
  (let ((buf (get-buffer my/team-sidebar-buffer-name)))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (let ((inhibit-read-only t)
              (pos (point)))
          ;; Preserve prompt block if present
          (let ((prompt-end (my/team-sidebar--prompt-region-end)))
            (goto-char (or prompt-end (point-min)))
            (delete-region (point) (point-max))
            (my/team-sidebar--insert-status)
            (goto-char (min pos (point-max)))))))))

(defun my/team-sidebar--prompt-region-end ()
  "Return end of the prompt region at top of buffer, or nil if none."
  (save-excursion
    (goto-char (point-min))
    (when (looking-at "```")
      ;; Find the closing ```
      (forward-line 1)
      (if (re-search-forward "^```$" nil t)
          (progn (forward-line 1) (point))
        ;; Unclosed block — include everything to end of buffer? No, return nil.
        nil))))

(defun my/team-sidebar--insert-status ()
  "Insert team status content at point."
  (let ((has-content nil))
    ;; Quota progress bars at the very top
    (when (my/team-sidebar--insert-quota)
      (setq has-content t))
    (when (my/team-sidebar--insert-context-bar)
      (setq has-content t))
    (when has-content (insert "\n"))
    (when (boundp 'agent-shell-team--sessions)
      (maphash
       (lambda (sid agents)
         (let ((short (if (fboundp 'agent-shell-team--short-session-id)
                          (agent-shell-team--short-session-id sid)
                        (substring sid 0 4))))
           (insert (propertize (format " Session: %s" short)
                               'face 'my/team-sidebar-session-face)
                   "\n")
           (dolist (agent agents)
             (let* ((role (or (alist-get 'role agent) "?"))
                    (buffer (alist-get 'buffer agent))
                    (wt-name (or (alist-get 'worktree-name agent) "main"))
                    (status (if (fboundp 'agent-shell-team--agent-status)
                                (agent-shell-team--agent-status buffer)
                              'dead))
                    (status (if (and (equal role "lead")
                                     buffer
                                     (get-buffer buffer)
                                     (with-current-buffer buffer
                                       (my-agent-shell-sprite--pending-p)))
                                'pending
                              status))
                    (indicator (my/team-sidebar--status-indicator status)))
               (insert (format "  %s %-10s %s  %s\n"
                               indicator
                               (propertize role 'face 'my/team-sidebar-role-face)
                               (propertize wt-name 'face 'font-lock-comment-face)
                               (propertize (symbol-name status)
                                           'face 'font-lock-type-face)))
               ;; Store agent data as text property for navigation
               (put-text-property (line-beginning-position 0)
                                  (line-end-position 0)
                                  'my/sidebar-agent agent)
               ;; Show current task for busy agents
               (when (and (eq status 'busy)
                          (boundp 'agent-shell-team--request-to-buffer))
                 (let ((req-id (cl-loop for k being the hash-keys of agent-shell-team--request-to-buffer
                                        using (hash-values v)
                                        when (eq v buffer) return k)))
                   (when req-id
                     (insert (format "    └ %s\n"
                                     (propertize req-id 'face 'font-lock-comment-face))))))))
           (insert "\n")
           (setq has-content t)))
       agent-shell-team--sessions))
    ;; Foreign agents from namespace peers
    (when (my/team-sidebar--insert-foreign-agents)
      (setq has-content t))
    ;; Task queue
    (when (and (boundp 'agent-shell-team--task-queue)
               agent-shell-team--task-queue)
      (insert (propertize " Pending Tasks" 'face 'my/team-sidebar-session-face) "\n")
      (dolist (task agent-shell-team--task-queue)
        (let ((task-line-start (point)))
          (insert (format "  ⏳ %s: %s\n"
                          (propertize (or (plist-get task :role) "?")
                                      'face 'my/team-sidebar-role-face)
                          (truncate-string-to-width
                           (or (plist-get task :message) "") 30 nil nil "…")))
          (put-text-property task-line-start (1- (point))
                             'task-request-id (plist-get task :request-id))
          (put-text-property task-line-start (1- (point))
                             'my/sidebar-pending-task task)))
      (insert "\n")
      (setq has-content t))
    ;; Message queue for lead
    (when (and (boundp 'agent-shell-team--message-queue)
               (hash-table-p agent-shell-team--message-queue))
      (let ((lead-buf (my/team-sidebar--find-lead-buffer agent-shell-team--session-id)))
        (when lead-buf
          (let ((msgs (gethash lead-buf agent-shell-team--message-queue)))
            (when msgs
              (insert (propertize (format " Queued Messages (%d)" (length msgs))
                                  'face 'my/team-sidebar-session-face) "\n")
              (dolist (msg msgs)
                (let* ((title (or (plist-get msg :title) "?"))
                       (body (or (plist-get msg :message) ""))
                       (first-line (car (split-string body "\n" t))))
                  (insert (format "  %s %s\n"
                                  (propertize title 'face 'my/team-sidebar-role-face)
                                  (truncate-string-to-width
                                   (or first-line "") 25 nil nil "…")))))
              (insert "\n")
              (setq has-content t))))))
    ;; Group progress
    (when (and (boundp 'agent-shell-team--task-groups)
               (hash-table-p agent-shell-team--task-groups)
               (> (hash-table-count agent-shell-team--task-groups) 0))
      (let ((group-content nil))
        (maphash (lambda (gid group)
                   (when (equal (plist-get group :session-id) agent-shell-team--session-id)
                     (let ((pending (length (plist-get group :pending)))
                           (completed (length (plist-get group :completed))))
                       (push (format "  %s %d/%d\n"
                                     (propertize (truncate-string-to-width gid 20 nil nil "…")
                                                 'face 'font-lock-comment-face)
                                     completed (+ pending completed))
                             group-content))))
                 agent-shell-team--task-groups)
        (when group-content
          (insert (propertize " Groups" 'face 'my/team-sidebar-session-face) "\n")
          (dolist (line (nreverse group-content))
            (insert line))
          (insert "\n")
          (setq has-content t))))
    ;; History section
    (when (fboundp 'agent-shell-team--load-all-sessions)
      (let ((before (point)))
        (my/team-sidebar--insert-history)
        (when (> (point) before)
          (setq has-content t))))
    (unless has-content
      (insert "\n  No active sessions.\n"))))

;;; ---- Major Mode -------------------------------------------------------------

(defvar my/team-sidebar-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "n" #'my/team-sidebar-next-agent)
    (define-key map "p" #'my/team-sidebar-prev-agent)
    (define-key map (kbd "RET") #'my/team-sidebar-switch-to-agent)
    (define-key map "x" #'my/team-sidebar-kill-agent)
    (define-key map "q" #'my/team-sidebar-quit)
    (define-key map "g" #'my/team-sidebar-refresh)
    (define-key map "+" #'my/team-sidebar-prompt)
    (define-key map "i" #'my/team-sidebar-prompt)
    (define-key map "j" #'my/team-sidebar-next-item)
    (define-key map "k" #'my/team-sidebar-prev-item)
    (define-key map (kbd "<up>") #'my/team-sidebar-prev-item)
    (define-key map (kbd "<down>") #'my/team-sidebar-next-item)
    (define-key map (kbd "<tab>") #'my/team-sidebar-toggle-section)
    map)
  "Keymap for `my/team-sidebar-mode'.")

(define-derived-mode my/team-sidebar-mode special-mode "TeamSidebar"
  "Major mode for the team agent sidebar."
  :interactive nil
  (setq cursor-type 'bar
        truncate-lines t
        buffer-read-only t
        buffer-invisibility-spec nil
        header-line-format (propertize " Team Dashboard" 'face 'bold)
        mode-line-format nil)
  (setq-local face-remapping-alist
              '((default (:background "#1a1400" :foreground "#ffb000"))
                (header-line (:background "#1a1400" :foreground "#ffc830"
                               :weight bold :box nil)))))

;; Evil-mode integration: bind keys in normal state so they take priority
(when (fboundp 'evil-define-key*)
  (evil-define-key* 'normal my/team-sidebar-mode-map
    "n" #'my/team-sidebar-next-agent
    "p" #'my/team-sidebar-prev-agent
    (kbd "RET") #'my/team-sidebar-switch-to-agent
    "x" #'my/team-sidebar-kill-agent
    "q" #'my/team-sidebar-quit
    "g" #'my/team-sidebar-refresh
    "+" #'my/team-sidebar-prompt
    "i" #'my/team-sidebar-prompt
    "j" #'my/team-sidebar-next-item
    "k" #'my/team-sidebar-prev-item
    (kbd "<up>") #'my/team-sidebar-prev-item
    (kbd "<down>") #'my/team-sidebar-next-item
    (kbd "<tab>") #'my/team-sidebar-toggle-section))

;; Open sidebar in normal state (not motion state from special-mode parent)
(when (fboundp 'evil-set-initial-state)
  (evil-set-initial-state 'my/team-sidebar-mode 'normal))

;;; ---- Navigation Commands ----------------------------------------------------

(defun my/team-sidebar--agent-at-point ()
  "Return the agent alist at point, or nil."
  (get-text-property (line-beginning-position) 'my/sidebar-agent))

(defun my/team-sidebar--preview-agent ()
  "Display the agent buffer at point in a non-sidebar window without selecting it."
  (let ((agent (my/team-sidebar--agent-at-point)))
    (when agent
      (let ((buf (alist-get 'buffer agent)))
        (when (buffer-live-p buf)
          (let ((window-buffer-change-functions nil)
                (window-selection-change-functions nil))
            (display-buffer buf '(display-buffer-use-some-window
                                  (inhibit-same-window . t)))))))))

(defun my/team-sidebar--task-at-point ()
  "Return the task plist at point, or nil."
  (get-text-property (line-beginning-position) 'my/sidebar-task))

(defun my/team-sidebar--session-at-point ()
  "Return the session-id at point, or nil."
  (get-text-property (line-beginning-position) 'my/sidebar-session))

(defun my/team-sidebar--item-at-point-p ()
  "Return non-nil if current line has an agent, task, or session property."
  (let ((pos (line-beginning-position)))
    (or (get-text-property pos 'my/sidebar-agent)
        (get-text-property pos 'my/sidebar-task)
        (get-text-property pos 'my/sidebar-session)
        (get-text-property pos 'my/sidebar-pending-task))))

(defun my/team-sidebar--render-task-preview (task)
  "Render TASK plist into a formatted preview buffer."
  (let ((buf (get-buffer-create " *task-preview*"))
        (rid (or (plist-get task :request-id) "unknown"))
        (role (or (plist-get task :role) "?"))
        (status (or (plist-get task :status) "?"))
        (msg (or (plist-get task :message) ""))
        (created (plist-get task :created-at))
        (assigned (plist-get task :assigned-at))
        (completed (plist-get task :completed-at))
        (commit (plist-get task :commit))
        (worktree (plist-get task :agent-worktree))
        (group (plist-get task :group-id)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format " Task: %s\n" rid)
                            'face '(:weight bold :height 1.2))
                "\n"
                (format "  Status:     %s\n" status)
                (format "  Role:       %s\n" role))
        (when worktree
          (insert (format "  Worktree:   %s\n" worktree)))
        (when group
          (insert (format "  Group:      %s\n" group)))
        (insert "\n")
        (when created
          (insert (format "  Created:    %s\n"
                          (format-time-string "%Y-%m-%d %H:%M:%S" created))))
        (when assigned
          (insert (format "  Assigned:   %s\n"
                          (format-time-string "%Y-%m-%d %H:%M:%S" assigned))))
        (when completed
          (insert (format "  Completed:  %s\n"
                          (format-time-string "%Y-%m-%d %H:%M:%S" completed))))
        (when commit
          (insert (format "  Commit:     %s\n" commit)))
        (insert "\n"
                (propertize " Description\n" 'face '(:weight bold))
                "\n"
                (format "  %s\n" (string-replace "\n" "\n  " msg))))
      (goto-char (point-min))
      (special-mode))
    buf))

(defun my/team-sidebar--preview-task ()
  "Preview the report for the task at point, falling back to synthetic preview."
  (let ((task (my/team-sidebar--task-at-point)))
    (when task
      (let* ((report (plist-get task :report-path))
             (buf (cond
                   ((and report (file-readable-p report))
                    (let ((b (find-file-noselect report)))
                      (with-current-buffer b
                        (when (and (fboundp 'markdown-view-mode)
                                   (not (derived-mode-p 'markdown-view-mode)))
                          (markdown-view-mode)))
                      b))
                   (t (my/team-sidebar--render-task-preview task)))))
        (when buf
          (let ((window-buffer-change-functions nil)
                (window-selection-change-functions nil))
            (display-buffer buf '(display-buffer-use-some-window
                                  (inhibit-same-window . t)))))))))

(defun my/team-sidebar--preview-current ()
  "Preview either agent buffer or task report at point."
  (cond
   ((my/team-sidebar--agent-at-point) (my/team-sidebar--preview-agent))
   ((my/team-sidebar--task-at-point)  (my/team-sidebar--preview-task))))

(defun my/team-sidebar-next-item ()
  "Move to next navigable line (agent, task, or session header) and preview."
  (interactive)
  (let ((start (point)))
    (forward-line 1)
    (while (and (not (eobp))
                (not (my/team-sidebar--item-at-point-p)))
      (forward-line 1))
    (if (eobp)
        (goto-char start)
      (my/team-sidebar--preview-current))))

(defun my/team-sidebar-prev-item ()
  "Move to previous navigable line (agent, task, or session header) and preview."
  (interactive)
  (let ((start (point)))
    (forward-line -1)
    (while (and (not (bobp))
                (not (my/team-sidebar--item-at-point-p)))
      (forward-line -1))
    (if (and (bobp)
             (not (my/team-sidebar--item-at-point-p)))
        (goto-char start)
      (my/team-sidebar--preview-current))))

(defun my/team-sidebar-next-agent ()
  "Move to next agent line and preview its buffer."
  (interactive)
  (let ((start (point)))
    (forward-line 1)
    (while (and (not (eobp))
                (not (get-text-property (line-beginning-position) 'my/sidebar-agent)))
      (forward-line 1))
    (if (eobp)
        (goto-char start)
      (my/team-sidebar--preview-agent))))

(defun my/team-sidebar-prev-agent ()
  "Move to previous agent line and preview its buffer."
  (interactive)
  (let ((start (point)))
    (forward-line -1)
    (while (and (not (bobp))
                (not (get-text-property (line-beginning-position) 'my/sidebar-agent)))
      (forward-line -1))
    (if (and (bobp)
             (not (get-text-property (line-beginning-position) 'my/sidebar-agent)))
        (goto-char start)
      (my/team-sidebar--preview-agent))))

(defun my/team-sidebar-switch-to-agent ()
  "Switch to agent buffer, open task report, or toggle session at point."
  (interactive)
  (cond
   ;; Session header — toggle collapse
   ((my/team-sidebar--session-at-point)
    (my/team-sidebar-toggle-section))
   ;; Task line — open report if available
   ((my/team-sidebar--task-at-point)
    (let ((task (my/team-sidebar--task-at-point)))
      (if-let ((report (plist-get task :report-path)))
          (if (file-readable-p report)
              (select-window
               (display-buffer (find-file-noselect report)
                               '(display-buffer-use-some-window
                                 (inhibit-same-window . t))))
            (message "Report not readable: %s" report))
        (message "No report for this task."))))
   ;; Foreign agent line — read-only
   ((get-text-property (line-beginning-position) 'my/sidebar-foreign-agent)
    (let ((agent (get-text-property (line-beginning-position) 'my/sidebar-foreign-agent)))
      (message "Foreign agent on %s — read-only" (alist-get 'hostname agent))))
   ;; Agent line
   ((my/team-sidebar--agent-at-point)
    (let* ((agent (my/team-sidebar--agent-at-point))
           (buf (alist-get 'buffer agent)))
      (if (buffer-live-p buf)
          (select-window
           (or (get-buffer-window buf)
               (display-buffer buf '(display-buffer-use-some-window
                                     (inhibit-same-window . t)))))
        (message "Agent buffer is dead."))))
   (t (message "Nothing on this line."))))

(defun my/team-sidebar-kill-agent ()
  "Kill/dismiss the agent at point, or cancel the pending task at point."
  (interactive)
  (cond
   ;; Pending task line — cancel it
   ((get-text-property (line-beginning-position) 'my/sidebar-pending-task)
    (my/team-sidebar-cancel-pending-task))
   ;; Agent line — kill it
   ((my/team-sidebar--agent-at-point)
    (let* ((agent (my/team-sidebar--agent-at-point))
           (buf (alist-get 'buffer agent))
           (role (alist-get 'role agent)))
      (when (yes-or-no-p (format "Kill %s agent? " role))
        (when (buffer-live-p buf)
          (kill-buffer buf))
        (my/team-sidebar-refresh))))
   (t (message "No agent or pending task on this line."))))

(defun my/team-sidebar-cancel-pending-task ()
  "Cancel the pending task at point and notify the lead."
  (interactive)
  (let ((request-id (get-text-property (line-beginning-position) 'task-request-id)))
    (if (not request-id)
        (message "No pending task on this line.")
      (when (yes-or-no-p (format "Cancel pending task %s? " request-id))
        ;; Remove from task queue
        (setq agent-shell-team--task-queue
              (cl-remove-if (lambda (task)
                              (equal (plist-get task :request-id) request-id))
                            agent-shell-team--task-queue))
        ;; Notify lead
        (when-let ((lead-buf (agent-shell-team--get-lead agent-shell-team--session-id)))
          (agent-shell-team--queue-message
           nil lead-buf
           (list :from "elevator-operator"
                 :title "Task Cancelled"
                 :message (format "Task %s was cancelled by the elevator-operator." request-id)))
          (agent-shell-team--start-drain-timer))
        ;; Refresh sidebar
        (my/team-sidebar-refresh)
        (message "Task %s cancelled" request-id)))))

(defun my/team-sidebar-quit ()
  "Hide the sidebar without killing the buffer."
  (interactive)
  (let ((win (get-buffer-window my/team-sidebar-buffer-name)))
    (when win
      (delete-window win))))

(defun my/team-sidebar-refresh ()
  "Manually refresh the sidebar content (force-refreshes history cache)."
  (interactive)
  (setq my/team-sidebar--history-cache nil
        my/team-sidebar--history-cache-time 0
        my/team-sidebar--manually-collapsed nil)
  (my/team-sidebar--render))

(defun my/team-sidebar-toggle-section ()
  "Toggle collapse/expand of history session at point."
  (interactive)
  (let ((session-id (get-text-property (line-beginning-position) 'my/sidebar-session)))
    (when session-id
      (let* ((sym (intern (format "session-%s" session-id)))
             (inhibit-read-only t)
             (currently-hidden (memq sym buffer-invisibility-spec)))
        (if currently-hidden
            (progn
              (remove-from-invisibility-spec sym)
              (cl-pushnew session-id my/team-sidebar--expanded-sessions :test #'equal)
              (setq my/team-sidebar--manually-collapsed
                    (delete session-id my/team-sidebar--manually-collapsed)))
          (add-to-invisibility-spec sym)
          (setq my/team-sidebar--expanded-sessions
                (delete session-id my/team-sidebar--expanded-sessions))
          (cl-pushnew session-id my/team-sidebar--manually-collapsed :test #'equal))
        ;; Update the toggle indicator
        (save-excursion
          (beginning-of-line)
          (when (looking-at "[▸▾]")
            (replace-match (if currently-hidden "▾" "▸"))))))))

;;; ---- Inline Prompt Mode -----------------------------------------------------

(defvar my/team-sidebar-prompt-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-<return>") #'my/team-sidebar-prompt-submit)
    (define-key map (kbd "<escape>") #'my/team-sidebar-prompt-cancel)
    (define-key map (kbd "C-c C-k") #'my/team-sidebar-prompt-cancel)
    map)
  "Keymap for inline prompt editing in the team sidebar.")

(define-minor-mode my/team-sidebar-prompt-mode
  "Minor mode for inline prompt editing in team sidebar."
  :lighter " Prompt"
  :keymap my/team-sidebar-prompt-mode-map
  (if my/team-sidebar-prompt-mode
      (setq buffer-read-only nil)
    (setq buffer-read-only t)
    (when (fboundp 'evil-normal-state)
      (evil-normal-state))))

(defun my/team-sidebar-prompt ()
  "Enter inline prompt mode: insert a markdown code block at the top."
  (interactive)
  (let ((inhibit-read-only t))
    (goto-char (point-min))
    (insert "```\n\n```\n")
    ;; Make only the editable region modifiable
    (let ((block-end (save-excursion
                       (goto-char (point-min))
                       (forward-line 1)
                       (re-search-forward "^```$" nil t)
                       (line-beginning-position 2))))
      (put-text-property block-end (point-max) 'read-only t))
    ;; Position cursor inside the block
    (goto-char (point-min))
    (forward-line 1)
    (my/team-sidebar-prompt-mode 1)
    ;; Switch to emacs state AFTER minor mode is fully set up,
    ;; via run-at-time to ensure evil doesn't override it.
    (when (fboundp 'evil-emacs-state)
      (run-at-time 0 nil
                   (lambda (buf)
                     (when (buffer-live-p buf)
                       (let ((win (get-buffer-window buf)))
                         (when (and win (window-live-p win))
                           (select-window win)
                           (evil-emacs-state)))))
                   (current-buffer)))))

(defun my/team-sidebar--extract-prompt-text ()
  "Extract text from between the ``` markers at top of buffer."
  (save-excursion
    (goto-char (point-min))
    (when (looking-at "```")
      (forward-line 1)
      (let ((start (point)))
        (when (re-search-forward "^```$" nil t)
          (string-trim (buffer-substring-no-properties start (line-beginning-position))))))))

(defun my/team-sidebar--erase-prompt-block ()
  "Remove the prompt block from the top of the buffer."
  (let ((inhibit-read-only t))
    ;; Remove read-only property first
    (remove-text-properties (point-min) (point-max) '(read-only nil))
    (save-excursion
      (goto-char (point-min))
      (when (looking-at "```")
        (let ((end (my/team-sidebar--prompt-region-end)))
          (when end
            (delete-region (point-min) end)))))))

(defun my/team-sidebar-prompt-submit ()
  "Submit the prompt text to the lead agent shell buffer."
  (interactive)
  (let ((text (my/team-sidebar--extract-prompt-text)))
    (if (or (null text) (string-empty-p text))
        (message "Empty prompt, nothing to submit.")
      (let* ((sid agent-shell-team--session-id)
             (lead-buf (my/team-sidebar--find-lead-buffer sid)))
        (if (not (buffer-live-p lead-buf))
            (message "Lead buffer not found for session %s" sid)
          (my/team-sidebar-prompt-mode -1)
          (my/team-sidebar--erase-prompt-block)
          (with-current-buffer lead-buf
            (shell-maker-submit :input text))
          (message "Submitted to lead."))))))

(defun my/team-sidebar-prompt-cancel ()
  "Cancel prompt editing and restore read-only state."
  (interactive)
  (my/team-sidebar-prompt-mode -1)
  (my/team-sidebar--erase-prompt-block))

;;; ---- Side Window Management -------------------------------------------------

(defun my/team-sidebar--get-or-create-buffer ()
  "Get or create the sidebar buffer."
  (or (get-buffer my/team-sidebar-buffer-name)
      (with-current-buffer (get-buffer-create my/team-sidebar-buffer-name)
        (my/team-sidebar-mode)
        (current-buffer))))

(defun my/team-sidebar--show ()
  "Display the sidebar in a side window on the right."
  (let ((buf (my/team-sidebar--get-or-create-buffer)))
    (unless (get-buffer-window buf)
      (let ((win (display-buffer-in-side-window
                  buf
                  `((side . right)
                    (slot . 0)
                    (window-width . ,my/team-sidebar-width)
                    (dedicated . t)))))
        (when win
          (my/team-sidebar--set-window-params win))))
    ;; Start refresh timers
    (my/team-sidebar--ensure-timer)
    (my/team-sidebar--quota-ensure-timer)
    ;; Initial render
    (my/team-sidebar--render)))

(defun my/team-sidebar--hide ()
  "Hide the sidebar window without killing the buffer."
  (let ((win (get-buffer-window my/team-sidebar-buffer-name t)))
    (when win
      (delete-window win)))
  (my/team-sidebar--stop-timer))

(defun my/team-sidebar--set-window-params (win)
  "Set protective window parameters on WIN."
  (when (window-live-p win)
    (set-window-parameter win 'no-delete-other-windows t)
    (set-window-parameter win 'no-other-window t)
    (set-window-parameter win 'dedicated t)
    (set-window-dedicated-p win t)))

(defun my/team-sidebar--reapply-window-params ()
  "Reapply window parameters on config change (treemacs defensive pattern)."
  (let ((win (get-buffer-window my/team-sidebar-buffer-name t)))
    (when win
      ;; Suppress hook locally to prevent feedback loops
      (let ((window-configuration-change-hook nil))
        (my/team-sidebar--set-window-params win)))))

;;; ---- Auto Show/Hide ---------------------------------------------------------

(defvar my/team-sidebar--toggling nil
  "Guard to prevent recursive toggling.")

(defun my/team-sidebar--team-related-buffer-p (buf)
  "Return non-nil if BUF is a team-related buffer.
A buffer is team-related if any of:
- Its name matches *team:XXXX:* pattern (team buffers)
- It IS the sidebar buffer itself
- It IS the approval queue buffer
- It is visiting a file under .agent-shell/reports/ or .agent-shell/reviews/"
  (and (buffer-live-p buf)
       (let ((name (buffer-name buf)))
         (or (string-match-p "\\*team:[a-z0-9]\\{4\\}:" name)
             (equal name my/team-sidebar-buffer-name)
             (equal name my/approval-buffer-name)
             (when-let ((file (buffer-file-name buf)))
               (string-match-p "/\\.agent-shell/re\\(ports\\|views\\)/" file))))))

(defun my/team-sidebar--auto-toggle (&rest _)
  "Show sidebar when selected window's buffer is team-related, hide otherwise.
Registered on `window-buffer-change-functions' and
`window-selection-change-functions'."
  (when (and (not my/team-sidebar--toggling)
             (not (active-minibuffer-window)))
    (let ((my/team-sidebar--toggling t)
          (sel-buf (window-buffer (selected-window))))
      (if (my/team-sidebar--team-related-buffer-p sel-buf)
          (my/team-sidebar--show)
        (my/team-sidebar--hide)))))

;;; ---- Refresh Timer ----------------------------------------------------------

(defun my/team-sidebar--ensure-timer ()
  "Ensure the 2-second refresh timer is running."
  (let ((buf (get-buffer my/team-sidebar-buffer-name)))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (unless (and my/team-sidebar--refresh-timer
                     (timerp my/team-sidebar--refresh-timer)
                     (memq my/team-sidebar--refresh-timer timer-list))
          (setq my/team-sidebar--refresh-timer
                (run-with-timer 2 2 #'my/team-sidebar--timer-refresh)))))))

(defun my/team-sidebar--stop-timer ()
  "Stop the refresh timer."
  (let ((buf (get-buffer my/team-sidebar-buffer-name)))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (when (timerp my/team-sidebar--refresh-timer)
          (cancel-timer my/team-sidebar--refresh-timer)
          (setq my/team-sidebar--refresh-timer nil))))))

(defun my/team-sidebar--timer-refresh ()
  "Timer callback: refresh if sidebar is visible."
  (let ((win (get-buffer-window my/team-sidebar-buffer-name t)))
    (if win
        (my/team-sidebar--render)
      ;; Sidebar not visible — stop timer
      (my/team-sidebar--stop-timer))))

;;; ---- Integration / Hook Registration ----------------------------------------

(defun my/team-sidebar--setup-hooks ()
  "Register auto-toggle hooks and window-config protection."
  (add-hook 'window-buffer-change-functions #'my/team-sidebar--auto-toggle)
  (add-hook 'window-selection-change-functions #'my/team-sidebar--auto-toggle)
  (add-hook 'window-configuration-change-hook #'my/team-sidebar--reapply-window-params))

(with-eval-after-load 'agent-shell-team
  (my/team-sidebar--setup-hooks))

;;; ---- Context bar refresh on usage update -----------------------------------

(with-eval-after-load 'agent-shell-usage
  (advice-add 'agent-shell--update-usage-from-notification :after
    (lambda (&rest _)
      (when (and (boundp 'agent-shell-team--role)
                 (equal agent-shell-team--role "lead"))
        (when (fboundp 'my/team-sidebar-refresh)
          (my/team-sidebar-refresh))))))

(provide 'my-agent-shell-sidebar)
;;; my-agent-shell-sidebar.el ends here
