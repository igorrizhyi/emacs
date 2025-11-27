;;; claude-code-mcp-tools.el --- MCP tool handlers for Claude Code Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2025

;; Author: DESKTOP2 <yuya373@DESKTOP2>
;; Keywords: tools, convenience
;; Version: 0.1.0

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This module implements the MCP tool handlers:
;; - getOpenBuffers: List open buffers in project
;; - getCurrentSelection: Get current text selection
;; - getDiagnostics: Get LSP diagnostics
;; - sendNotification: Send notifications to user via alert
;; - getTerminalContent: Get content of terminal buffer
;; - executeTerminalCommand: Execute command in terminal
;; - getTerminalList: List active terminal sessions
;; - createTerminal: Create new terminal buffer

;;; Code:

(require 'claude-code-core)
(require 'projectile)
(require 'lsp-mode nil t)
(require 'lsp-protocol nil t)
(require 'vc)
(require 'ediff)
(require 'alert nil t)  ;; Optional dependency
(require 'claude-code-terminal)
(require 'claude-code-mcp-protocol)  ;; For async request management
(require 'cl-lib)

;; LSP function declarations
(declare-function lsp-diagnostics "lsp-mode" (&optional all-workspaces))
(declare-function lsp:diagnostic-range "lsp-protocol" (diagnostic))
(declare-function lsp:range-start "lsp-protocol" (range))
(declare-function lsp:position-line "lsp-protocol" (position))
(declare-function lsp:position-character "lsp-protocol" (position))
(declare-function lsp:diagnostic-severity? "lsp-protocol" (diagnostic))
(declare-function lsp:diagnostic-source? "lsp-protocol" (diagnostic))
(declare-function lsp:diagnostic-message "lsp-protocol" (diagnostic))
(declare-function lsp-request "lsp-mode" (method &optional params))
(declare-function lsp--text-document-position-params "lsp-mode" ())
(declare-function lsp--location-uri "lsp-mode" (location))
(declare-function lsp--location-range "lsp-mode" (location))
(declare-function lsp--uri-to-path "lsp-mode" (uri))
(declare-function lsp:range-end "lsp-protocol" (range))
(declare-function lsp:location-uri "lsp-protocol" (location))
(declare-function lsp:location-range "lsp-protocol" (location))
(declare-function lsp:hover-contents "lsp-protocol" (hover))
(declare-function lsp-markup-content? "lsp-protocol" (obj))
(declare-function lsp:markup-content-value "lsp-protocol" (content))
(declare-function lsp-marked-string? "lsp-protocol" (obj))
(declare-function lsp:marked-string-language "lsp-protocol" (marked-string))
(declare-function lsp:marked-string-value "lsp-protocol" (marked-string))

;; Terminal function declarations
(declare-function claude-code-terminal-create "claude-code-terminal" (&optional directory))
(declare-function claude-code-terminal-get-content "claude-code-terminal" (terminal-id &optional project-root))
(declare-function claude-code-terminal-execute-command "claude-code-terminal" (terminal-id command &optional project-root timeout async))
(declare-function claude-code-terminal-execute-command-async "claude-code-terminal" (terminal-id command callback &optional project-root timeout))
(declare-function claude-code-terminal-list-active "claude-code-terminal" ())
(declare-function claude-code-terminal-get-sessions "claude-code-terminal" (&optional project-root))
(declare-function claude-code-terminal-get-by-id "claude-code-terminal" (terminal-id &optional project-root))
(declare-function claude-code-terminal-get-last-focused "claude-code-terminal" ())

;;; MCP Tool Handlers


(defun claude-code-mcp-handle-getOpenBuffers (params)
  "Handle getOpenBuffers request with PARAMS."
  (let* ((include-hidden (cdr (assoc 'includeHidden params)))
         (project-root (claude-code-normalize-project-root (projectile-project-root)))
         (buffers '()))

    (dolist (buffer (buffer-list))
      (let ((file-path (buffer-file-name buffer))
            (buffer-name (buffer-name buffer)))
        (when (and file-path
                   (string-prefix-p project-root file-path)
                   (or include-hidden
                       (not (string-prefix-p " " buffer-name))))
          (push `((path . ,file-path)
                  (name . ,buffer-name)
                  (active . ,(if (eq buffer (current-buffer)) t json-false))
                  (modified . ,(if (buffer-modified-p buffer) t json-false)))
                buffers))))

    `((buffers . ,(nreverse buffers)))))

(defun claude-code-mcp-handle-getCurrentSelection (_params)
  "Handle getCurrentSelection request."
  (if (use-region-p)
      (let* ((start (region-beginning))
             (end (region-end))
             (text (buffer-substring-no-properties start end))
             (start-line (line-number-at-pos start))
             (end-line (line-number-at-pos end))
             (start-char (save-excursion
                           (goto-char start)
                           (current-column)))
             (end-char (save-excursion
                         (goto-char end)
                         (current-column))))
        `((text . ,text)
          (startLine . ,start-line)
          (endLine . ,end-line)
          (startChar . ,start-char)
          (endChar . ,end-char)
          (fileName . ,(or (buffer-file-name) ""))))
    `((text . "")
      (startLine . 0)
      (endLine . 0)
      (startChar . 0)
      (endChar . 0)
      (fileName . ""))))

(defun claude-code-mcp-handle-getDiagnostics (params)
  "Handle getDiagnostics request with PARAMS.
Returns project-wide diagnostics using specified buffer for LSP context."
  (condition-case err
      (let ((diagnostics '())
            (buffer-name (cdr (assoc 'buffer params))))

        ;; Buffer parameter is required for LSP context
        (unless buffer-name
          (error "Buffer name is required for LSP context"))

        ;; Check buffer exists first
        (unless (get-buffer buffer-name)
          (error "Buffer %s not found for LSP context" buffer-name))

        (when (fboundp 'lsp-diagnostics)
          (let ((lsp-diags (with-current-buffer (get-buffer buffer-name)
                             (condition-case diag-err
                                 (lsp-diagnostics t)
                               (error
                                (message "Error getting LSP diagnostics in buffer %s: %s"
                                         buffer-name
                                         (error-message-string diag-err))
                                nil)))))
            (when lsp-diags
              (maphash (lambda (file diags)
                         (dolist (diag diags)
                           (let* ((message (lsp:diagnostic-message diag))
                                  (severity (lsp:diagnostic-severity? diag))
                                  (source (lsp:diagnostic-source? diag))
                                  (range (lsp:diagnostic-range diag))
                                  (start (lsp:range-start range))
                                  (line (1+ (lsp:position-line start)))
                                  (column (lsp:position-character start)))
                             (when (and file line)
                               (push `((file . ,file)
                                       (line . ,line)
                                       (column . ,(or column 0))
                                       (severity . ,(pcase severity
                                                      (1 "error")
                                                      (2 "warning")
                                                      (3 "information")
                                                      (4 "hint")
                                                      (5 "max")
                                                      (_ "")))
                                       (message . ,message)
                                       (source . ,(or source "lsp")))
                                     diagnostics)))))
                       lsp-diags)))
          `((diagnostics . ,(nreverse diagnostics)))))
    (error
     ;; Log error and re-throw it
     (message "Error in getDiagnostics handler: %s" (error-message-string err))
     (signal (car err) (cdr err)))))

;;; Diff Tool Handlers

(defun claude-code-mcp-handle-openDiffFile (params)
  "Handle openDiffFile request with PARAMS."
  (let ((file-a (cdr (assoc 'fileA params)))
        (file-b (cdr (assoc 'fileB params))))
    (condition-case err
        (progn
          (unless (and file-a file-b)
            (error "Missing required parameters: fileA and fileB"))
          (let ((path-a (expand-file-name file-a (claude-code-normalize-project-root (projectile-project-root))))
                (path-b (expand-file-name file-b (claude-code-normalize-project-root (projectile-project-root)))))
            (unless (file-exists-p path-a)
              (error "File not found: %s" path-a))
            (unless (file-exists-p path-b)
              (error "File not found: %s" path-b))
            (ediff-files path-a path-b))
          `((status . "success")
            (message . "Opened ediff session")))
      (error
       `((status . "error")
         (message . ,(error-message-string err)))))))

(defun claude-code-mcp-handle-openRevisionDiff (params)
  "Handle openRevisionDiff request with PARAMS."
  (let ((file (cdr (assoc 'file params)))
        (revision (or (cdr (assoc 'revision params)) "HEAD")))
    (condition-case err
        (progn
          (unless file
            (error "Missing required parameter: file"))
          (let ((full-path (expand-file-name file (claude-code-normalize-project-root (projectile-project-root)))))
            (unless (file-exists-p full-path)
              (error "File not found: %s" full-path))
            ;; Open the file and compare with revision
            (condition-case inner-err
                (with-current-buffer (find-file-noselect full-path)
                  ;; Check if file is under version control
                  (let ((backend (vc-backend buffer-file-name)))
                    (unless backend
                      (error "File is not under version control: %s" file))
                    ;; Use vc-version-ediff for version-controlled files
                    (vc-version-ediff (list buffer-file-name) revision nil)))
              (error
               (message "Inner error in openRevisionDiff: %s" (error-message-string inner-err))
               (signal (car inner-err) (cdr inner-err)))))
          `((status . "success")
            (message . "Opened revision diff")))
      (error
       (message "Error in openRevisionDiff: %s" (error-message-string err))
       `((status . "error")
         (message . ,(error-message-string err)))))))

(defun claude-code-mcp-handle-openCurrentChanges (params)
  "Handle openCurrentChanges request with PARAMS."
  (let ((file (cdr (assoc 'file params))))
    (condition-case err
        (let ((target-file (if file
                               (expand-file-name file (claude-code-normalize-project-root (projectile-project-root)))
                             (buffer-file-name))))
          (unless target-file
            (error "No file specified and current buffer has no file"))
          (unless (file-exists-p target-file)
            (error "File not found: %s" target-file))
          ;; Use vc-diff for showing uncommitted changes
          (with-current-buffer (find-file-noselect target-file)
            (vc-diff nil t))
          `((status . "success")
            (message . "Showing changes")
            (file . ,(file-name-nondirectory target-file))))
      (error
       `((status . "error")
         (message . ,(error-message-string err)))))))

(defun claude-code-mcp-handle-openDiffContent (params)
  "Handle openDiffContent request with PARAMS."
  (let ((content-a (cdr (assoc 'contentA params)))
        (content-b (cdr (assoc 'contentB params)))
        (title-a (cdr (assoc 'titleA params)))
        (title-b (cdr (assoc 'titleB params))))
    (condition-case err
        (progn
          (unless (and content-a content-b title-a title-b)
            (error "Missing required parameters: contentA, contentB, titleA, and titleB"))
          (let* ((buf-a (get-buffer-create title-a))
                 (buf-b (get-buffer-create title-b)))
            ;; Set up buffer A
            (with-current-buffer buf-a
              (erase-buffer)
              (insert content-a)
              (goto-char (point-min)))
            ;; Set up buffer B
            (with-current-buffer buf-b
              (erase-buffer)
              (insert content-b)
              (goto-char (point-min)))
            ;; Start ediff
            (ediff-buffers buf-a buf-b))
          `((status . "success")
            (message . ,(format "Opened ediff session for buffers: %s and %s" title-a title-b))))
      (error
       `((status . "error")
         (message . ,(error-message-string err)))))))

;;; Resource Handlers

(defun claude-code-mcp-handle-get-buffer-content (params)
  "Get content of a buffer specified by PATH in PARAMS."
  (let* ((path (cdr (assoc 'path params)))
         (full-path (expand-file-name path (claude-code-normalize-project-root (projectile-project-root)))))
    (if (file-exists-p full-path)
        (let ((buffer (find-buffer-visiting full-path)))
          (if buffer
              ;; Return buffer content (which may include unsaved changes)
              `((success . t)
                (content . ,(with-current-buffer buffer
                              (buffer-substring-no-properties (point-min) (point-max)))))
            ;; File exists but not opened, read from disk
            `((success . t)
              (content . ,(with-temp-buffer
                            (insert-file-contents full-path)
                            (buffer-string))))))
      `((success . nil)
        (error . ,(format "File not found: %s" full-path))))))

(defun claude-code-mcp-handle-get-project-info (_params)
  "Get project information."
  (let ((project-root (claude-code-normalize-project-root (projectile-project-root))))
    `((success . t)
      (projectRoot . ,project-root)
      (projectName . ,(projectile-project-name))
      (projectType . ,(projectile-project-type))
      (vcs . ,(when (vc-responsible-backend project-root)
                (symbol-name (vc-responsible-backend project-root))))
      (branch . ,(when (vc-responsible-backend project-root)
                   (ignore-errors
                     (vc-working-revision project-root))))
      (lastModified . ,(format-time-string "%FT%T%z")))))

(defun claude-code-mcp-handle-get-project-files (_params)
  "Get list of project files."
  (let ((files (projectile-current-project-files)))
    `((success . t)
      (files . ,(mapcar (lambda (file)
                          `((path . ,file)
                            (relativePath . ,file)
                            (absolutePath . ,(expand-file-name file (claude-code-normalize-project-root (projectile-project-root))))))
                        files)))))


(defun claude-code-mcp-handle-get-open-buffers (params)
  "Handle get-open-buffers request for resources with PARAMS."
  (claude-code-mcp-handle-getOpenBuffers params))


;;; Definition finding

(defun claude-code-mcp-handle-getDefinition (params)
  "Handle getDefinition request with PARAMS using LSP.
PARAMS must include \\='file\\=', \\='line\\=', and \\='symbol\\=' parameters."
  (let* ((symbol-name (cdr (assoc 'symbol params)))
         (file-path (cdr (assoc 'file params)))
         (line (cdr (assoc 'line params)))
         (definitions '()))

    (condition-case err
        (progn
          ;; Check if LSP is available
          (unless (and (fboundp 'lsp-mode)
                       (fboundp 'lsp-request))
            (error "LSP mode is not available.  Please install and configure lsp-mode"))

          ;; file-path, line, and symbol are required
          (unless file-path
            (error "Missing required parameter: file"))
          (unless line
            (error "Missing required parameter: line"))
          (unless symbol-name
            (error "Missing required parameter: symbol"))

          ;; Visit the specified file
          (let* ((full-path (expand-file-name file-path (claude-code-normalize-project-root (projectile-project-root))))
                 (buffer (find-file-noselect full-path)))
            (with-current-buffer buffer
              ;; Check if LSP is active in this buffer
              (unless (bound-and-true-p lsp-mode)
                (error "LSP is not active in buffer: %s" (buffer-name)))

              ;; Go to specified position
              (goto-char (point-min))
              (forward-line (1- line))

              ;; Search for the symbol on this line
              (let ((line-end (line-end-position)))
                (if (search-forward symbol-name line-end t)
                    (goto-char (match-beginning 0))
                  ;; If not found, just go to beginning of line
                  (beginning-of-line)))

              ;; Get definitions using lsp-request
              (setq definitions (claude-code-mcp-get-lsp-definitions-with-request))))

          ;; Return results
          (if definitions
              `((definitions . ,definitions)
                (method . "lsp"))
            (error "No definition found using LSP")))

      (error
       (error "Failed to find definition: %s" (error-message-string err))))))

(defun claude-code-mcp-get-lsp-definitions-with-request ()
  "Get definitions using `lsp-request'."
  (require 'lsp-mode)
  (condition-case _
      (let* ((params (lsp--text-document-position-params))
             (response (lsp-request "textDocument/definition" params))
             (definitions '()))

        ;; Response can be Location, Location[], LocationLink, or LocationLink[]
        (when response
          (let ((locations (if (listp response)
                               (if (and (listp (car response))
                                        (assoc 'uri (car response)))
                                   ;; Array of locations
                                   response
                                 ;; Single location in a list
                                 (if (assoc 'uri response)
                                     (list response)
                                   ;; Might be wrapped
                                   response))
                             ;; Single location
                             (list response))))
            (dolist (loc locations)
              (let* ((uri (lsp--location-uri loc))
                     (range (lsp--location-range loc))
                     (file (when uri (lsp--uri-to-path uri))))

                (when (and file range)
                  (let* ((def-info (claude-code-mcp-get-definition-info-at file range)))
                    (when def-info
                      (push def-info definitions))))))))

        (nreverse definitions))

    (error
     ;; Return empty list on error
     nil)))

(defun claude-code-mcp-get-definition-info-at (file range)
  "Get definition information at FILE with RANGE."
  (condition-case nil
      (let* ((preview (claude-code-mcp-get-preview-text file range)))
        `((file . ,file)
          (preview . ,preview)
          (range . ,range)))
    (error nil)))

(defun claude-code-mcp-get-preview-text (file-path range)
  "Get preview text around RANGE with 3 lines of context from FILE-PATH."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents file-path)
        (claude-code-mcp-get-preview-text-internal range))
    (error "")))

(defun claude-code-mcp-get-preview-text-internal (range)
  "Internal function to get preview text for RANGE.
Assumes we're in the correct buffer."
  (let* ((start-line (lsp:position-line (lsp:range-start range)))
         (end-line (lsp:position-line (lsp:range-end range)))
         ;; Calculate preview range with 3 lines padding
         (preview-start-line (max 0 (- start-line 3)))
         (preview-end-line (+ end-line 3))
         preview-start preview-end)

    ;; Move to preview start
    (goto-char (point-min))
    (forward-line preview-start-line)
    (beginning-of-line)
    (setq preview-start (point))

    ;; Move to preview end
    (goto-char (point-min))
    (forward-line preview-end-line)
    (end-of-line)
    (setq preview-end (point))

    ;; Ensure we don't go past buffer boundaries
    (buffer-substring-no-properties
     preview-start
     (min preview-end (point-max)))))

;;; Reference finding

(defun claude-code-mcp-handle-findReferences (params)
  "Handle findReferences request with PARAMS using LSP.
PARAMS must include \\='file\\=', \\='line\\=', \\='symbol\\=' parameters.
Optional: \\='includeDeclaration\\=' (boolean)."
  (let* ((file-path (cdr (assoc 'file params)))
         (line (cdr (assoc 'line params)))
         (symbol-name (cdr (assoc 'symbol params)))
         (include-declaration (cdr (assoc 'includeDeclaration params)))
         (references '()))

    (condition-case err
        (progn
          ;; Check if LSP is available
          (unless (and (fboundp 'lsp-mode)
                       (fboundp 'lsp-request))
            (error "LSP mode is not available"))

          ;; Validate required parameters
          (unless file-path
            (error "File parameter is required"))
          (unless line
            (error "Line parameter is required"))
          (unless symbol-name
            (error "Symbol parameter is required"))

          ;; Find the file
          (let* ((project-root (claude-code-normalize-project-root (projectile-project-root)))
                 (absolute-path (expand-file-name file-path project-root))
                 (buffer (find-file-noselect absolute-path)))

            (with-current-buffer buffer
              ;; Move to the specified position
              (goto-char (point-min))
              (forward-line (1- line))

              ;; Search for the symbol on this line
              (let ((line-end (line-end-position)))
                (if (search-forward symbol-name line-end t)
                    (goto-char (match-beginning 0))
                  ;; If not found, just go to beginning of line
                  (beginning-of-line)))

              ;; Check if LSP is active in this buffer
              (unless (bound-and-true-p lsp-mode)
                (error "LSP is not active in this buffer"))

              ;; Find references using LSP
              (let* ((context `(:includeDeclaration ,(if include-declaration t :json-false)))
                     (params (append (lsp--text-document-position-params)
                                     `(:context ,context)))
                     (lsp-response (lsp-request "textDocument/references" params)))

                (when lsp-response
                  (setq references (claude-code-mcp-convert-lsp-references lsp-response project-root))))))

          ;; Return the references
          `((references . ,references)
            (count . ,(length references))))

      (error
       `((error . ,(error-message-string err)))))))

(defun claude-code-mcp-convert-lsp-references (lsp-references project-root)
  "Convert LSP-REFERENCES to MCP format relative to PROJECT-ROOT."
  (mapcar (lambda (location)
            (let* ((uri (lsp:location-uri location))
                   (range (lsp:location-range location))
                   (file-path (lsp--uri-to-path uri))
                   (relative-path (file-relative-name file-path project-root)))
              ;; Get preview text for this reference
              (let ((preview (claude-code-mcp-get-preview-text file-path range)))
                `((file . ,relative-path)
                  (absolutePath . ,file-path)
                  (range . ,range)
                  (preview . ,preview)))))
          lsp-references))

;;; Symbol description

(defun claude-code-mcp-handle-describeSymbol (params)
  "Handle describeSymbol request with PARAMS using LSP hover.
PARAMS must include \\='file\\=', \\='line\\=', and \\='symbol\\=' parameters."
  (let* ((symbol-name (cdr (assoc 'symbol params)))
         (file-path (cdr (assoc 'file params)))
         (line (cdr (assoc 'line params)))
         (description nil))

    (condition-case err
        (progn
          ;; Check if LSP is available
          (unless (and (fboundp 'lsp-mode)
                       (fboundp 'lsp-request))
            (error "LSP mode is not available.  Please install and configure lsp-mode"))

          ;; file-path, line, and symbol are required
          (unless file-path
            (error "Missing required parameter: file"))
          (unless line
            (error "Missing required parameter: line"))
          (unless symbol-name
            (error "Missing required parameter: symbol"))

          ;; Visit the specified file
          (let* ((full-path (expand-file-name file-path (claude-code-normalize-project-root (projectile-project-root))))
                 (buffer (find-file-noselect full-path)))
            (with-current-buffer buffer
              ;; Check if LSP is active in this buffer
              (unless (bound-and-true-p lsp-mode)
                (error "LSP is not active in buffer: %s" (buffer-name)))

              ;; Go to specified position
              (goto-char (point-min))
              (forward-line (1- line))

              ;; Search for the symbol on this line
              (let ((line-end (line-end-position)))
                (if (search-forward symbol-name line-end t)
                    (goto-char (match-beginning 0))
                  ;; If not found, just go to beginning of line
                  (beginning-of-line)))

              ;; Get hover information using lsp-request
              (setq description (claude-code-mcp-get-lsp-hover-info))))

          ;; Return results
          (if description
              `((description . ,description)
                (method . "lsp"))
            (error "No hover information found using LSP")))

      (error
       (error "Failed to describe symbol: %s" (error-message-string err))))))

(defun claude-code-mcp-get-lsp-hover-info ()
  "Get hover information using `lsp-request'."
  (require 'lsp-mode)
  (condition-case nil
      (let* ((params (lsp--text-document-position-params))
             (response (lsp-request "textDocument/hover" params)))

        (when response
          (let* ((contents (or (lsp:hover-contents response) nil))
                 (documentation nil))

            ;; Process contents - can be string, MarkupContent, or MarkedString[]
            (cond
             ;; Simple string
             ((stringp contents)
              (setq documentation contents))

             ;; MarkupContent with kind and value
             ((lsp-markup-content? contents)
              (setq documentation (lsp:markup-content-value contents)))

             ;; Array of MarkedString
             (t
              (let ((doc-parts '()))
                (dolist (item contents)
                  (cond
                   ;; MarkedString with language and value
                   ((lsp-marked-string? item)
                    (let ((lang (lsp:marked-string-language item))
                          (value (lsp:marked-string-value item)))
                      ;; Format as markdown code block
                      (push (format "```%s\n%s\n```" lang value) doc-parts)))
                   ;; Simple string
                   ((stringp item)
                    (push item doc-parts))))
                (when doc-parts
                  (setq documentation (string-join (nreverse doc-parts) "\n\n"))))))

            ;; Return only documentation
            (when documentation
              `((documentation . ,documentation))))))

    (error nil)))

;;; Command Confirmation Popup

(defun claude-code-show-command-confirmation-popup (command project-root)
  "Show confirmation popup for COMMAND execution in PROJECT-ROOT.
Returns t if user confirms (y), nil if user declines (n)."
  (let ((buffer-name " *command-confirmation*")
        (working-dir (or project-root default-directory))
        (confirmation nil))
    
    ;; Create popup content
    (with-current-buffer (get-buffer-create buffer-name)
      (erase-buffer)
      (insert (propertize "⚡ COMMAND EXECUTION REQUEST" 'face 'warning))
      (insert "\n\n")
      (insert (propertize "Command:" 'face 'font-lock-keyword-face))
      (insert "\n")
      (insert (propertize command 'face 'font-lock-string-face))
      (insert "\n\n")
      ;; (insert (propertize "Working Directory:" 'face 'font-lock-keyword-face))
      ;; (insert "\n")
      ;; (insert (propertize working-dir 'face 'font-lock-comment-face))
      ;; (insert "\n\n")
      (insert (propertize "Execute this command?" 'face 'font-lock-builtin-face))
      (insert "\n\n")
      (insert (propertize "[y] Yes, execute    [n] No, cancel" 'face 'success))
      (goto-char (point-min)))
    
    ;; Show popup using posframe if available, otherwise use pop-to-buffer
    (unwind-protect
        (if (fboundp 'posframe-show)
            ;; Use posframe for better popup experience
            (progn
              (posframe-show buffer-name
                           :poshandler #'posframe-poshandler-frame-center
                           :width 60
                           :height 12
                           :border-width 2
                           :border-color "#555555"
                           :background-color (face-background 'default)
                           :foreground-color (face-foreground 'default)
                           :internal-border-width 8
                           :left-fringe 8
                           :right-fringe 8)
              
              ;; Wait for user input
              (let ((key nil))
                (while (not (memq key '(?y ?n ?Y ?N ?\C-g)))
                  (setq key (read-key "Execute command? [y/n]: "))
                  (unless (memq key '(?y ?n ?Y ?N ?\C-g))
                    (message "Please press 'y' for yes or 'n' for no")))
                
                (setq confirmation (memq key '(?y ?Y))))
              
              (posframe-hide buffer-name))
          
          ;; Fallback to regular buffer popup
          (pop-to-buffer buffer-name)
          (let ((key nil))
            (while (not (memq key '(?y ?n ?Y ?N ?\C-g)))
              (setq key (read-key "Execute command? [y/n]: "))
              (unless (memq key '(?y ?n ?Y ?N ?\C-g))
                (message "Please press 'y' for yes or 'n' for no")))
            
            (setq confirmation (memq key '(?y ?Y))))
          
          (quit-window t))
      
      ;; Cleanup
      (when (get-buffer buffer-name)
        (kill-buffer buffer-name)))
    
    confirmation))

;;; Terminal Output Size and State Tracking

(defvar claude-code-mcp-output-size-limit 25000
  "Maximum allowed output size before marking as large output interruption.")

(defvar claude-code-mcp-command-states (make-hash-table :test 'equal)
  "Hash table tracking command execution states by terminal ID.")

(defvar claude-code-mcp-terminal-buffer-corrupted (make-hash-table :test 'equal)
  "Hash table tracking buffer corruption state by terminal ID.")

(cl-defstruct claude-code-mcp-command-state
  "Command execution state structure."
  start-time
  output-size
  interrupted
  large-output-detected
  timeout-detected)

(defun claude-code-mcp-init-command-state (terminal-id)
  "Initialize command state for TERMINAL-ID."
  (puthash terminal-id
           (make-claude-code-mcp-command-state
            :start-time (current-time)
            :output-size 0
            :interrupted nil
            :large-output-detected nil
            :timeout-detected nil)
           claude-code-mcp-command-states))

(defun claude-code-mcp-update-output-size (terminal-id output)
  "Update output size tracking for TERMINAL-ID with OUTPUT."
  (when-let ((state (gethash terminal-id claude-code-mcp-command-states)))
    (let ((new-size (+ (claude-code-mcp-command-state-output-size state) 
                       (length output))))
      (setf (claude-code-mcp-command-state-output-size state) new-size)
      (when (> new-size claude-code-mcp-output-size-limit)
        (setf (claude-code-mcp-command-state-large-output-detected state) t)
        (setf (claude-code-mcp-command-state-interrupted state) t)))))

(defun claude-code-mcp-check-timeout (terminal-id timeout-seconds)
  "Check if command execution has timed out for TERMINAL-ID."
  (when-let ((state (gethash terminal-id claude-code-mcp-command-states)))
    (let ((elapsed (float-time (time-subtract (current-time) 
                                             (claude-code-mcp-command-state-start-time state)))))
      (when (> elapsed timeout-seconds)
        (setf (claude-code-mcp-command-state-timeout-detected state) t)
        (setf (claude-code-mcp-command-state-interrupted state) t)
        t))))

(defun claude-code-mcp-validate-buffer-state (buffer)
  "Validate and recover buffer state for BUFFER."
  (condition-case err
      (with-current-buffer buffer
        (let ((point-max (point-max))
              (point-min (point-min))
              (current-point (point)))
          ;; Check for buffer position corruption
          (when (or (> current-point point-max)
                    (< current-point point-min))
            (goto-char (min current-point point-max))
            (message "Buffer position corrected: %s" (buffer-name))
            t)))
    (args-out-of-range
     (message "Buffer corruption detected in %s, marking for reset" (buffer-name buffer))
     (when (bound-and-true-p claude-code-terminal-id)
       (puthash claude-code-terminal-id t claude-code-mcp-terminal-buffer-corrupted))
     t)
    (error
     (message "Error validating buffer state: %s" (error-message-string err))
     nil)))

(defun claude-code-mcp-reset-buffer-state (terminal-id)
  "Reset buffer state for TERMINAL-ID after corruption."
  (remhash terminal-id claude-code-mcp-command-states)
  (remhash terminal-id claude-code-mcp-terminal-buffer-corrupted)
  (message "Buffer state reset for terminal: %s" terminal-id))

(defun claude-code-mcp-is-buffer-corrupted (terminal-id)
  "Check if buffer is marked as corrupted for TERMINAL-ID."
  (gethash terminal-id claude-code-mcp-terminal-buffer-corrupted))

;;; Terminal Tool Handlers

(defun claude-code-mcp-handle-getTerminalContent (params)
  "Handle getTerminalContent request with PARAMS.
PARAMS should include 'terminalId' and optionally 'projectRoot'."
  (condition-case err
      (let ((terminal-id (cdr (assoc 'terminalId params)))
            (project-root (cdr (assoc 'projectRoot params))))
        
        (unless terminal-id
          (error "Terminal ID is required"))
        
        (when (fboundp 'claude-code-terminal-get-content)
          (let ((content (claude-code-terminal-get-content terminal-id project-root)))
            (if content
                `((success . t)
                  (content . ,content)
                  (terminalId . ,terminal-id))
              `((success . nil)
                (error . "Terminal not found or no content available"))))))
    (error
     `((success . nil)
       (error . ,(error-message-string err))))))

(defun claude-code-mcp-handle-executeTerminalCommandInEmacs (params)
  "Handle executeTerminalCommand request with PARAMS.
PARAMS should include 'command', and optionally 'terminalId', 'projectRoot', and 'timeout'.
Note: terminalId parameter is ignored - always uses last focused terminal.
Shows confirmation popup before executing and includes buffer corruption detection."
  (let ((command (cdr (assoc 'command params)))
        (project-root (cdr (assoc 'projectRoot params)))
        (timeout-duration (or (cdr (assoc 'timeout params)) 30))
        terminal-id
        buffer)
    
    ;; Validate required parameters
    (unless command
      (error "Command parameter is required"))
    
    ;; Always use last focused terminal ID, ignore the provided terminalId parameter
    (setq terminal-id 
          (when (fboundp 'claude-code-terminal-get-last-focused)
            (claude-code-terminal-get-last-focused)))

    (unless terminal-id
      (message "No focused terminal found, cannot execute command")
      (error "No focused terminal available"))
    
    ;; Check if buffer is corrupted before proceeding
    (when (claude-code-mcp-is-buffer-corrupted terminal-id)
      (message "Terminal buffer %s is corrupted, resetting state" terminal-id)
      (claude-code-mcp-reset-buffer-state terminal-id))
    
    ;; Get terminal buffer and validate its state
    (setq buffer (claude-code-terminal-get-by-id terminal-id project-root))
    (when buffer
      (condition-case err
          (claude-code-mcp-validate-buffer-state buffer)
        (args-out-of-range
         (message "Buffer corruption detected during validation for terminal %s" terminal-id)
         (claude-code-mcp-reset-buffer-state terminal-id)
         (error "Terminal buffer is corrupted and needs to be recreated"))))
    
    ;; Show confirmation popup before executing
    (if (claude-code-show-command-confirmation-popup command project-root)
        ;; User confirmed - execute the command with enhanced monitoring
        (progn
          (unless (fboundp 'claude-code-terminal-execute-command)
            (error "Terminal execute function not available"))
          
          ;; Initialize command state tracking
          (claude-code-mcp-init-command-state terminal-id)
          
          (condition-case exec-err
              ;; Return async marker instead of blocking
              (let ((async-id (format "term-cmd-%d" (random 100000))))
                (list :async-pending t
                      :async-id async-id
                      :async-callback
                      (lambda (callback)
                        ;; Send command to terminal for visual feedback
                        ;; (with-current-buffer (claude-code-terminal-get-by-id terminal-id project-root)
                        ;;   (vterm-send-string command)
                        ;;   (vterm-send-return))
                        
                        ;; Execute async with real callback
                        (claude-code-terminal-execute-command-async 
                         terminal-id 
                         command 
                         (lambda (result)
                           ;; Convert result to MCP format and call callback
                           (let* ((mcp-result `((success . ,(plist-get result :success))
                                               (message . ,(if (plist-get result :success) "Command executed successfully" "Command failed"))
                                               (terminalId . ,terminal-id)
                                               (command . ,command)
                                               (stdout . ,(or (plist-get result :stdout) ""))
                                               (stderr . ,(or (plist-get result :stderr) ""))
                                               (exitCode . ,(or (plist-get result :exit-code) 1))
                                               (timeout . ,(if (plist-get result :timeout) t json-false))
                                               (interrupted . ,json-false)
                                               (largeOutput . ,json-false)
                                               (workingDirectory . ,(or (plist-get result :working-directory) project-root default-directory))
                                               (error . ,(if (plist-get result :success) "" "Command failed")))))
                             (funcall callback mcp-result)))
                         project-root
                         timeout-duration))))
            
            (args-out-of-range
             ;; Buffer corruption occurred during execution
             (message "Buffer corruption during command execution for terminal %s" terminal-id)
             (puthash terminal-id t claude-code-mcp-terminal-buffer-corrupted)
             (remhash terminal-id claude-code-mcp-command-states)
             `((success . nil)
               (message . "Terminal buffer corrupted during command execution")
               (terminalId . ,terminal-id)
               (command . ,command)
               (stdout . "")
               (stderr . "Args out of range: Terminal buffer corrupted")
               (exitCode . 1)
               (timeout . ,json-false)
               (interrupted . t)
               (largeOutput . t)
               (workingDirectory . ,(or project-root default-directory))
               (error . "Args out of range: Terminal buffer corrupted")))
            
            (error
             ;; Other execution errors
             (remhash terminal-id claude-code-mcp-command-states)
             `((success . nil)
               (message . ,(format "Command execution error: %s" (error-message-string exec-err)))
               (terminalId . ,terminal-id)
               (command . ,command)
               (stdout . "")
               (stderr . ,(error-message-string exec-err))
               (exitCode . 1)
               (timeout . ,json-false)
               (interrupted . nil)
               (largeOutput . nil)
               (workingDirectory . ,(or project-root default-directory))
               (error . ,(error-message-string exec-err))))))
      
      ;; User declined - return error indicating cancellation
      `((success . nil)
        (message . "Command execution was cancelled by user")
        (terminalId . ,terminal-id)
        (command . ,command)
        (stdout . "")
        (stderr . "KeyboardInterrupt: User cancelled command execution")
        (exitCode . 130)
        (timeout . ,json-false)
        (interrupted . nil)
        (largeOutput . nil)
        (workingDirectory . ,(or project-root default-directory))
        (error . "KeyboardInterrupt: User cancelled command execution")))))

(defun claude-code-mcp-handle-getTerminalList (params)
  "Handle getTerminalList request with PARAMS.
PARAMS can optionally include 'projectRoot'."
  (condition-case err
      (let ((project-root (cdr (assoc 'projectRoot params))))
        
        (when (fboundp 'claude-code-terminal-list-active)
          (let ((terminals (claude-code-terminal-list-active)))
            ;; Filter by project root if specified
            (when project-root
              (setq terminals (cl-remove-if-not 
                              (lambda (term) 
                                (string= (plist-get term :project-root) project-root))
                              terminals)))
            
            ;; Convert to MCP format
            (let ((terminal-list (mapcar (lambda (term)
                                          `((terminalId . ,(plist-get term :terminal-id))
                                            (bufferName . ,(plist-get term :buffer-name))
                                            (projectRoot . ,(plist-get term :project-root))))
                                        terminals)))
              `((success . t)
                (terminals . ,terminal-list)
                (count . ,(length terminal-list)))))))
    (error
     `((success . nil)
       (error . ,(error-message-string err))))))

(defun claude-code-mcp-handle-createTerminal (params)
  "Handle createTerminal request with PARAMS.
PARAMS can optionally include 'directory' and 'projectRoot'."
  (condition-case err
      (let ((directory (cdr (assoc 'directory params)))
            (project-root (cdr (assoc 'projectRoot params))))
        
        (when (fboundp 'claude-code-terminal-create)
          ;; Set project root temporarily if specified
          (let ((default-directory (or directory 
                                      project-root 
                                      (claude-code-normalize-project-root (projectile-project-root)))))
            (let ((terminal-id (claude-code-terminal-create directory)))
              (if terminal-id
                  `((success . t)
                    (terminalId . ,terminal-id)
                    (message . "Terminal created successfully")
                    (directory . ,default-directory))
                `((success . nil)
                  (error . "Failed to create terminal")))))))
    (error
     `((success . nil)
       (error . ,(error-message-string err))))))

;;; Notification handler

(defun claude-code-mcp-handle-sendNotification (params)
  "Handle sendNotification request with PARAMS.
PARAMS should include \\='title\\=' and \\='message\\='."
  (let ((title (cdr (assoc 'title params)))
        (message-text (cdr (assoc 'message params))))

    ;; Validate required parameters
    (unless title
      (error "Title is required"))
    (unless message-text
      (error "Message is required"))

    ;; Send notification using alert if available, otherwise use message
    (if (fboundp 'alert)
        (alert message-text
               :title title
               :category 'claude-code)
      ;; Fallback to message if alert is not available
      (message "[%s] %s" title message-text))

    ;; Return success response
    `((success . t)
      (message . "Notification sent"))))

(provide 'claude-code-mcp-tools)
;;; claude-code-mcp-tools.el ends here
