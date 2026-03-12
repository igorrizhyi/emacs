;;; mcp-stdio-server.el --- Stdio MCP server for agent-shell integration -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author: Igor Rizhyi
;; Keywords: tools, mcp
;; Version: 0.1.0

;;; Commentary:

;; This module provides a stdio-based MCP server that bridges agent-shell
;; to the existing claude-code-mcp-tools infrastructure.
;;
;; It reads JSON-RPC requests from stdin and writes responses to stdout,
;; delegating actual tool execution to claude-code-mcp-tools.el handlers.
;;
;; Usage (via emacsclient):
;;   emacsclient -s emacs-{PID} -e "(claude-code-mcp-stdio-handler)"

;;; Code:

(require 'json)
(require 'claude-code-mcp-tools nil t)

(defvar claude-code-mcp-stdio--running nil
  "Flag indicating if stdio server is running.")

(defun claude-code-mcp-stdio-handler ()
  "Main entry point for stdio MCP server.
Reads JSON-RPC requests from stdin, processes them, and writes responses to stdout."
  (interactive)
  (setq claude-code-mcp-stdio--running t)
  (unwind-protect
      (claude-code-mcp-stdio--main-loop)
    (setq claude-code-mcp-stdio--running nil)))

(defun claude-code-mcp-stdio--main-loop ()
  "Main loop reading from stdin and processing MCP requests."
  (let ((input-buffer ""))
    (while claude-code-mcp-stdio--running
      ;; Read a line from stdin
      (let ((line (ignore-errors (read-from-minibuffer ""))))
        (when line
          (setq input-buffer (concat input-buffer line))
          ;; Try to parse as JSON
          (condition-case err
              (let* ((request (json-read-from-string input-buffer))
                     (response (claude-code-mcp-stdio--handle-request request)))
                ;; Clear buffer on successful parse
                (setq input-buffer "")
                ;; Write response to stdout
                (when response
                  (princ (json-encode response))
                  (princ "\n")
                  (terpri)))
            (json-error
             ;; Incomplete JSON, wait for more input
             nil)
            (error
             ;; Other error, send error response and clear buffer
             (setq input-buffer "")
             (princ (json-encode
                     `((jsonrpc . "2.0")
                       (id . nil)
                       (error . ((code . -32603)
                                (message . ,(error-message-string err)))))))
             (princ "\n"))))))))

(defun claude-code-mcp-stdio--handle-request (request)
  "Handle a single MCP REQUEST and return response."
  (let* ((id (alist-get 'id request))
         (method (alist-get 'method request))
         (params (alist-get 'params request)))
    (cond
     ;; Initialize
     ((string= method "initialize")
      `((jsonrpc . "2.0")
        (id . ,id)
        (result . ((protocolVersion . "2024-11-05")
                   (capabilities . ((tools . ((listChanged . t)))))
                   (serverInfo . ((name . "emacs-mcp")
                                  (version . "0.1.0")))))))

     ;; List tools
     ((string= method "tools/list")
      `((jsonrpc . "2.0")
        (id . ,id)
        (result . ((tools . ,(claude-code-mcp-stdio--list-tools))))))

     ;; Call tool
     ((string= method "tools/call")
      (let* ((tool-name (alist-get 'name params))
             (tool-args (alist-get 'arguments params))
             (result (claude-code-mcp-stdio--call-tool tool-name tool-args)))
        `((jsonrpc . "2.0")
          (id . ,id)
          (result . ,result))))

     ;; Ping/pong for health check
     ((string= method "ping")
      `((jsonrpc . "2.0")
        (id . ,id)
        (result . ((pong . t)))))

     ;; Unknown method
     (t
      `((jsonrpc . "2.0")
        (id . ,id)
        (error . ((code . -32601)
                  (message . ,(format "Method not found: %s" method)))))))))

(defun claude-code-mcp-stdio--list-tools ()
  "Return list of available MCP tools."
  (vector
   `((name . "getOpenBuffers")
     (description . "Get list of open buffers in the current Emacs project")
     (inputSchema . ((type . "object")
                     (properties . ())
                     (required . []))))

   `((name . "getCurrentSelection")
     (description . "Get the currently selected text in Emacs")
     (inputSchema . ((type . "object")
                     (properties . ())
                     (required . []))))

   `((name . "getDiagnostics")
     (description . "Get LSP diagnostics for open buffers")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string")
                                            (description . "Optional file path to filter diagnostics")))))
                     (required . []))))

   `((name . "getDefinition")
     (description . "Get definition location for symbol at position")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string")))
                                   (line . ((type . "integer")))
                                   (column . ((type . "integer")))))
                     (required . ["file" "line" "column"]))))

   `((name . "findReferences")
     (description . "Find all references to symbol at position")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string")))
                                   (line . ((type . "integer")))
                                   (column . ((type . "integer")))))
                     (required . ["file" "line" "column"]))))

   `((name . "executeTerminalCommandInEmacs")
     (description . "Execute a command in an Emacs terminal buffer")
     (inputSchema . ((type . "object")
                     (properties . ((command . ((type . "string")
                                               (description . "Command to execute")))
                                   (terminalId . ((type . "string")
                                                 (description . "Optional terminal ID")))))
                     (required . ["command"]))))

   `((name . "getTerminalContent")
     (description . "Get content of a terminal buffer")
     (inputSchema . ((type . "object")
                     (properties . ((terminalId . ((type . "string")
                                                  (description . "Terminal ID to read from")))))
                     (required . []))))

   `((name . "createTerminal")
     (description . "Create a new terminal buffer")
     (inputSchema . ((type . "object")
                     (properties . ((name . ((type . "string")
                                            (description . "Name for the terminal")))
                                   (cwd . ((type . "string")
                                          (description . "Working directory")))))
                     (required . []))))

   `((name . "sendNotification")
     (description . "Send a desktop notification")
     (inputSchema . ((type . "object")
                     (properties . ((title . ((type . "string")))
                                   (message . ((type . "string")))))
                     (required . ["title" "message"]))))

   `((name . "openDiffFile")
     (description . "Open a diff view for a file")
     (inputSchema . ((type . "object")
                     (properties . ((file . ((type . "string")
                                            (description . "File path to show diff for")))))
                     (required . ["file"]))))

   `((name . "openCurrentChanges")
     (description . "Open diff view of current uncommitted changes")
     (inputSchema . ((type . "object")
                     (properties . ())
                     (required . []))))

   `((name . "tasksPut")
     (description . "Submit tasks to the team task queue for assignment to idle agents")
     (inputSchema . ((type . "object")
                     (properties . ((tasks . ((type . "array")
                                              (items . ((type . "object")
                                                        (properties . ((role . ((type . "string")
                                                                               (description . "Target agent role: dev, tester, researcher")))
                                                                       (message . ((type . "string")
                                                                                  (description . "Task description and instructions")))
                                                                       (group_id . ((type . "string")
                                                                                   (description . "Optional group ID to batch related subtasks. All tasks with the same group_id are tracked together and the lead is notified when ALL complete.")))
                                                                       (request_id . ((type . "string")
                                                                                     (description . "Optional custom request ID. Auto-generated if omitted.")))))
                                                        (required . ["role" "message"])))))))
                     (required . ["tasks"]))))

   `((name . "taskUpdate")
     (description . "Push a task status update (finished/updated/blocked) to the team lead's queue")
     (inputSchema . ((type . "object")
                     (properties . ((request_id . ((type . "string")
                                                   (description . "Request ID from the original tasksPut assignment")))
                                    (status . ((type . "string")
                                               (enum . ["finished" "updated" "blocked"])
                                               (description . "Task status")))
                                    (content . ((type . "string")
                                                (description . "What was done, problems encountered, results")))
                                    (commit . ((type . "string")
                                               (description . "Commit hash if code was committed")))
                                    (report_path . ((type . "string")
                                                    (description . "Path to detailed report file")))))
                     (required . ["request_id" "status" "content"]))))))

(defun claude-code-mcp-stdio--call-tool (tool-name args)
  "Call MCP tool TOOL-NAME with ARGS and return result."
  (condition-case err
      (let* ((handler-name (intern (format "claude-code-mcp-handle-%s" tool-name)))
             (result (if (fboundp handler-name)
                        (funcall handler-name args)
                      ;; Fallback: try to call the tool via existing infrastructure
                      (claude-code-mcp-stdio--fallback-call tool-name args))))
        `((content . [((type . "text")
                       (text . ,(if (stringp result)
                                   result
                                 (json-encode result))))])))
    (error
     `((content . [((type . "text")
                    (text . ,(format "Error: %s" (error-message-string err))))])
       (isError . t)))))

(defun claude-code-mcp-stdio--fallback-call (tool-name args)
  "Fallback tool call for TOOL-NAME with ARGS."
  (pcase tool-name
    ("getOpenBuffers"
     (mapcar (lambda (buf)
               (with-current-buffer buf
                 `((name . ,(buffer-name))
                   (file . ,(buffer-file-name))
                   (modified . ,(buffer-modified-p)))))
             (seq-filter #'buffer-file-name (buffer-list))))

    ("getCurrentSelection"
     (if (use-region-p)
         (buffer-substring-no-properties (region-beginning) (region-end))
       ""))

    ("sendNotification"
     (let ((title (alist-get 'title args))
           (message (alist-get 'message args)))
       (notifications-notify :title title :body message)
       "Notification sent"))

    (_
     (format "Tool %s not implemented in fallback handler" tool-name))))

(provide 'mcp-stdio-server)
;;; mcp-stdio-server.el ends here
