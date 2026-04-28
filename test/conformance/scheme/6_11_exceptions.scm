;; Curated from Chibi-Scheme r7rs-tests.scm §6.11 "Exceptions".
;; Source: https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests.scm
;;
;; Excluded from the upstream section, with reasons:
;;   - `file-error?` test on `open-input-file` at lines 1808-1809:
;;     no file I/O in Schooner.
;;   - `read-error?` test using `open-input-string` at 1813-1816:
;;     `open-input-string` and string ports aren't in Schooner's
;;     surface (PLAN.md leaves the port abstraction out of v1
;;     beyond what `(scheme read)` needs internally).
;;   - `test-exception-handler-1` cluster at 1818-1831,
;;     `test-exception-handler-2` at 1833-1845: rely on `set!` to
;;     observe handler side effects. Mutation is out of scope; the
;;     handler logic itself is exercised by the SRFI-34 sub-tests
;;     below.
;;   - The R6RS-style `with-exception-handler` + `open-output-string`
;;     test at 1849-1865, `test-exception-handler-3` at 1868-1879,
;;     `test-exception-handler-4` at 1881-1911: all use string-port
;;     output for assertion. The pure-value form of the same logic
;;     is captured by the SRFI-34 #8/#9 cases below.

(test-begin "6.11 Exceptions")

(test 65
    (with-exception-handler
     (lambda (con) 42)
     (lambda ()
       (+ (raise-continuable "should be a number")
          23))))

(test #t
    (error-object? (guard (exn (else exn)) (error "BOOM!" 1 2 3))))
(test "BOOM!"
    (error-object-message (guard (exn (else exn)) (error "BOOM!" 1 2 3))))
(test '(1 2 3)
    (error-object-irritants (guard (exn (else exn)) (error "BOOM!" 1 2 3))))

(test #f
    (file-error? (guard (exn (else exn)) (error "BOOM!"))))

(test #f
    (read-error? (guard (exn (else exn)) (error "BOOM!"))))

;; From SRFI-34 "Examples" section - #8
(test 42
    (guard (condition
            ((assq 'a condition) => cdr)
            ((assq 'b condition)))
      (raise (list (cons 'a 42)))))

;; From SRFI-34 "Examples" section - #9
(test '(b . 23)
    (guard (condition
            ((assq 'a condition) => cdr)
            ((assq 'b condition)))
      (raise (list (cons 'b 23)))))

;; The upstream nested-guard test at lines 1927-1936 builds a
;; `(list (sqrt 8) (guard ...))` where `(sqrt 8)` is incidental.
;; Schooner has no rational tower, so `(sqrt 8)` raises before the
;; inner `guard` runs. The semantically interesting piece — the
;; outer guard catching the inner `raise` — is preserved by
;; substituting `'placeholder` for the irrational `(sqrt 8)`.
(test 'caught-d
    (guard (condition
            ((assq 'c condition) 'caught-c)
            ((assq 'd condition) 'caught-d))
      (list
       'placeholder
       (guard (condition
               ((assq 'a condition) => cdr)
               ((assq 'b condition)))
         (raise (list (cons 'd 24)))))))

(test-end)
