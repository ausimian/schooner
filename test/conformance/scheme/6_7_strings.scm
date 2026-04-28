;; Curated from Chibi-Scheme r7rs-tests.scm §6.7 "Strings".
;; Source: https://github.com/ashinn/chibi-scheme/blob/master/tests/r7rs-tests.scm
;;
;; Excluded from the upstream section, with reasons:
;;   - All `string-set!` tests at lines 1320-1325: mutation; not
;;     supported in Schooner.
;;   - All `string-fill!` tests at lines 1456-1461: mutation.
;;   - All `string-copy!` tests at lines 1463-1478: mutation.
;;   - `string-foldcase` and Unicode special-case tests at lines
;;     1389-1422: `string-foldcase` is not in Schooner's surface;
;;     the case-mapping tests rely on it indirectly.
;;   - Greek final-sigma context-sensitive tests at 1414-1422:
;;     Schooner ships no context-sensitive case mapping.
;;   - All `string-ci=?` / `string-ci<?` / etc. tests at 1356-1382:
;;     case-insensitive string comparisons are not in Schooner's
;;     surface (PLAN.md keeps `(scheme base)` minimal — case
;;     mapping is host-injectable in v2 if needed).

(test-begin "6.7 Strings")

(test #t (string? ""))
(test #t (string? " "))
(test #f (string? 'a))
(test #f (string? #\a))

(test 3 (string-length (make-string 3)))
(test "---" (make-string 3 #\-))

(test "" (string))
(test "---" (string #\- #\- #\-))
(test "kitten" (string #\k #\i #\t #\t #\e #\n))

(test 0 (string-length ""))
(test 1 (string-length "a"))
(test 3 (string-length "abc"))

(test #\a (string-ref "abc" 0))
(test #\b (string-ref "abc" 1))
(test #\c (string-ref "abc" 2))

(test #t (string=? "" ""))
(test #t (string=? "abc" "abc" "abc"))
(test #f (string=? "" "abc"))
(test #f (string=? "abc" "aBc"))

(test #f (string<? "" ""))
(test #f (string<? "abc" "abc"))
(test #t (string<? "abc" "abcd" "acd"))
(test #f (string<? "abcd" "abc"))
(test #t (string<? "abc" "bbc"))

(test #f (string>? "" ""))
(test #f (string>? "abc" "abc"))
(test #f (string>? "abc" "abcd"))
(test #t (string>? "acd" "abcd" "abc"))
(test #f (string>? "abc" "bbc"))

(test #t (string<=? "" ""))
(test #t (string<=? "abc" "abc"))
(test #t (string<=? "abc" "abcd" "abcd"))
(test #f (string<=? "abcd" "abc"))
(test #t (string<=? "abc" "bbc"))

(test #t (string>=? "" ""))
(test #t (string>=? "abc" "abc"))
(test #f (string>=? "abc" "abcd"))
(test #t (string>=? "abcd" "abcd" "abc"))
(test #f (string>=? "abc" "bbc"))

;; Skipped: `string-ci=?` cluster at upstream lines 1356-1382 — see header.

;; latin
(test "ABC" (string-upcase "abc"))
(test "ABC" (string-upcase "ABC"))
(test "abc" (string-downcase "abc"))
(test "abc" (string-downcase "ABC"))

;; cyrillic
(test "ΑΒΓ" (string-upcase "αβγ"))
(test "ΑΒΓ" (string-upcase "ΑΒΓ"))
(test "αβγ" (string-downcase "αβγ"))
(test "αβγ" (string-downcase "ΑΒΓ"))

(test "" (substring "" 0 0))
(test "" (substring "a" 0 0))
(test "" (substring "abc" 1 1))
(test "ab" (substring "abc" 0 2))
(test "bc" (substring "abc" 1 3))

(test "" (string-append ""))
(test "" (string-append "" ""))
(test "abc" (string-append "" "abc"))
(test "abc" (string-append "abc" ""))
(test "abcde" (string-append "abc" "de"))
(test "abcdef" (string-append "abc" "de" "f"))

(test '() (string->list ""))
(test '(#\a) (string->list "a"))
(test '(#\a #\b #\c) (string->list "abc"))
(test '(#\a #\b #\c) (string->list "abc" 0))
(test '(#\b #\c) (string->list "abc" 1))
(test '(#\b #\c) (string->list "abc" 1 3))

(test "" (list->string '()))
(test "abc" (list->string '(#\a #\b #\c)))

(test "" (string-copy ""))
(test "" (string-copy "" 0))
(test "" (string-copy "" 0 0))
(test "abc" (string-copy "abc"))
(test "abc" (string-copy "abc" 0))
(test "bc" (string-copy "abc" 1))
(test "b" (string-copy "abc" 1 2))
(test "bc" (string-copy "abc" 1 3))

(test-end)
