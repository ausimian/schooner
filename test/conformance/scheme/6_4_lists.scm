;; Curated from Chibi-Scheme r7rs-tests.scm §6.4 "Lists".
;; Source: https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests.scm
;;
;; Excluded from the upstream section, with reasons:
;;   - The `let* x/y` cluster at lines 1080-1089: uses `set-cdr!`
;;     to demonstrate the `list?` cycle detector and the `eqv?`
;;     identity guarantee under mutation. Mutation is out of scope.
;;   - `(set-cdr! x x)` cycle test at line 1113: same reason.
;;   - `(list-set! lst 1 ...)` test at lines 1140-1143: list-set!
;;     is a mutator. Out of scope.
;;   - `(test 'c (list-ref ... (exact (round 1.8))))` at line
;;     1137-1138: relies on `exact` (number-tower) which Schooner
;;     does not ship; the integer form is kept.

(test-begin "6.4 Lists")

(test #t (pair? '(a . b)))
(test #t (pair? '(a b c)))
(test #f (pair? '()))
(test #f (pair? '#(a b)))

(test '(a) (cons 'a '()))
(test '((a) b c d) (cons '(a) '(b c d)))
(test '("a" b c) (cons "a" '(b c)))
(test '(a . 3) (cons 'a 3))
(test '((a b) . c) (cons '(a b) 'c))

(test 'a (car '(a b c)))
(test '(a) (car '((a) b c d)))
(test 1 (car '(1 . 2)))

(test '(b c d) (cdr '((a) b c d)))
(test 2 (cdr '(1 . 2)))

(test #t (list? '(a b c)))
(test #t (list? '()))
(test #f (list? '(a . b)))

(test '(a 7 c) (list 'a (+ 3 4) 'c))
(test '() (list))

(test 3 (length '(a b c)))
(test 3 (length '(a (b) (c d e))))
(test 0 (length '()))

(test '(x y) (append '(x) '(y)))
(test '(a b c d) (append '(a) '(b c d)))
(test '(a (b) (c)) (append '(a (b)) '((c))))

(test '(a b c . d) (append '(a b) '(c . d)))
(test 'a (append '() 'a))

(test '(c b a) (reverse '(a b c)))
(test '((e (f)) d (b c) a) (reverse '(a (b c) d (e (f)))))

(test '(d e) (list-tail '(a b c d e) 3))

(test 'c (list-ref '(a b c d) 2))

(test '(a b c) (memq 'a '(a b c)))
(test '(b c) (memq 'b '(a b c)))
(test #f (memq 'a '(b c d)))
(test #f (memq (list 'a) '(b (a) c)))
(test '((a) c) (member (list 'a) '(b (a) c)))
;; Skipped: `(member "B" '(...) string-ci=?)` from upstream line 1150.
;; The 3-argument form of `member` (custom comparison) and the
;; `string-ci=?` primitive are not in Schooner's surface.
(test '(101 102) (memv 101 '(100 101 102)))

(let ()
  (define e '((a 1) (b 2) (c 3)))
  (test '(a 1) (assq 'a e))
  (test '(b 2) (assq 'b e))
  (test #f (assq 'd e)))

(test #f (assq (list 'a) '(((a)) ((b)) ((c)))))
(test '((a)) (assoc (list 'a) '(((a)) ((b)) ((c)))))
;; Skipped: `(assoc 2.0 ... =)` from upstream line 1161. The
;; 3-argument form of `assoc` (custom comparison) is not in
;; Schooner's surface — its `assoc` is the 2-arity equal? form.
(test '(5 7) (assv 5 '((2 3) (5 7) (11 13))))

(test '(1 2 3) (list-copy '(1 2 3)))
(test '() (list-copy '()))
(test '(3 . 4) (list-copy '(3 . 4)))
(test '(6 7 8 . 9) (list-copy '(6 7 8 . 9)))
(let* ((l1 '((a b) (c d) e))
       (l2 (list-copy l1)))
  (test l2 '((a b) (c d) e))
  (test #t (eq? (car l1) (car l2)))
  (test #t (eq? (cadr l1) (cadr l2)))
  (test #f (eq? (cdr l1) (cdr l2)))
  (test #f (eq? (cddr l1) (cddr l2))))

(test-end)
