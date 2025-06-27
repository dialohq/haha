(lang dune 3.15)

(generate_opam_files true)

(name haha)

(package
 (name h2kit))

(package
 (name h2inspect))

(package
 (name haha)
 (synopsis "Performance-first HTTP/2 implementation in OCaml")
 (depends
  (ocaml
   (>= "4.08.0"))
  (angstrom
   (>= "0.14.0"))
  (faraday
   (>= "0.7.3"))
  (bigstringaf
   (>= "0.5.0"))
  hpackv))

(package
 (name haha-examples)
 (synopsis "Examples for Haha library")
 (depends haha uri))
