;; mokh.hx -- Claude Code IDE integration for Helix (Steel).
;;
;; `mokh-bridge` (a small Rust process) speaks Claude Code's IDE protocol:
;; it writes the lock file Claude's `/ide` looks for, serves the WebSocket,
;; and turns MCP tool calls into JSON lines on its stdout. This file reads
;; those lines on a background thread, answers them with editor state on the
;; UI thread, and pushes selection changes back. Nothing here touches the
;; network.
;;
;;   (require "mokh/mokh.scm")
;;   (mokh-start)                 ; or bind :mokh-start
;;
;; Then in Claude Code (in a terminal next to hx): `/ide` -> Helix.

(require "helix/editor.scm")
(require "helix/misc.scm")
(require "helix/ext.scm")
(require (prefix-in helix. "helix/commands.scm"))
(require (prefix-in helix.static. "helix/static.scm"))
(require-builtin helix/core/text as text.)
(require-builtin steel/process)
(require-builtin steel/threads)
(require-builtin steel/time)
(require "util.scm")

(provide mokh-start
         mokh-stop
         mokh-status
         mokh-send
         mokh-accept
         mokh-reject
         mokh-edit
         mokh-configure!)

;;;; configuration

(define *bridge-command* "mokh-bridge")
(define *ide-name* "Helix")
(define *diff-root* "/tmp/mokh-hx")
(define *track-selection* #t)

;;@doc
;; Configure mokh before `mokh-start`. Keywords: #:bridge (path to
;; mokh-bridge), #:ide-name (what Claude's /ide shows), #:diff-root
;; (where proposal files are written), #:track-selection (push the
;; selection to Claude as you move, default #t).
(define (mokh-configure! #:bridge (bridge #f)
                         #:ide-name (ide-name #f)
                         #:diff-root (diff-root #f)
                         #:track-selection (track 'unset))
  (when bridge (set! *bridge-command* bridge))
  (when ide-name (set! *ide-name* ide-name))
  (when diff-root (set! *diff-root* diff-root))
  (unless (equal? track 'unset) (set! *track-selection* track)))

;;;; state

(define *child* #f)
(define *to-bridge* #f)
(define *port* #f)
(define *connections* 0)
(define *diffs* (hash))          ; tab-name -> diff record (hash)
(define *latest-selection* #f)
(define *last-sent* #f)
(define *session-dir* #f)

(define (running?) (and *child* #t))

;;;; wire helpers

(define (send! value)
  (when *to-bridge*
    (write-string (value->jsexpr-string value) *to-bridge*)
    (write-string "\n" *to-bridge*)
    (flush-output-port *to-bridge*)))

(define (reply! id result) (send! (hash 'id id 'result result)))
(define (reply-error! id message) (send! (hash 'id id 'error message)))
(define (notify! method params) (send! (hash 'method method 'params params)))

(define (status msg) (set-status! msg))

;;;; document helpers

(define (doc-path doc)
  (let ([p (editor-document->path doc)])
    (if (and p (not (void? p)) (string? p)) p #f)))

(define (doc-text doc) (text.rope->string (editor->text doc)))

(define (find-doc-by-path path)
  (let loop ([docs (editor-all-documents)])
    (cond
      [(null? docs) #f]
      [(equal? (doc-path (car docs)) path) (car docs)]
      [else (loop (cdr docs))])))

(define (write-file! path content)
  (let ([port (open-output-file path)])
    (write-string content port)
    (close-output-port port)))

(define (ensure-dir! path)
  (unless (path-exists? path) (hx.create-directory path)))

;; Run thunk with the focus moved to `view`, then restore focus and mode.
(define (with-focus view thunk)
  (define previous (editor-focus))
  (define mode (editor-mode))
  (editor-set-focus! view)
  (thunk)
  (when (editor-doc-exists? (editor->doc-id previous))
    (editor-set-focus! previous))
  (editor-set-mode! mode))

;;;; selection

;; The focused document's primary selection in Claude's shape, or #f when
;; the focused buffer has no file.
(define (focused-selection)
  (define doc (editor->doc-id (editor-focus)))
  (define path (doc-path doc))
  (if (not path)
      #f
      (let* ([rope (editor->text doc)]
             [range (helix.static.selection->primary-range (helix.static.current-selection-object))]
             [from (helix.static.range->from range)]
             [to (helix.static.range->to range)]
             ;; Helix's cursor is a one-character selection; Claude should
             ;; see that as "no selection", like a bare cursor in VS Code.
             [bare-cursor (<= (- to from) 1)]
             [to (if bare-cursor from to)]
             [start-line (text.rope-char->line rope from)]
             [end-line (text.rope-char->line rope to)]
             [start-char (- from (text.rope-line->char rope start-line))]
             [end-char (- to (text.rope-line->char rope end-line))]
             [text (if bare-cursor "" (helix.static.current-highlighted-text!))])
        (selection-json path text start-line start-char end-line end-char))))

(define (remember-selection!)
  (let ([sel (focused-selection)])
    (when sel (set! *latest-selection* sel))
    sel))

(define (push-selection!)
  (when (and (running?)
             *track-selection*
             (> *connections* 0)
             ;; A proposal buffer lives under the temp dir; Claude should not
             ;; be told the user is "looking at" that path.
             (not (diff-for-doc (editor->doc-id (editor-focus)))))
    (let ([sel (remember-selection!)])
      (when (and sel (not (equal? sel *last-sent*)))
        (set! *last-sent* sel)
        (notify! "selection_changed" sel)))))

;;;; tools: the editor side of each MCP tool. Each returns a result value,
;;;; or #f when the reply is deferred (openDiff).

(define (tool-open-file id params)
  (define path (json-string params 'filePath))
  (define start-text (json-string params 'startText))
  (define end-text (json-string params 'endText))
  (unless path (error! "openFile: filePath is required"))
  (helix.open path)
  (when start-text
    (helix.static.select_all)
    (helix.static.regex-selection
     (if end-text
         (string-append (regex-escape start-text) "(?s:.*?)" (regex-escape end-text))
         (regex-escape start-text)))
    (helix.static.keep_primary_selection)
    (unless end-text (helix.static.collapse_selection))
    (helix.static.align_view_center))
  (hash 'success #t 'filePath path))

(define (tool-current-selection id params)
  (or (remember-selection!) (empty-selection-json)))

(define (tool-latest-selection id params)
  (or *latest-selection* (remember-selection!) (empty-selection-json)))

(define (tool-open-editors id params)
  (define active (editor->doc-id (editor-focus)))
  (open-editors-json
   (filter (lambda (e) (car e))
           (map (lambda (doc)
                  (list (doc-path doc)
                        (equal? (doc-id->usize doc) (doc-id->usize active))
                        (let ([l (editor-document->language doc)]) (if (string? l) l "plaintext"))
                        (editor-document-dirty? doc)))
                (editor-all-documents)))))

;; Helix exposes diagnostic counts to Steel, not the diagnostics themselves.
(define (tool-diagnostics id params)
  (list))

(define (tool-document-dirty id params)
  (define path (json-string params 'filePath))
  (define doc (and path (find-doc-by-path path)))
  (if doc
      (hash 'success #t 'filePath path 'isDirty (editor-document-dirty? doc) 'isUntitled #f)
      (hash 'success #f 'message (string-append "Document not open: " (or path "")))))

(define (tool-save-document id params)
  (define path (json-string params 'filePath))
  (define doc (and path (find-doc-by-path path)))
  (cond
    [(not doc) (hash 'success #f 'message (string-append "Document not open: " (or path "")))]
    [else
     (let ([view (editor-doc-in-view? doc)])
       (if view
           (with-focus view (lambda () (helix.write)))
           (begin
             (helix.vsplit-new)
             (editor-switch! doc)
             (helix.write)
             (helix.quit!))))
     (hash 'success #t 'filePath path 'saved #t 'message "Document saved successfully")]))

(define (tool-close-tab id params)
  (define tab (json-string params 'tab_name))
  (when (and tab (hash-contains? *diffs* tab))
    (close-diff! tab))
  "TAB_CLOSED")

(define (tool-close-all-diffs id params)
  (define n (length (hash-keys->list *diffs*)))
  (for-each (lambda (tab) (close-diff! tab)) (hash-keys->list *diffs*))
  (string-append "CLOSED_" (number->string n) "_DIFF_TABS"))

;;;; openDiff: the unified diff in one vertical split, in `diff` highlighting.
;;;; Accept answers FILE_SAVED plus the proposal text and Claude then writes
;;;; the file itself; reject answers DIFF_REJECTED. `:mokh-edit` opens the
;;;; proposal as an editable buffer for the cases where you want to change
;;;; it before accepting; its text is then what goes back.

(define (tool-open-diff id params)
  (define tab (or (json-string params 'tab_name) "diff"))
  (define old-path (or (json-string params 'old_file_path) ""))
  (define new-path (or (json-string params 'new_file_path) old-path))
  (define contents (or (json-string params 'new_file_contents) ""))
  (define diff (or (json-string params 'diff) ""))
  (define added (json-get params 'added 0))
  (define removed (json-get params 'removed 0))
  (when (hash-contains? *diffs* tab) (close-diff! tab))
  (define dir (string-append *session-dir* "/" (sanitize-tab-name tab)))
  (ensure-dir! dir)
  (define proposal (string-append dir "/" (file-name new-path)))
  (write-file! proposal contents)
  (define origin (editor-focus))
  (helix.vsplit-new)
  (set-scratch-buffer-name! (string-append "[mokh] " (file-name new-path)))
  (helix.static.insert_string diff)
  (helix.static.goto_file_start)
  (helix.static.collapse_selection)
  (helix.set-language "diff")
  (define diff-view (editor-focus))
  (define diff-doc (editor->doc-id diff-view))
  (set! *diffs*
        (hash-insert *diffs* tab
                     (hash 'id id
                           'tab tab
                           'old-path old-path
                           'new-path new-path
                           'contents contents
                           'proposal proposal
                           'proposal-doc #f
                           'diff-doc diff-doc
                           'origin origin
                           'status "pending")))
  (status (diff-summary (file-name new-path) (exact (round added)) (exact (round removed))))
  #f)

(define (same-doc? a b)
  (and a b (equal? (doc-id->usize a) (doc-id->usize b))))

(define (diff-for-doc doc)
  (let loop ([tabs (hash-keys->list *diffs*)])
    (cond
      [(null? tabs) #f]
      [else
       (let ([d (hash-ref *diffs* (car tabs))])
         (if (or (same-doc? doc (hash-ref d 'proposal-doc))
                 (same-doc? doc (hash-ref d 'diff-doc)))
             d
             (loop (cdr tabs))))])))

;;@doc
;; Open Claude's proposed file in an editable buffer below the diff; what
;; you leave in it is what :mokh-accept (or :w) sends back
(define (mokh-edit)
  (let ([d (current-diff)])
    (cond
      [(not d) (status "mokh: no pending diff here")]
      [(hash-ref d 'proposal-doc)
       (editor-set-focus! (or (editor-doc-in-view? (hash-ref d 'proposal-doc)) (editor-focus)))]
      [else
       (let ([diff-view (editor-doc-in-view? (hash-ref d 'diff-doc))])
         (when diff-view (editor-set-focus! diff-view))
         (helix.hsplit)
         (helix.open (hash-ref d 'proposal))
         (set! *diffs*
               (hash-insert *diffs* (hash-ref d 'tab)
                            (hash-insert d 'proposal-doc (editor->doc-id (editor-focus))))))])))

;; What accept sends: the edited buffer when the proposal was opened,
;; otherwise Claude's text untouched.
(define (diff-final-text d)
  (let ([doc (hash-ref d 'proposal-doc)])
    (if (and doc (editor-doc-exists? doc))
        (doc-text doc)
        (hash-ref d 'contents))))

;; The diff the user means: the one owning the focused buffer, else the only
;; pending one.
(define (current-diff)
  (or (diff-for-doc (editor->doc-id (editor-focus)))
      (let ([tabs (hash-keys->list *diffs*)])
        (and (= (length tabs) 1) (hash-ref *diffs* (car tabs))))))

(define (resolve-diff! d outcome)
  (when (equal? (hash-ref d 'status) "pending")
    (define tab (hash-ref d 'tab))
    (set! *diffs* (hash-insert *diffs* tab (hash-insert d 'status outcome)))
    (if (equal? outcome "accepted")
        (let ([content (diff-final-text d)])
          (reply! (hash-ref d 'id) (mcp-content (mcp-text "FILE_SAVED") (mcp-text content)))
          (status (string-append "mokh: accepted " (file-name (hash-ref d 'new-path)))))
        (begin
          (reply! (hash-ref d 'id) (mcp-content (mcp-text "DIFF_REJECTED")))
          (status (string-append "mokh: rejected " (file-name (hash-ref d 'new-path))))))
    (close-diff! tab)))

;; Is some document other than `doc` shown in a window? If not, closing
;; doc's window would close the editor.
(define (other-window-exists? doc)
  (let loop ([docs (editor-all-documents)])
    (cond
      [(null? docs) #f]
      [(and (not (equal? (doc-id->usize (car docs)) (doc-id->usize doc)))
            (editor-doc-in-view? (car docs)))
       #t]
      [else (loop (cdr docs))])))

(define (close-view-and-buffer! doc)
  (when (and doc (editor-doc-exists? doc))
    (let ([view (editor-doc-in-view? doc)])
      (when view
        (editor-set-focus! view)
        (when (other-window-exists? doc) (helix.quit!)))
      (editor-switch! doc)
      (helix.buffer-close!))))

(define (close-diff! tab)
  (define d (hash-try-get *diffs* tab))
  (when d
    ;; Claude is still waiting if nobody decided: closing counts as a reject.
    (when (equal? (hash-ref d 'status) "pending")
      (set! *diffs* (hash-insert *diffs* tab (hash-insert d 'status "rejected")))
      (reply! (hash-ref d 'id) (mcp-content (mcp-text "DIFF_REJECTED"))))
    (define previous (editor-focus))
    (close-view-and-buffer! (hash-ref d 'diff-doc))
    (close-view-and-buffer! (hash-ref d 'proposal-doc))
    (set! *diffs* (hash-remove *diffs* tab))
    (when (path-exists? (hash-ref d 'proposal)) (delete-file! (hash-ref d 'proposal)))
    (let ([origin (hash-ref d 'origin)])
      (cond
        [(editor-doc-exists? (editor->doc-id origin)) (editor-set-focus! origin)]
        [(editor-doc-exists? (editor->doc-id previous)) (editor-set-focus! previous)]
        [else void]))))

;;@doc
;; Accept the Claude diff under the cursor (or the only pending one): sends
;; the proposal buffer's current text back as FILE_SAVED
(define (mokh-accept)
  (let ([d (current-diff)])
    (if d (resolve-diff! d "accepted") (status "mokh: no pending diff here"))))

;;@doc
;; Reject the Claude diff under the cursor (or the only pending one)
(define (mokh-reject)
  (let ([d (current-diff)])
    (if d (resolve-diff! d "rejected") (status "mokh: no pending diff here"))))

;; :w in a proposal buffer accepts, like the VS Code extension.
(define (on-document-saved doc)
  (let ([d (diff-for-doc doc)])
    (when (and d (same-doc? doc (hash-ref d 'proposal-doc)))
      (resolve-diff! d "accepted"))))

;;;; dispatch

(define *tools*
  (hash "openFile" tool-open-file
        "openDiff" tool-open-diff
        "getCurrentSelection" tool-current-selection
        "getLatestSelection" tool-latest-selection
        "getOpenEditors" tool-open-editors
        "getDiagnostics" tool-diagnostics
        "checkDocumentDirty" tool-document-dirty
        "saveDocument" tool-save-document
        "close_tab" tool-close-tab
        "closeAllDiffTabs" tool-close-all-diffs))

(define (handle-request id method params)
  (define tool (hash-try-get *tools* method))
  (if (not tool)
      (reply-error! id (string-append "mokh.hx does not implement " method))
      (with-handler
       (lambda (e) (reply-error! id (string-append method ": " (error-object-message e))))
       (let ([result (tool id params)])
         (when result (reply! id result))))))

(define (handle-message msg)
  (define method (json-string msg 'method))
  (define id (json-get msg 'id #f))
  (define params (json-get msg 'params (hash)))
  (cond
    [id (handle-request id (or method "") params)]
    [(equal? method "ready")
     ;; JSON numbers arrive as floats (41281.0); keep the port an integer.
     (let ([port (json-get params 'port #f)])
       (set! *port* (if (number? port) (exact (round port)) port)))
     (status "mokh: bridge ready, run /ide in Claude Code")]
    [(equal? method "connected")
     (set! *connections* (+ *connections* 1))
     (set! *last-sent* #f)
     (status "mokh: Claude Code connected")
     (push-selection!)]
    [(equal? method "disconnected")
     (set! *connections* (max 0 (- *connections* 1)))
     (status "mokh: Claude Code disconnected")]
    [else void]))

(define (reader-loop port)
  (let loop ()
    (define line (read-line-from-port port))
    (unless (eof-object? line)
      (let ([trimmed (trim line)])
        (unless (equal? trimmed "")
          (let ([msg (with-handler (lambda (e) #f) (string->jsexpr trimmed))])
            (when msg
              (hx.with-context (lambda () (handle-message msg)))))))
      (loop)))
  (hx.with-context on-bridge-exit))

(define (on-bridge-exit)
  (when *child*
    (set! *child* #f)
    (set! *to-bridge* #f)
    (set! *connections* 0)
    (status "mokh: bridge exited")))

;;;; lifecycle

;;@doc
;; Start the Claude Code bridge for this workspace; Claude's /ide then
;; lists Helix
(define (mokh-start)
  (if (running?)
      (status "mokh: already running")
      (let* ([workspace (helix-find-workspace)]
             [cmd (with-stdout-piped
                   (with-stdin-piped
                    (command *bridge-command*
                             (list "--ide-name" *ide-name* "--workspace" workspace))))]
             [spawned (spawn-process cmd)])
        (if (Err? spawned)
            (status (string-append "mokh: cannot start " *bridge-command* ": " (to-string (Err->value spawned))))
            (let ([child (Ok->value spawned)])
              (ensure-dir! *diff-root*)
              (set! *session-dir* (string-append *diff-root* "/" (number->string (current-milliseconds))))
              (ensure-dir! *session-dir*)
              (set! *child* child)
              (set! *to-bridge* (child-stdin child))
              (set! *connections* 0)
              (let ([out (child-stdout child)])
                (spawn-native-thread (lambda () (reader-loop out))))
              (status "mokh: starting bridge..."))))))

;;@doc
;; Stop the bridge; pending diffs are rejected and the lock file removed
(define (mokh-stop)
  (if (not (running?))
      (status "mokh: not running")
      (begin
        (for-each (lambda (tab) (close-diff! tab)) (hash-keys->list *diffs*))
        (notify! "shutdown" (hash))
        (let ([child *child*])
          (set! *child* #f)
          (set! *to-bridge* #f)
          (kill child))
        (set! *connections* 0)
        (status "mokh: stopped"))))

;;@doc
;; Show whether the bridge is running and how many Claude sessions are attached
(define (mokh-status)
  (status (cond
            [(not (running?)) "mokh: not running (:mokh-start)"]
            [else (string-append "mokh: bridge on port " (to-string *port*)
                                 ", " (number->string *connections*) " Claude session(s)"
                                 ", " (number->string (length (hash-keys->list *diffs*))) " pending diff(s)")])))

;;@doc
;; Send the current selection to Claude Code as an @-mention (file and lines)
(define (mokh-send)
  (cond
    [(not (running?)) (status "mokh: not running (:mokh-start)")]
    [(= *connections* 0) (status "mokh: no Claude session attached (run /ide in Claude Code)")]
    [else
     (let ([sel (remember-selection!)])
       (if (not sel)
           (status "mokh: the focused buffer has no file")
           (let* ([range (hash-ref sel 'selection)]
                  [start (hash-ref (hash-ref range 'start) 'line)]
                  [end (hash-ref (hash-ref range 'end) 'line)])
             (notify! "at_mentioned" (at-mention-json (hash-ref sel 'filePath) start end))
             (status (string-append "mokh: sent " (file-name (hash-ref sel 'filePath))
                                    ":" (number->string (+ 1 start)) "-" (number->string (+ 1 end)))))))]))

;;;; hooks

(register-hook 'selection-did-change (lambda (_view) (push-selection!)))
(register-hook 'document-saved on-document-saved)
