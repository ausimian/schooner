;; Curated from Chibi-Scheme r7rs-tests.scm §6.9 "Bytevectors".
;; Source: https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests.scm
;;
;; Excluded from the upstream section, with reasons:
;;   - `bytevector-u8-set!` test at lines 1580-1581: mutation;
;;     out of scope.
;;   - All `bytevector-copy!` tests at 1588-1617: mutation.

(test-begin "6.9 Bytevectors")

(test #t (bytevector? #u8()))
(test #t (bytevector? #u8(0 1 2)))
(test #f (bytevector? #()))
(test #f (bytevector? #(0 1 2)))
(test #f (bytevector? '()))
(test #t (bytevector? (make-bytevector 0)))

(test 0 (bytevector-length (make-bytevector 0)))
(test 1024 (bytevector-length (make-bytevector 1024)))
(test 1024 (bytevector-length (make-bytevector 1024 255)))

(test 3 (bytevector-length (bytevector 0 1 2)))

(test 0 (bytevector-u8-ref (bytevector 0 1 2) 0))
(test 1 (bytevector-u8-ref (bytevector 0 1 2) 1))
(test 2 (bytevector-u8-ref (bytevector 0 1 2) 2))

(test #u8() (bytevector-copy #u8()))
(test #u8(0 1 2) (bytevector-copy #u8(0 1 2)))
(test #u8(1 2) (bytevector-copy #u8(0 1 2) 1))
(test #u8(1) (bytevector-copy #u8(0 1 2) 1 2))

(test #u8() (bytevector-append #u8()))
(test #u8() (bytevector-append #u8() #u8()))
(test #u8(0 1 2) (bytevector-append #u8() #u8(0 1 2)))
(test #u8(0 1 2) (bytevector-append #u8(0 1 2) #u8()))
(test #u8(0 1 2 3 4) (bytevector-append #u8(0 1 2) #u8(3 4)))
(test #u8(0 1 2 3 4 5) (bytevector-append #u8(0 1 2) #u8(3 4) #u8(5)))

(test "ABC" (utf8->string #u8(#x41 #x42 #x43)))
(test "ABC" (utf8->string #u8(0 #x41 #x42 #x43) 1))
(test "ABC" (utf8->string #u8(0 #x41 #x42 #x43 0) 1 4))
(test "λ" (utf8->string #u8(0 #xCE #xBB 0) 1 3))
(test #u8(#x41 #x42 #x43) (string->utf8 "ABC"))
(test #u8(#x42 #x43) (string->utf8 "ABC" 1))
(test #u8(#x42) (string->utf8 "ABC" 1 2))
(test #u8(#xCE #xBB) (string->utf8 "λ"))

(test-end)
