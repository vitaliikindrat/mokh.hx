;; Run with `sh tests/run-all.sh` or `steel tests/util-test.scm` from the repo root.
(require "../util.scm")

(define failures 0)
(define (check name got expected)
  (if (equal? got expected)
      (displayln "ok   " name)
      (begin
        (set! failures (+ failures 1))
        (displayln "FAIL " name ": got " got ", expected " expected))))

(check "sanitize keeps safe chars" (sanitize-tab-name "main.rs-v2_x") "main.rs-v2_x")
(check "sanitize replaces the rest" (sanitize-tab-name "✻ [Claude Code] main.rs ⧉") "___Claude_Code__main.rs__")
(check "sanitize never empty" (sanitize-tab-name "") "diff")
(check "regex-escape" (regex-escape "a.b(c)[d]+*?") "a\\.b\\(c\\)\\[d\\]\\+\\*\\?")
(check "file-uri" (file-uri "/tmp/x.rs") "file:///tmp/x.rs")
(check "uri->path" (uri->path "file:///tmp/x.rs") "/tmp/x.rs")
(check "uri->path passthrough" (uri->path "/tmp/x.rs") "/tmp/x.rs")

(define sel (selection-json "/p/a.rs" "foo" 1 2 1 5))
(check "selection text" (hash-ref sel 'text) "foo")
(check "selection isEmpty" (hash-ref (hash-ref sel 'selection) 'isEmpty) #f)
(check "selection start" (hash-ref (hash-ref (hash-ref sel 'selection) 'start) 'character) 2)
(check "empty selection isEmpty" (hash-ref (hash-ref (selection-json "/p" "" 0 0 0 0) 'selection) 'isEmpty) #t)
(check "selection serializes"
       (string->jsexpr (value->jsexpr-string sel))
       (string->jsexpr "{\"text\":\"foo\",\"filePath\":\"/p/a.rs\",\"fileUrl\":\"file:///p/a.rs\",\"selection\":{\"start\":{\"line\":1,\"character\":2},\"end\":{\"line\":1,\"character\":5},\"isEmpty\":false}}"))

(define parsed (string->jsexpr "{\"id\":7.0,\"method\":\"openDiff\",\"params\":{\"tab_name\":\"t\",\"flag\":false,\"nothing\":null}}"))
(check "json-get present" (json-string (hash-ref parsed 'params) 'tab_name) "t")
(check "json-get absent -> default" (json-get (hash-ref parsed 'params) 'missing "d") "d")
(check "json-get null -> default" (json-get (hash-ref parsed 'params) 'nothing "d") "d")
(check "json-string non-string -> #f" (json-string (hash-ref parsed 'params) 'flag) #f)

(check "at-mention" (hash-ref (at-mention-json "/p/a.rs" 3 9) 'lineEnd) 9)
(check "at-mention file has no range" (hash-contains? (at-mention-file-json "/p/a.rs") 'lineStart) #f)
(define editors (open-editors-json (list (list "/p/a.rs" #t "rust" #f) (list "/p/b.md" #f "markdown" #t))))
(check "open editors label" (hash-ref (car (hash-ref editors 'tabs)) 'label) "a.rs")
(check "open editors dirty" (hash-ref (cadr (hash-ref editors 'tabs)) 'isDirty) #t)
(check "mcp content" (value->jsexpr-string (mcp-content (mcp-text "FILE_SAVED") (mcp-text "x")))
       "{\"content\":[{\"text\":\"FILE_SAVED\",\"type\":\"text\"},{\"text\":\"x\",\"type\":\"text\"}]}")
(check "diff summary" (diff-summary "a.rs" 3 1) "mokh: a.rs +3 -1 | :mokh-accept (or :w) / :mokh-reject")

(if (> failures 0)
    (begin (displayln failures " failure(s)") (error! "tests failed"))
    (displayln "all util tests passed"))
