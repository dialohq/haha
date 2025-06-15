(lang dune 3.15)

(generate_opam_files true)

(name haha)

(package
 (name hpackv)
 (synopsis
  "An HPACK (Header Compression for HTTP/2) implementation in OCaml")
 (description
  "hpack is an implementation of the HPACK: Header Compression for HTTP/2 specification (RFC7541) written in OCaml. It uses Angstrom and Faraday for parsing and serialization, respectively.")
 (depends
  (ocaml
   (>= "4.08.0"))
  angstrom
  (faraday
   (>= "0.7.3"))
  (yojson :with-test)
  (hex :with-test)))

(package 
  (name h2kit))

(package
 (name haha)
 (synopsis
  "Performance-first HTTP/2 implementation in OCaml")
 (depends
  (ocaml
   (>= "4.08.0"))
  (angstrom
   (>= "0.14.0"))
  (faraday
   (>= "0.7.3"))
  (bigstringaf
   (>= "0.5.0"))
  hpackv
  ))

(package
 (name haha-examples)
 (synopsis
  "Examples for Haha library")
 (depends
  haha
  uri))
