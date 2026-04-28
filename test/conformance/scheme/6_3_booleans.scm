;; Curated from Chibi-Scheme r7rs-tests.scm §6.3 "Booleans".
;; Source: https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests.scm
;; All upstream tests in this section are exercised verbatim.

(test-begin "6.3 Booleans")

(test #t #t)
(test #f #f)
(test #f '#f)

(test #f (not #t))
(test #f (not 3))
(test #f (not (list 3)))
(test #t (not #f))
(test #f (not '()))
(test #f (not (list)))
(test #f (not 'nil))

(test #t (boolean? #f))
(test #f (boolean? 0))
(test #f (boolean? '()))

(test #t (boolean=? #t #t))
(test #t (boolean=? #f #f))
(test #f (boolean=? #t #f))
(test #t (boolean=? #f #f #f))
(test #f (boolean=? #t #t #f))

(test-end)
