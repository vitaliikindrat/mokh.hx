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
         mokh-send-file
         mokh-accept
         mokh-reject
         mokh-edit
         mokh-next-hunk
         mokh-prev-hunk
         mokh-configure!)

;;;; configuration

(define *bridge-command* "mokh-bridge")
(define *ide-name* "Helix")
(define *diff-root* "/tmp/mokh-hx")
;; Off by default: with it on, Claude's prompt always shows "in <file>" for
;; whatever buffer is focused. `mokh-send` / `mokh-send-file` are explicit.
(define *track-selection* #f)
;; 'auto: inline when hx has the virtual-text API, else the split view.
(define *inline* 'auto)

;;@doc
;; Configure mokh before `mokh-start`. Keywords: #:bridge (path to
;; mokh-bridge), #:ide-name (what Claude's /ide shows), #:diff-root
;; (where proposal files are written), #:track-selection (push the
;; selection to Claude as you move, default #f).
(define (mokh-configure! #:bridge (bridge #f)
                         #:ide-name (ide-name #f)
                         #:diff-root (diff-root #f)
                         #:track-selection (track 'unset)
                         #:inline (inline 'unset))
  (when bridge (set! *bridge-command* bridge))
  (when ide-name (set! *ide-name* ide-name))
  (when diff-root (set! *diff-root* diff-root))
  (unless (equal? track 'unset) (set! *track-selection* track))
  (unless (equal? inline 'unset) (set! *inline* inline)))

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

;;;; openDiff. Two renderings:
;;;;
;;;; * inline (default when hx has the virtual-text API, see the patch in
;;;;   the README): the change is shown in the real buffer -- lines Claude
;;;;   deletes get a red background, lines it adds appear as green rows
;;;;   below the line they follow -- and the cursor lands on the first hunk.
;;;; * split (fallback, or #:inline #f): the unified diff in a vertical
;;;;   split with `diff` highlighting, cursor on the first hunk.
;;;;
;;;; Accept answers FILE_SAVED plus the proposal text and Claude then writes
;;;; the file itself; reject answers DIFF_REJECTED. `:mokh-edit` opens the
;;;; proposal as an editable buffer when you want to change it before
;;;; accepting; its text is then what goes back.

;; The virtual-text functions exist only in a patched hx; look them up at
;; load time (through the builtin module, which eval-string can reach) so
;; this file still loads without them.
(define (lookup-virtual-text name)
  (with-handler (lambda (_) #f)
                (eval-string (string-append "(require-builtin helix/core/misc as vt.) vt." name))))
(define vt-add-lines (lookup-virtual-text "add-virtual-lines"))
(define vt-add-highlight (lookup-virtual-text "add-line-highlight"))
(define vt-remove (lookup-virtual-text "remove-virtual-text"))

(define (inline-available?)
  (and (function? vt-add-lines) (function? vt-add-highlight) (function? vt-remove)))

(define (inline-enabled?)
  (cond
    [(equal? *inline* 'auto) (inline-available?)]
    [else (and *inline* (inline-available?))]))

;; "@@ -12,5 +12,6 @@" -> (11 . 11): 0-based old and new start lines
(define (hunk-starts line)
  (let* ([parts (split-many (substring line 3 (string-length line)) " ")]
         [old (car (split-many (substring (car parts) 1 (string-length (car parts))) ","))]
         [new (car (split-many (substring (cadr parts) 1 (string-length (cadr parts))) ","))])
    (cons (max 0 (- (string->int old) 1)) (max 0 (- (string->int new) 1)))))

;; Unified diff text -> list of (hash 'old-start n 'ops (list (cons tag text) ...))
;; with tags 'ctx, 'del, 'add. Header lines before the first hunk are skipped.
(define (parse-unified-diff text)
  (define (finish hunk) (hash-insert hunk 'ops (reverse (hash-ref hunk 'ops))))
  (let loop ([lines (split-many text "\n")] [hunks '()] [cur #f])
    (cond
      [(null? lines) (reverse (if cur (cons (finish cur) hunks) hunks))]
      [else
       (let ([line (car lines)])
         (cond
           [(starts-with? line "@@ ")
            (loop (cdr lines)
                  (if cur (cons (finish cur) hunks) hunks)
                  (let ([starts (hunk-starts line)])
                    (hash 'old-start (car starts) 'new-start (cdr starts) 'ops '())))]
           [(not cur) (loop (cdr lines) hunks cur)]
           [(equal? line "") (loop (cdr lines) hunks cur)]
           [else
            (let* ([tag (substring line 0 1)]
                   [body (substring line 1 (string-length line))]
                   [op (cond
                         [(equal? tag "-") (cons 'del body)]
                         [(equal? tag "+") (cons 'add body)]
                         [(equal? tag " ") (cons 'ctx body)]
                         [else #f])])
              (loop (cdr lines)
                    hunks
                    (if op (hash-insert cur 'ops (cons op (hash-ref cur 'ops))) cur)))]))])))

(define (virtual-row text)
  (hash 'style "ui.virtual.diff.plus"
        'spans (list (hash 'text (string-append "+ " (string-replace text "\t" "    "))
                           'style "diff.plus"))))

;; Render one hunk into the focused (old) buffer. A hunk can hold several
;; change runs (del/add lines separated by context); each run is recorded
;; as (old-line . new-line) so navigation and :mokh-edit go per change.
;; Returns (cons changes item-ids) with changes a list of pairs.
(define (render-hunk! hunk)
  (define old (hash-ref hunk 'old-start))
  (define new (hash-ref hunk 'new-start))
  (define ids '())
  (define adds '())
  (define changes '())
  (define in-change #f)
  (define (start-change! old-line new-line)
    (unless in-change
      (set! in-change #t)
      (set! changes (cons (cons old-line new-line) changes))))
  (define (flush-adds!)
    (unless (null? adds)
      (let* ([anchor (max 0 (- old 1))]
             [json (value->jsexpr-string (map virtual-row (reverse adds)))]
             [id (vt-add-lines anchor json)])
        (when id (set! ids (cons id ids))))
      (set! adds '())))
  (for-each (lambda (op)
              (cond
                [(equal? (car op) 'ctx)
                 (flush-adds!)
                 (set! in-change #f)
                 (set! old (+ old 1))
                 (set! new (+ new 1))]
                [(equal? (car op) 'del)
                 (flush-adds!)
                 (start-change! old new)
                 (let ([id (vt-add-highlight old "ui.virtual.diff.minus")])
                   (when id (set! ids (cons id ids))))
                 (set! old (+ old 1))]
                [else
                 ;; an insertion lands below the previous old line
                 (start-change! (max 0 (- old 1)) new)
                 (set! adds (cons (cdr op) adds))
                 (set! new (+ new 1))]))
            (hash-ref hunk 'ops))
  (flush-adds!)
  (cons (reverse changes) ids))

(define (goto-line! line)
  (helix.goto (number->string (+ 1 line)))
  (helix.static.align_view_center))

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
  (define base (hash 'id id
                     'tab tab
                     'old-path old-path
                     'new-path new-path
                     'contents contents
                     'proposal proposal
                     'proposal-doc #f
                     'diff-doc #f
                     'doc #f
                     'items '()
                     'hunk-lines '()
                     'hunk-new-lines '()
                     'origin origin
                     'status "pending"))
  (define record
    (if (and (inline-enabled?) (path-exists? old-path))
        (begin
          (helix.open old-path)
          (let* ([doc (editor->doc-id (editor-focus))]
                 [rendered (map render-hunk! (parse-unified-diff diff))]
                 [changes (apply append (map car rendered))]
                 [lines (map car changes)]
                 [new-lines (map cdr changes)]
                 [ids (apply append (map cdr rendered))])
            (unless (null? lines) (goto-line! (car lines)))
            (hash-insert (hash-insert (hash-insert (hash-insert base 'doc doc) 'items ids)
                                      'hunk-lines lines)
                         'hunk-new-lines new-lines)))
        (begin
          (helix.vsplit-new)
          (set-scratch-buffer-name! (string-append "[mokh] " (file-name new-path)))
          (helix.static.insert_string diff)
          (helix.static.goto_file_start)
          (helix.static.collapse_selection)
          (helix.set-language "diff")
          ;; cursor on the first hunk header
          (let loop ([lines (split-many diff "\n")] [i 0])
            (cond
              [(null? lines) void]
              [(starts-with? (car lines) "@@ ") (goto-line! i)]
              [else (loop (cdr lines) (+ i 1))]))
          (let ([hunks (parse-unified-diff diff)])
            (hash-insert (hash-insert base 'diff-doc (editor->doc-id (editor-focus)))
                         'hunk-new-lines (map (lambda (h) (hash-ref h 'new-start)) hunks))))))
  (set! *diffs* (hash-insert *diffs* tab record))
  (status (diff-summary (file-name new-path) (exact (round added)) (exact (round removed))))
  #f)

;; Run thunk with `doc` focused in some window (its own, or the current one).
(define (with-doc-focused doc thunk)
  (let ([view (editor-doc-in-view? doc)])
    (if view
        (with-focus view thunk)
        (begin (editor-switch! doc) (thunk)))))

(define (remove-inline-items! d)
  (let ([doc (hash-ref d 'doc)] [ids (hash-ref d 'items)])
    (when (and doc (not (null? ids)) (editor-doc-exists? doc))
      (with-doc-focused doc (lambda () (for-each (lambda (id) (vt-remove id)) ids))))))

;;@doc
;; Jump to the next hunk of the Claude diff under review
(define (mokh-next-hunk) (jump-hunk 'next))

;;@doc
;; Jump to the previous hunk of the Claude diff under review
(define (mokh-prev-hunk) (jump-hunk 'prev))

(define (jump-hunk direction)
  (let ([d (current-diff)])
    (cond
      [(or (not d) (null? (hash-ref d 'hunk-lines))) (status "mokh: no inline diff here")]
      [else
       (let* ([here (helix.static.get-current-line-number)]
              [lines (hash-ref d 'hunk-lines)]
              [candidates (filter (lambda (l) (if (equal? direction 'next) (> l here) (< l here))) lines)]
              [target (cond
                        [(null? candidates) (if (equal? direction 'next) (car lines) (car (reverse lines)))]
                        [(equal? direction 'next) (apply min candidates)]
                        [else (apply max candidates)])])
         (with-doc-focused (hash-ref d 'doc) (lambda () void))
         (goto-line! target)
         (status (string-append "mokh: hunk "
                                (number->string (+ 1 (length (filter (lambda (l) (< l target)) lines))))
                                "/" (number->string (length lines)))))])))

(define (same-doc? a b)
  (and a b (equal? (doc-id->usize a) (doc-id->usize b))))

(define (diff-for-doc doc)
  (let loop ([tabs (hash-keys->list *diffs*)])
    (cond
      [(null? tabs) #f]
      [else
       (let ([d (hash-ref *diffs* (car tabs))])
         (if (or (same-doc? doc (hash-ref d 'proposal-doc))
                 (same-doc? doc (hash-ref d 'diff-doc))
                 (same-doc? doc (hash-ref d 'doc)))
             d
             (loop (cdr tabs))))])))

;;@doc
;; Open Claude's proposed file as an editable buffer (in the diff's window,
;; or a split next to an inline review); what you leave in it is what
;; :mokh-accept (or :w) sends back
(define (mokh-edit)
  (let ([d (current-diff)])
    (cond
      [(not d) (status "mokh: no pending diff here")]
      [(hash-ref d 'proposal-doc)
       (editor-set-focus! (or (editor-doc-in-view? (hash-ref d 'proposal-doc)) (editor-focus)))]
      [else
       (let ([diff-view (and (hash-ref d 'diff-doc) (editor-doc-in-view? (hash-ref d 'diff-doc)))]
             [target (edit-target-line d)])
         (if diff-view
             (editor-set-focus! diff-view) ; reuse the diff window
             (helix.vsplit))
         (helix.open (hash-ref d 'proposal))
         (when target (goto-line! target))
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
    (remove-inline-items! d)
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

;;@doc
;; Send the focused file to Claude Code as an @-mention (whole file)
(define (mokh-send-file)
  (cond
    [(not (running?)) (status "mokh: not running (:mokh-start)")]
    [(= *connections* 0) (status "mokh: no Claude session attached (run /ide in Claude Code)")]
    [else
     (let ([path (doc-path (editor->doc-id (editor-focus)))])
       (if (not path)
           (status "mokh: the focused buffer has no file")
           (begin
             (notify! "at_mentioned" (at-mention-file-json path))
             (status (string-append "mokh: sent " (file-name path))))))]))

;;;; hooks

(register-hook 'selection-did-change (lambda (_view) (push-selection!)))
(register-hook 'document-saved on-document-saved)

;; Where in the proposal to put the cursor for :mokh-edit: the hunk the
;; cursor is on in the inline review (the last one starting at or before
;; it), else the first hunk.
(define (edit-target-line d)
  (let ([olds (hash-ref d 'hunk-lines)] [news (hash-ref d 'hunk-new-lines)])
    (cond
      [(null? news) #f]
      [else
       (let* ([on-old-doc (and (hash-ref d 'doc)
                               (same-doc? (editor->doc-id (editor-focus)) (hash-ref d 'doc)))]
              [here (if on-old-doc (helix.static.get-current-line-number) -1)]
              [idx (let loop ([i 0] [best 0])
                     (cond
                       [(>= i (length olds)) best]
                       [(<= (list-ref olds i) here) (loop (+ i 1) i)]
                       [else (loop (+ i 1) best)]))])
         (list-ref news (min idx (- (length news) 1))))])))
