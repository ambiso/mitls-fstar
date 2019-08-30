module HSL.Transcript
open FStar.Integers
open FStar.HyperStack.ST
module List = FStar.List.Tot
module HS = FStar.HyperStack
module B = LowStar.Buffer
module G = FStar.Ghost

module HSM = Parsers.Handshake
module HSM12 = Parsers.Handshake12
module HSM13 = Parsers.Handshake13

module PV = Parsers.ProtocolVersion
module LP = LowParse.Low.Base

module R = MITLS.Repr
module R_HS = MITLS.Repr.Handshake

module R_CH = MITLS.Repr.ClientHello
module CH = Parsers.ClientHello

module R_SH = MITLS.Repr.ServerHello
module SH = Parsers.ServerHello
module CRF = Crypto.CRF
module TestCRF = Test.CRF

#set-options "--max_fuel 1 --max_ifuel 1 --z3rlimit 16"

// In Negotiation.Version.fst
let nego_version _ _ = admit ()

//Seems to be automatic
let serialize_max_size
  (#pk:_) (#t:_) (#p:LP.parser pk t) (s:LP.serializer p)
  (x:t)
: Lemma
  (requires (
    match pk.LP.parser_kind_high with
    | None -> False
    | Some n -> n < max_message_size
  ))
  (ensures (
    Seq.length (LP.serialize s x) < max_message_size
  ))
= ()

module LPSL = LowParse.Spec.List

val serialize_list_max_size
  (#pk:_) (#t:_) (#p:LP.parser pk t) (s:LP.serializer p)
  (x:list t)
: Lemma
  (requires (
    LPSL.serialize_list_precond pk /\ (
    match pk.LP.parser_kind_high with
    | None -> False
    | Some n -> n < max_message_size
  )))
  (ensures (
    Seq.length (LP.serialize (LPSL.serialize_list _ s) x) <= List.Tot.length x * max_message_size
  ))
//  [SMTPat (Seq.length (LP.serialize (LPSL.serialize_list _ s) x))]


let rec serialize_list_max_size #pk #t #p s x =
  match x with
  | [] -> LPSL.serialize_list_nil p s
  | hd::tl -> LPSL.serialize_list_cons p s hd tl; serialize_list_max_size s tl
   
let serialize_any_tag (ht:any_hash_tag) =
    LP.serialize HSM.handshake_serializer ht // (Parsers.Handshake.M_message_hash ht)

let serialize_client_hello (ch:CH.clientHello) =
  LP.serialize HSM.handshake_serializer (HSM.M_client_hello ch)

let serialize_server_hello (sh:SH.serverHello) =
  LP.serialize HSM.handshake_serializer (HSM.M_server_hello sh)

let serialize_retry (r:option retry)
  : GTot (b:bytes{Seq.length b < 2 * max_message_size })
  =
  match r with
  | None -> Seq.empty
  | Some (ht, sh) ->
    serialize_any_tag ht `Seq.append`
    serialize_server_hello sh

let transcript_bytes (t:transcript_t)
  : GTot (b:bytes {
    Seq.length b <= (max_transcript_size + 4) * max_message_size
    })
  = match t with
  | Start r ->
    serialize_retry r

  | TruncatedClientHello r tch ->
    serialize_retry r `Seq.append`
    FStar.Bytes.reveal (PB.truncate_clientHello_bytes (HSM.M_client_hello tch))

  | ClientHello r ch ->
    serialize_retry r `Seq.append`
    serialize_client_hello ch
    
  | Transcript12 ch sh rest ->
    serialize_list_max_size HSM12.handshake12_serializer rest;
    serialize_client_hello ch `Seq.append` (
    serialize_server_hello sh `Seq.append`
    LP.serialize (LPSL.serialize_list _ HSM12.handshake12_serializer) rest
    )

  | Transcript13 retry ch sh rest ->
    serialize_list_max_size HSM13.handshake13_serializer rest;
    serialize_retry retry `Seq.append` (
    serialize_client_hello ch `Seq.append` (
    serialize_server_hello sh `Seq.append` (
    LP.serialize (LPSL.serialize_list _ HSM13.handshake13_serializer) rest
    )))

let transcript_is_empty (t: transcript_t) : Tot bool = match t with
  | Start None -> true
  | _ -> false

let transcript_get_retry (t: transcript_t) : Tot (option retry) = match t with
  | Start r -> r
  | TruncatedClientHello r _ -> r
  | ClientHello r _ -> r
  | Transcript12 _ _ _ -> None
  | Transcript13 r _ _ _ -> r

let transcript_set_retry (t: transcript_t) (r: option retry { Transcript12? t ==> None? r }) : Tot transcript_t =
  match t with
  | Start _ -> Start r
  | TruncatedClientHello _ tch -> TruncatedClientHello r tch
  | ClientHello _ ch -> ClientHello r ch
  | Transcript12 ch sh rest -> Transcript12 ch sh rest
  | Transcript13 _ ch sh rest -> Transcript13 r ch sh rest

let transcript_script_bytes (t: transcript_t) : Lemma
  (transcript_bytes t `Seq.equal` (serialize_retry (transcript_get_retry t) `Seq.append` transcript_bytes (transcript_set_retry t None)))
= ()

let seq_append_empty () : Lemma
  (forall (s: Seq.seq LP.byte) . {:pattern (Seq.empty `Seq.append` s)} Seq.empty `Seq.append` s == s)
= assert (forall (s: Seq.seq LP.byte) . {:pattern (Seq.empty `Seq.append` s)} (Seq.empty `Seq.append` s) `Seq.equal` s)

let transcript_bytes_does_not_start_with_message_hash
  (t: transcript_t)
  (r: retry)
  (q: Seq.seq FStar.UInt8.t)
: Lemma
  (requires (transcript_get_retry t == None /\ transcript_bytes t == serialize_retry (Some r) `Seq.append` q))
  (ensures False)
= let ht, hrr = r in
  seq_append_empty();
  assert (transcript_bytes t `Seq.equal` 
    (serialize_any_tag ht `Seq.append` (serialize_server_hello hrr `Seq.append` q)));  
  match t with
  | ClientHello _ ch ->
    assert (transcript_bytes t `Seq.equal` (serialize_client_hello ch `Seq.append` Seq.empty));
    LP.serialize_strong_prefix HSM.handshake_serializer 
      ht (HSM.M_client_hello ch)
      (serialize_server_hello hrr `Seq.append` q)
      Seq.empty

  | TruncatedClientHello _ tch -> 
    PB.parse_truncate_clientHello_bytes (HSM.M_client_hello tch);
    LP.parse_strong_prefix HSM.handshake_parser 
      (serialize_any_tag ht)
      (Bytes.reveal (PB.truncate_clientHello_bytes (HSM.M_client_hello tch)))

  | Transcript12 ch sh rest ->
    LP.serialize_strong_prefix HSM.handshake_serializer 
      ht (HSM.M_client_hello ch)
      (serialize_server_hello hrr `Seq.append` q)
      (serialize_server_hello sh `Seq.append`
        LP.serialize (LPSL.serialize_list _ HSM12.handshake12_serializer) rest)

  | Transcript13 _ ch sh rest ->
    LP.serialize_strong_prefix HSM.handshake_serializer 
      ht (HSM.M_client_hello ch)
      (serialize_server_hello hrr `Seq.append` q)
      (serialize_server_hello sh `Seq.append`
        LP.serialize (LPSL.serialize_list _ HSM13.handshake13_serializer) rest)

let transcript_bytes_injective_retry
  (r1: option retry)
  (t1: transcript_t { transcript_get_retry t1 == None } )
  (r2: option retry)
  (t2: transcript_t { transcript_get_retry t2 == None } )
: Lemma
  (requires (serialize_retry r1 `Seq.append` transcript_bytes t1 == serialize_retry r2 `Seq.append` transcript_bytes t2))
  (ensures (r1 == r2 /\ transcript_bytes t1 `Seq.equal` transcript_bytes t2))
= seq_append_empty ();
  match r1, r2 with
  | None, None -> ()
  | Some (ht1, sh1), Some (ht2, sh2) ->
    assert ((serialize_retry r1 `Seq.append` transcript_bytes t1) `Seq.equal` (serialize_any_tag ht1 `Seq.append` (serialize_server_hello sh1 `Seq.append` transcript_bytes t1)));
    assert ((serialize_retry r2 `Seq.append` transcript_bytes t2) `Seq.equal` (serialize_any_tag ht2 `Seq.append` (serialize_server_hello sh2 `Seq.append` transcript_bytes t2)));
    LP.serialize_strong_prefix HSM.handshake_serializer ht1 ht2
      (serialize_server_hello sh1 `Seq.append` transcript_bytes t1)
      (serialize_server_hello sh2 `Seq.append` transcript_bytes t2);        
    LP.serialize_strong_prefix HSM.handshake_serializer
      (HSM.M_server_hello sh1) (HSM.M_server_hello sh2)
      (transcript_bytes t1) (transcript_bytes t2)
  | Some r1, _ ->
    transcript_bytes_does_not_start_with_message_hash t2 r1 (transcript_bytes t1)
  | _, Some r2 ->
    transcript_bytes_does_not_start_with_message_hash t1 r2 (transcript_bytes t2)

let transcript_arbitrary_index
  (t1: transcript_t)
: GTot nat
= match t1 with
  | Start _ -> 0
  | TruncatedClientHello _ _ -> 1
  | ClientHello _ _ -> 2
  | Transcript12 _ _ _ -> 3
  | Transcript13 _ _ _ _ -> 4

let seq_append_empty_r () : Lemma
  (forall (s: Seq.seq LP.byte) . {:pattern (s `Seq.append` Seq.empty)} s `Seq.append` Seq.empty  == s)
= assert   (forall (s: Seq.seq LP.byte) . {:pattern (s `Seq.append` Seq.empty)} (s `Seq.append` Seq.empty) `Seq.equal` s)

let rec transcript_bytes_injective_no_retry
  (t1: transcript_t { transcript_get_retry t1 == None } )
  (t2: transcript_t { transcript_get_retry t2 == None } )
: Lemma
    (requires
      transcript_bytes t1 `Seq.equal` transcript_bytes t2)
    (ensures
      t1 == t2)
    (decreases (transcript_arbitrary_index t2))
= seq_append_empty ();
  if transcript_arbitrary_index t1 < transcript_arbitrary_index t2
  then transcript_bytes_injective_no_retry t2 t1
  else
    if Start? t2
    then ()
    else match t1 with
    | TruncatedClientHello _ tch1 ->
      begin match t2 with
      | TruncatedClientHello _ tch2 ->
        let tch1' = HSM.M_client_hello tch1 in
        let tch2' = HSM.M_client_hello tch2 in
        PB.truncate_clientHello_bytes_inj_binders_bytesize tch1' tch2';
        PB.set_binders_get_binders tch1';
        PB.set_binders_get_binders tch2';
        PB.truncate_clientHello_bytes_inj tch1' tch2' (PB.build_canonical_binders (tch_binders_len tch1))
      end
    | ClientHello _ ch1 ->
      begin match t2 with
      | TruncatedClientHello _ tch2 ->
        PB.parse_truncate_clientHello_bytes (HSM.M_client_hello tch2)
      | ClientHello _ ch2 ->
        LP.serializer_injective _ HSM.handshake_serializer (HSM.M_client_hello ch1) (HSM.M_client_hello ch2)
      end
    | Transcript12  ch1 sh1 rest1 ->
      begin match t2 with
      | TruncatedClientHello _ tch2 ->
        LP.parse_strong_prefix HSM.handshake_parser (LP.serialize HSM.handshake_serializer (HSM.M_client_hello ch1)) (transcript_bytes t1);
        PB.parse_truncate_clientHello_bytes (HSM.M_client_hello tch2)
      | ClientHello _ ch2 ->
        seq_append_empty_r ();
        LP.serialize_strong_prefix HSM.handshake_serializer (HSM.M_client_hello ch1) (HSM.M_client_hello ch2) (serialize_server_hello sh1 `Seq.append` (
    LP.serialize (LPSL.serialize_list _ HSM12.handshake12_serializer) rest1)) Seq.empty
      | Transcript12 ch2 sh2 rest2 ->
        LP.serialize_strong_prefix HSM.handshake_serializer (HSM.M_client_hello ch1) (HSM.M_client_hello ch2) (serialize_server_hello sh1 `Seq.append` (
    LP.serialize (LPSL.serialize_list _ HSM12.handshake12_serializer) rest1)) (serialize_server_hello sh2 `Seq.append` (
    LP.serialize (LPSL.serialize_list _ HSM12.handshake12_serializer) rest2));
        LP.serialize_strong_prefix HSM.handshake_serializer (HSM.M_server_hello sh1) (HSM.M_server_hello sh2)     (LP.serialize (LPSL.serialize_list _ HSM12.handshake12_serializer) rest1) (
    LP.serialize (LPSL.serialize_list _ HSM12.handshake12_serializer) rest2);
        LP.serializer_injective _ (LPSL.serialize_list _ HSM12.handshake12_serializer) rest1 rest2
      end      
    | Transcript13 _ ch1 sh1 rest1 ->
      begin match t2 with
      | TruncatedClientHello _ tch2 ->
        LP.parse_strong_prefix HSM.handshake_parser (LP.serialize HSM.handshake_serializer (HSM.M_client_hello ch1)) (transcript_bytes t1);
        PB.parse_truncate_clientHello_bytes (HSM.M_client_hello tch2)
      | ClientHello _ ch2 ->
        seq_append_empty_r ();
        LP.serialize_strong_prefix HSM.handshake_serializer (HSM.M_client_hello ch1) (HSM.M_client_hello ch2) (serialize_server_hello sh1 `Seq.append` (
    LP.serialize (LPSL.serialize_list _ HSM13.handshake13_serializer) rest1)) Seq.empty
      | Transcript12 ch2 sh2 _ -> ()
      | Transcript13 _ ch2 sh2 rest2 ->
        LP.serialize_strong_prefix HSM.handshake_serializer (HSM.M_client_hello ch1) (HSM.M_client_hello ch2) (serialize_server_hello sh1 `Seq.append` (
    LP.serialize (LPSL.serialize_list _ HSM13.handshake13_serializer) rest1)) (serialize_server_hello sh2 `Seq.append` (
    LP.serialize (LPSL.serialize_list _ HSM13.handshake13_serializer) rest2));
        LP.serialize_strong_prefix HSM.handshake_serializer (HSM.M_server_hello sh1) (HSM.M_server_hello sh2)     (LP.serialize (LPSL.serialize_list _ HSM13.handshake13_serializer) rest1) (
    LP.serialize (LPSL.serialize_list _ HSM13.handshake13_serializer) rest2);
        LP.serializer_injective _ (LPSL.serialize_list _ HSM13.handshake13_serializer) rest1 rest2
      end

let transcript_bytes_injective (t1 t2:transcript_t)
  : Lemma
    (requires
      transcript_bytes t1 `Seq.equal` transcript_bytes t2)
    (ensures
      t1 == t2)
  = let t1' = transcript_set_retry t1 None in
    let t2' = transcript_set_retry t2 None in
    transcript_script_bytes t1;
    transcript_script_bytes t2;
    transcript_bytes_injective_retry (transcript_get_retry t1) t1' (transcript_get_retry t2) t2' ;
    transcript_bytes_injective_no_retry t1' t2'

noeq
type state (a:HashDef.hash_alg) = {
  region:Mem.rgn;
  loc: Ghost.erased B.loc;
  hash_state: CRF.state a
}

let invariant (#a:HashDef.hash_alg) (s:state a) (tx:transcript_t) (h:HS.mem) =
  CRF.hashed h s.hash_state `Seq.equal` transcript_bytes tx /\
  CRF.invariant h s.hash_state /\
  B.loc_region_only true s.region `B.loc_includes` Ghost.reveal s.loc /\
  Ghost.reveal s.loc == CRF.footprint h s.hash_state /\
  B.loc_not_unused_in h `B.loc_includes` Ghost.reveal s.loc

let footprint (#a:HashDef.hash_alg) (s:state a) = Ghost.reveal s.loc

let elim_invariant #a s t h = ()

let region_of #a s = s.region

let frame_invariant (#a:_) (s:state a) (t: transcript_t) (h0 h1:HS.mem) (l:B.loc) =
  CRF.frame_invariant l s.hash_state h0 h1

let create r a =
  let h0 = get() in
  let s = CRF.create_in a r in
  let h1 = get () in
  {region=r;
   loc=Ghost.hide (CRF.footprint h1 s);
   hash_state=s},
  Ghost.hide (Start None)

#push-options "--max_fuel 0 --max_ifuel  1 --initial_ifuel  1 --z3rlimit 200"
let extend (#a:_) (s:state a) (l:label_repr) (tx:G.erased transcript_t) =
  let h0 = HyperStack.ST.get() in
  match l with
  | LR_ClientHello #b ch ->
    assume (C.qbuf_qual (C.as_qbuf b.R.base) = C.MUTABLE);

    // These three lemmas prove that the data in the subbuffer data is
    // the serialized data corresponding to the client hello that is being added
    R.reveal_valid();
    LP.valid_pos_valid_exact HSM.handshake_parser h0 (R.to_slice b) ch.R.start_pos ch.R.end_pos;
    LP.valid_exact_serialize HSM.handshake_serializer h0 (R.to_slice b) ch.R.start_pos ch.R.end_pos;

    let len = ch.R.end_pos - ch.R.start_pos in
    let data = C.sub b.R.base ch.R.start_pos len in

    assert_norm (pow2 32 < pow2 61);
    CRF.update (Ghost.hide a) s.hash_state (C.to_buffer data) len;

    let tx' = G.hide (Some?.v (transition (G.reveal tx) (label_of_label_repr l))) in

    tx'

  | LR_ServerHello #b sh ->
    assume (C.qbuf_qual (C.as_qbuf b.R.base) = C.MUTABLE);

    // These three lemmas prove that the data in the subbuffer data is
    // the serialized data corresponding to the server hello that is being added
    R.reveal_valid();
    LP.valid_pos_valid_exact HSM.handshake_parser h0 (R.to_slice b) sh.R.start_pos sh.R.end_pos;
    LP.valid_exact_serialize HSM.handshake_serializer h0 (R.to_slice b) sh.R.start_pos sh.R.end_pos;

    let len = sh.R.end_pos - sh.R.start_pos in
    let data = C.sub b.R.base sh.R.start_pos len in

    assert_norm (pow2 32 < pow2 61);
    CRF.update (Ghost.hide a) s.hash_state (C.to_buffer data) len;
    let h1 = HyperStack.ST.get() in

    let tx' = G.hide (Some?.v (transition (G.reveal tx) (label_of_label_repr l))) in

    LPSL.serialize_list_nil HSM12.handshake12_parser HSM12.handshake12_serializer;
    LPSL.serialize_list_nil HSM13.handshake13_parser HSM13.handshake13_serializer;
    assert ((transcript_bytes (G.reveal tx) `Seq.append` 
             serialize_server_hello (HSM.M_server_hello?._0 (R.value sh)))
        `Seq.equal`     
             transcript_bytes (G.reveal tx'));

    tx'

  | LR_TCH #b tch   ->
    assume (C.qbuf_qual (C.as_qbuf b.R.base) = C.MUTABLE);

    R.reveal_valid();
    let h0 = HyperStack.ST.get() in
    assert (LP.valid HSM.handshake_parser h0 (R.to_slice b) tch.R.start_pos);
    let end_pos = PB.binders_pos (R.to_slice b) tch.R.start_pos in

    let len = end_pos - tch.R.start_pos in
    let data = C.sub b.R.base tch.R.start_pos len in

    PB.valid_truncate_clientHello h0 (R.to_slice b) tch.R.start_pos;
    assert (C.as_seq h0 data == FStar.Bytes.reveal (PB.truncate_clientHello_bytes (R.value tch)));

    assert_norm (pow2 32 < pow2 61);
    let h1 = HyperStack.ST.get () in
    CRF.frame_invariant B.loc_none s.hash_state h0 h1;
    CRF.update (Ghost.hide a) s.hash_state (C.to_buffer data) len;

    let tx' = G.hide (Some?.v (transition (G.reveal tx) (label_of_label_repr l))) in

    PB.truncate_clientHello_bytes_set_binders
      (R.value tch)
      (PB.build_canonical_binders (tch_binders_len (HSM.M_client_hello?._0 (R.value tch))));

    
    tx'

  | LR_CompleteTCH #b tch -> 
    assume (C.qbuf_qual (C.as_qbuf b.R.base) = C.MUTABLE);

    R.reveal_valid();
    // Needed to detect that the whole b.R.base between start and pos is actually serialize tch
    LP.valid_pos_valid_exact HSM.handshake_parser h0 (R.to_slice b) tch.R.start_pos tch.R.end_pos;
    LP.valid_exact_serialize HSM.handshake_serializer h0 (R.to_slice b) tch.R.start_pos tch.R.end_pos;
    
    let h0 = HyperStack.ST.get() in
    assert (LP.valid HSM.handshake_parser h0 (R.to_slice b) tch.R.start_pos);
    let start_pos = PB.binders_pos (R.to_slice b) tch.R.start_pos in

    let len = tch.R.end_pos - start_pos in
    let data = C.sub b.R.base start_pos len in

    PB.valid_truncate_clientHello h0 (R.to_slice b) tch.R.start_pos;
    assert_norm (pow2 32 < pow2 61);
    let h1 = HyperStack.ST.get () in
    CRF.frame_invariant B.loc_none s.hash_state h0 h1;
    CRF.update (Ghost.hide a) s.hash_state (C.to_buffer data) len;

    let tx' = G.hide (Some?.v (transition (G.reveal tx) (label_of_label_repr l))) in

    PB.truncate_clientHello_bytes_set_binders
      (R.value tch)
      (PB.build_canonical_binders (tch_binders_len (HSM.M_client_hello?._0 (R.value tch))));

    assert ((transcript_bytes (G.reveal tx) `Seq.append` (C.as_seq h0 data))
        `Seq.equal` 
          transcript_bytes (G.reveal tx'));

    tx'

  | LR_HRR #b1 ch_tag #b2 hrr ->
    assume (C.qbuf_qual (C.as_qbuf b1.R.base) = C.MUTABLE);
    assume (C.qbuf_qual (C.as_qbuf b2.R.base) = C.MUTABLE);

    let tx' = G.hide (Some?.v (transition (G.reveal tx) (label_of_label_repr l))) in

    // these three lemmas prove that the data in the subbuffer data is
    // the serialized data corresponding to the client hello that is being added
    R.reveal_valid();

    LP.valid_pos_valid_exact HSM.handshake_parser h0 (R.to_slice b1) ch_tag.R.start_pos ch_tag.R.end_pos;
    LP.valid_exact_serialize HSM.handshake_serializer h0 (R.to_slice b1) ch_tag.R.start_pos ch_tag.R.end_pos;

    LP.valid_pos_valid_exact HSM.handshake_parser h0 (R.to_slice b2) hrr.R.start_pos hrr.R.end_pos;
    LP.valid_exact_serialize HSM.handshake_serializer h0 (R.to_slice b2) hrr.R.start_pos hrr.R.end_pos;


    let len = ch_tag.R.end_pos - ch_tag.R.start_pos in
    let data = C.sub b1.R.base ch_tag.R.start_pos len in

    assert_norm (pow2 32 < pow2 61);
    CRF.update (Ghost.hide a) s.hash_state (C.to_buffer data) len;

    assert ((Seq.empty `Seq.append`  LP.serialize HSM.handshake_serializer (R.value ch_tag))
      `Seq.equal`
        LP.serialize HSM.handshake_serializer (R.value ch_tag));

    let h1 = HyperStack.ST.get() in

    let len = hrr.R.end_pos - hrr.R.start_pos in
    let data = C.sub b2.R.base hrr.R.start_pos len in

    CRF.update (Ghost.hide a) s.hash_state (C.to_buffer data) len;

    let hf = HyperStack.ST.get () in

    tx'
  
  | LR_HSM12 #b hs12 ->
    assume (C.qbuf_qual (C.as_qbuf b.R.base) = C.MUTABLE);

    // These three lemmas prove that the data in the subbuffer data is
    // the serialized data corresponding to the client hello that is being added
    R.reveal_valid();
    LP.valid_pos_valid_exact HSM12.handshake12_parser h0 (R.to_slice b) hs12.R.start_pos hs12.R.end_pos;
    LP.valid_exact_serialize HSM12.handshake12_serializer h0 (R.to_slice b) hs12.R.start_pos hs12.R.end_pos;

    let len = hs12.R.end_pos - hs12.R.start_pos in
    let data = C.sub b.R.base hs12.R.start_pos len in
    let tx' = G.hide (Some?.v (transition (G.reveal tx) (label_of_label_repr l))) in

    LPSL.serialize_list_singleton HSM12.handshake12_parser HSM12.handshake12_serializer
      (R.value hs12);
    LPSL.serialize_list_append HSM12.handshake12_parser HSM12.handshake12_serializer
      (let Transcript12 _ _ rest = G.reveal tx in rest)
      [R.value hs12];
    assert ((transcript_bytes (G.reveal tx) `Seq.append` 
                              LP.serialize HSM12.handshake12_serializer (R.value hs12))
        `Seq.equal`     
             transcript_bytes (G.reveal tx'));
    
    assert_norm ((max_transcript_size + 4) * max_message_size < pow2 61);

    CRF.update (Ghost.hide a) s.hash_state (C.to_buffer data) len;

    tx'

  | LR_HSM13 #b hs13 ->
    assume (C.qbuf_qual (C.as_qbuf b.R.base) = C.MUTABLE);

    // These three lemmas prove that the data in the subbuffer data is
    // the serialized data corresponding to the client hello that is being added
    R.reveal_valid();
    LP.valid_pos_valid_exact HSM13.handshake13_parser h0 (R.to_slice b) hs13.R.start_pos hs13.R.end_pos;
    LP.valid_exact_serialize HSM13.handshake13_serializer h0 (R.to_slice b) hs13.R.start_pos hs13.R.end_pos;

    let len = hs13.R.end_pos - hs13.R.start_pos in
    let data = C.sub b.R.base hs13.R.start_pos len in

    let tx' = G.hide (Some?.v (transition (G.reveal tx) (label_of_label_repr l))) in

    LPSL.serialize_list_singleton HSM13.handshake13_parser HSM13.handshake13_serializer
      (R.value hs13);
    LPSL.serialize_list_append HSM13.handshake13_parser HSM13.handshake13_serializer
      (let Transcript13 _ _ _ rest = G.reveal tx in rest)
      [R.value hs13];
    assert ((transcript_bytes (G.reveal tx) `Seq.append` 
                              LP.serialize HSM13.handshake13_serializer (R.value hs13))
        `Seq.equal`     
             transcript_bytes (G.reveal tx'));

    
    assert_norm ((max_transcript_size + 4) * max_message_size < pow2 61);

    CRF.update (Ghost.hide a) s.hash_state (C.to_buffer data) len;

    tx'
#pop-options

let transcript_hash (a:HashDef.hash_alg) (t:transcript_t)
  = Spec.Hash.hash a (transcript_bytes t)

let hashed (a:HashDef.hash_alg) (t:transcript_t) = 
  Model.CRF.hashed a (transcript_bytes t)
  
let extract_hash (#a:_) (s:state a) 
  (tag:Hacl.Hash.Definitions.hash_t a)
  (tx:G.erased transcript_t)
  = 
    let h0 = HyperStack.ST.get() in
    CRF.finish (Ghost.hide a) s.hash_state tag;
    let h1 = HyperStack.ST.get() in
    B.(modifies_liveness_insensitive_buffer
      (footprint s `loc_union` (loc_region_only true Mem.tls_tables_region))
      (B.loc_buffer tag) h0 h1 tag)

let injectivity a t0 t1 =
  let b0 = Ghost.hide (transcript_bytes (Ghost.reveal t0)) in
  let b1 = Ghost.hide (transcript_bytes (Ghost.reveal t1)) in
  Model.CRF.injective a b0 b1;
  let aux () : Lemma
    (requires CRF.model /\ Model.CRF.crf a /\ b0 == b1)
    (ensures Ghost.reveal t0 == Ghost.reveal t1) =
    transcript_bytes_injective (Ghost.reveal t0) (Ghost.reveal t1)
  in Classical.move_requires aux ()