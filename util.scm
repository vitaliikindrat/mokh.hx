;; util.scm -- pure helpers for mokh.hx. No helix requires, so `steel` can
;; run tests/ against this file directly.

(provide json-get
         json-string
         sanitize-tab-name
         regex-escape
         file-uri
         uri->path
         selection-json
         empty-selection-json
         at-mention-json
         at-mention-file-json
         open-editors-json
         diff-summary
         mcp-text
         mcp-content)

;; JSON objects from string->jsexpr have symbol keys; absent and `false`
;; both come back as #f from hash-try-get, and null as void.
(define (json-get obj key default)
  (let ([v (hash-try-get obj key)])
    (if (or (not v) (void? v)) default v)))

;; A string field, or #f when absent / not a string.
(define (json-string obj key)
  (let ([v (json-get obj key #f)])
    (if (string? v) v #f)))

;; Tab names look like "✻ [Claude Code] main.rs ⧉"; keep them usable as a
;; directory name.
(define (ascii-letter? c)
  (let ([n (char->integer c)])
    (or (and (>= n 65) (<= n 90)) (and (>= n 97) (<= n 122)))))

(define (sanitize-tab-name name)
  (define (keep? c)
    (or (ascii-letter? c) (char-digit? c) (equal? c #\.) (equal? c #\-) (equal? c #\_)))
  (let ([cleaned (list->string (map (lambda (c) (if (keep? c) c #\_)) (string->list name)))])
    (if (equal? cleaned "") "diff" cleaned)))

;; Escape a literal for use inside a regex.
(define (regex-escape s)
  (define specials (string->list "\\.+*?()[]{}|^$"))
  (list->string
   (foldl (lambda (c acc)
            (if (member c specials) (append acc (list #\\ c)) (append acc (list c))))
          '()
          (string->list s))))

(define (file-uri path)
  (string-append "file://" path))

(define (uri->path uri)
  (if (starts-with? uri "file://") (trim-start-matches uri "file://") uri))

;; The `selection_changed` / `getCurrentSelection` shape Claude expects.
;; Lines and characters are 0-based.
(define (selection-json path text start-line start-char end-line end-char)
  (hash 'text text
        'filePath path
        'fileUrl (file-uri path)
        'selection (hash 'start (hash 'line start-line 'character start-char)
                         'end (hash 'line end-line 'character end-char)
                         'isEmpty (equal? text ""))))

(define (empty-selection-json)
  (hash 'success #f 'message "No active editor with a file"))

(define (at-mention-json path line-start line-end)
  (hash 'filePath path 'lineStart line-start 'lineEnd line-end))

;; A whole file as an @-mention: no line range.
(define (at-mention-file-json path)
  (hash 'filePath path))

;; entries: list of (list path is-active language is-dirty)
(define (open-editors-json entries)
  (hash 'tabs
        (map (lambda (e)
               (hash 'uri (file-uri (car e))
                     'isActive (cadr e)
                     'label (file-name (car e))
                     'languageId (caddr e)
                     'isDirty (cadddr e)))
             entries)))

(define (diff-summary name added removed)
  (string-append "mokh: " name " +" (number->string added) " -" (number->string removed)
                 " | :mokh-accept (or :w) / :mokh-reject"))

;; MCP results are a content list of text items.
(define (mcp-text s) (hash 'type "text" 'text s))
(define (mcp-content . items) (hash 'content items))
