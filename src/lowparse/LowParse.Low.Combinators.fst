module LowParse.Low.Combinators
include LowParse.Low.Base
include LowParse.Spec.Combinators

module B = FStar.Buffer
module U32 = FStar.UInt32
module HS = FStar.HyperStack
module HST = FStar.HyperStack.ST

#reset-options "--z3rlimit 256 --max_fuel 32 --max_ifuel 32 --z3cliopt smt.arith.nl=false"

inline_for_extraction
let validate32_nondep_then
  (#k1: parser_kind)
  (#t1: Type0)
  (#p1: parser k1 t1)
  (p1' : validator32 p1)
  (#k2: parser_kind)
  (#t2: Type0)
  (#p2: parser k2 t2)
  (p2' : validator32 p2)
: Tot (validator32 (nondep_then p1 p2))
= fun (input: pointer buffer8) (len: pointer U32.t) ->
  if p1' input len
  then begin
    let res = p2' input len in
    res
  end else false

#reset-options "--z3rlimit 128 --max_fuel 32 --max_ifuel 32 --z3cliopt smt.arith.nl=false"

inline_for_extraction
let validate_nochk32_nondep_then
  (#k1: parser_kind)
  (#t1: Type0)
  (#p1: parser k1 t1)
  (p1' : validator_nochk32 p1)
  (#k2: parser_kind)
  (#t2: Type0)
  (#p2: parser k2 t2)
  (p2' : validator_nochk32 p2)
: Tot (validator_nochk32 (nondep_then p1 p2))
= fun (input: pointer buffer8) (len: pointer U32.t) ->
  p1' input len;
  p2' input len

inline_for_extraction
let validate32_synth
  (#k: parser_kind)
  (#t1: Type0)
  (#t2: Type0)
  (#p1: parser k t1)
  (p1' : validator32 p1)
  (f2: t1 -> GTot t2)
  (u: unit {
    synth_injective f2
  })
: Tot (validator32 (parse_synth p1 f2))
= fun (input: pointer buffer8) (len: pointer U32.t) ->
  p1' input len

inline_for_extraction
let validate_nochk32_synth
  (#k: parser_kind)
  (#t1: Type0)
  (#t2: Type0)
  (#p1: parser k t1)
  (p1' : validator_nochk32 p1)
  (f2: t1 -> GTot t2)
  (u: unit {
    synth_injective f2
  })
: Tot (validator_nochk32 (parse_synth p1 f2))
= fun (input: pointer buffer8) (len: pointer U32.t) ->
  p1' input len

inline_for_extraction
let validate32_total_constant_size
  (#k: parser_kind)
  (#t: Type0)
  (p: parser k t)
  (sz: U32.t)
  (u: unit {
    k.parser_kind_high == Some k.parser_kind_low /\
    k.parser_kind_low == U32.v sz /\
    k.parser_kind_metadata.parser_kind_metadata_total = true
  })
: Tot (validator32 p)
= fun (input: pointer buffer8) (len: pointer U32.t) ->
  let len0 = B.index len 0ul in
  if U32.lt len0 sz
  then false
  else begin
    advance_slice_ptr input len sz;
    true
  end

inline_for_extraction
let validate_nochk32_constant_size
  (#k: parser_kind)
  (#t: Type0)
  (p: parser k t)
  (sz: U32.t)
  (u: unit {
    k.parser_kind_high == Some k.parser_kind_low /\
    k.parser_kind_low == U32.v sz
  })
: Tot (validator_nochk32 p)
= fun (input: pointer buffer8) (len: pointer U32.t) ->
  advance_slice_ptr input len sz

inline_for_extraction
let accessor_weaken
  (#k1: parser_kind)
  (#t1: Type)
  (#p1: parser k1 t1)
  (#k2: parser_kind)
  (#t2: Type)
  (#p2: parser k2 t2)
  (#rel: (t1 -> t2 -> GTot Type0))
  (a: accessor p1 p2 rel)
  (rel': (t1 -> t2 -> GTot Type0))
  (u: unit { forall x1 x2 . rel x1 x2 ==> rel' x1 x2 } )
: Tot (accessor p1 p2 rel')
= fun input res -> a input res

let rel_compose (#t1 #t2 #t3: Type) (r12: t1 -> t2 -> GTot Type0) (r23: t2 -> t3 -> GTot Type0) (x1: t1) (x3: t3) : GTot Type0 =
  exists x2 . r12 x1 x2 /\ r23 x2 x3

inline_for_extraction
let accessor_compose
  (#k1: parser_kind)
  (#t1: Type)
  (#p1: parser k1 t1)
  (#k2: parser_kind)
  (#t2: Type)
  (#p2: parser k2 t2)
  (#k3: parser_kind)
  (#t3: Type)
  (#p3: parser k3 t3)
  (#rel12: (t1 -> t2 -> GTot Type0))
  (#rel23: (t2 -> t3 -> GTot Type0))
  (a12: accessor p1 p2 rel12)
  (a23: accessor p2 p3 rel23)
: Tot (accessor p1 p3 (rel12 `rel_compose` rel23))
= fun input res ->
    a12 input res;
    a23 input res

inline_for_extraction
let accessor_synth
  (#k: parser_kind)
  (#t1: Type)
  (#t2: Type)
  (#p1: parser k t1)
  (v1: validator_nochk32 p1)
  (f: t1 -> GTot t2)
  (u: unit {  synth_injective f } )
: Tot (accessor (parse_synth p1 f) p1 (fun x y -> f y == x))
= fun input res -> truncate32 v1 input res

inline_for_extraction
val nondep_then_fst
  (#k1: parser_kind)
  (#t1: Type0)
  (#p1: parser k1 t1)
  (p1' : validator_nochk32 p1)
  (#k2: parser_kind)
  (#t2: Type0)
  (p2: parser k2 t2)
: Tot (accessor (p1 `nondep_then` p2) p1 (fun x y -> y == fst x))

let nondep_then_fst #k1 #t1 #p1 p1' #k2 #t2 p2 input sz =
  truncate32 p1' input sz

inline_for_extraction
val nondep_then_snd
  (#k1: parser_kind)
  (#t1: Type0)
  (#p1: parser k1 t1)
  (p1' : validator_nochk32 p1)
  (#k2: parser_kind)
  (#t2: Type0)
  (#p2: parser k2 t2)
  (p2' : validator_nochk32 p2)
: Tot (accessor (p1 `nondep_then` p2) p2 (fun x y -> y == snd x))

let nondep_then_snd #k1 #t1 #p1 p1' #k2 #t2 #p2 p2' input sz =
  p1' input sz;
  truncate32 p2' input sz

inline_for_extraction
let make_total_constant_size_parser32
  (sz: nat)
  (sz' : U32.t { U32.v sz' == sz } )
  (#t: Type0)
  (f: ((s: bytes {Seq.length s == sz}) -> GTot (t)))
  (u: unit {
    make_total_constant_size_parser_precond sz t f
  })
  (f' : ((s: buffer8) -> HST.Stack t
    (requires (fun h -> B.live h s /\ B.length s == sz))
    (ensures (fun h res h' ->
      h == h' /\
      res == f (B.as_seq h s)
  ))))
: Tot (parser32 (make_total_constant_size_parser sz t f))
= fun (input: pointer buffer8) (len: pointer U32.t) ->
  let b0 = B.index input 0ul in
  let b = B.sub b0 0ul sz' in
  let res = f' b in
  advance_slice_ptr input len sz';
  res