;; Test harness prepended to every conformance section file before
;; the section content runs through Schooner.run/1.
;;
;; The harness mirrors the (chibi test) / SRFI-64 surface used by the
;; upstream Chibi r7rs-tests.scm:
;;
;;   (test expected expr)   — pass when (equal? expr expected)
;;   (test-assert expr)     — pass when expr is truthy
;;   (test-not expr)        — pass when expr is falsy
;;   (test-error expr)      — pass when expr raises a Scheme exception
;;
;; All four failure modes raise a Scheme exception that propagates out
;; through Schooner.run/1 and is reported by ExUnit.  test-begin /
;; test-end / test-group are no-ops; section structure lives in the
;; per-section file rather than in a runtime accumulator (Schooner has
;; no mutation, so a counter-based harness would not work).
;;
;; test-error catches Scheme-level exceptions only — `(error ...)` and
;; `(raise ...)`.  Schooner's primitive type/arity errors raise
;; Schooner.Primitive.Error on the host side and do not enter the
;; Scheme exception handler chain; tests that rely on catching those
;; are excluded from the curated subset.

(import (scheme base)
        (scheme cxr)
        (scheme char)
        (scheme inexact)
        (scheme complex)
        (scheme lazy)
        (scheme write)
        (scheme read)
        (scheme case-lambda))

(define-syntax test
  (syntax-rules ()
    ((_ expected expr)
     (let ((got expr))
       (if (equal? got expected)
           'ok
           (error "test failed"
                  'expr 'expected expected 'got got))))))

(define-syntax test-assert
  (syntax-rules ()
    ((_ expr)
     (if expr 'ok (error "test-assert failed" 'expr)))))

(define-syntax test-not
  (syntax-rules ()
    ((_ expr)
     (if expr (error "test-not: expected falsy, got truthy" 'expr) 'ok))))

(define-syntax test-error
  (syntax-rules ()
    ((_ expr)
     (guard (e (#t 'ok))
       (let ((result expr))
         (error "test-error: did not raise" 'expr 'got result))))))

(define (test-begin . rest) 'ok)
(define (test-end . rest) 'ok)
(define (test-group . rest) 'ok)
