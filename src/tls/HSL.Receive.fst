module HSL.Receive

open FStar.Integers
open FStar.HyperStack.ST

module G = FStar.Ghost
module List = FStar.List.Tot

module HS = FStar.HyperStack
module ST = FStar.HyperStack.ST
module B = LowStar.Buffer

module HSM = HandshakeMessages
module LP = LowParse.Low.Base

module E = FStar.Error

open HSL.Common

#reset-options "--max_fuel 0 --max_ifuel 0 --using_facts_from '* -FStar.Tactics -FStar.Reflection'"

type inc_st_t = G.erased (bytes & in_progress_flt_t)

noeq
type hsl_state = {
  rgn: Mem.rgn;
  inc_st: (p:B.pointer inc_st_t{
    rgn `region_includes` B.loc_buffer p
  });
}

let region_of st = st.rgn

let parsed_bytes st h = fst (G.reveal (B.deref h st.inc_st))

let in_progress_flt st h = snd (G.reveal (B.deref h st.inc_st))

let invariant s h = B.live h s.inc_st

let footprint s = B.loc_buffer s.inc_st

let frame_hsl_state _ _ _ _ = ()

let create r =
  let inc_st = B.malloc r (G.hide (Seq.empty, F_none)) 1ul in
  { rgn = r; inc_st = inc_st }

assume val parsing_error : TLSError.error
assume val unexpected_flight_error : TLSError.error
assume val bytes_remain_error : TLSError.error

inline_for_extraction
noextract
let parse_hsm13
  (#a:Type) (#k:LP.parser_kind{k.LP.parser_kind_subkind == Some LP.ParserStrong})
  (#p:LP.parser k a) (#cl:LP.clens HSM.handshake13 a)
  (#gacc:LP.gaccessor HSM.handshake13_parser p cl)
  (tag:HSM.handshakeType{
    forall (m:HSM.handshake13).
      (HSM.tag_of_handshake13 m == tag) <==> cl.LP.clens_cond m})
  (f:a -> HSM.handshake13{
    forall (m:HSM.handshake13).
      cl.LP.clens_cond m ==> f (cl.LP.clens_get m) == m})
  (acc:LP.accessor gacc)
  : b:slice -> from:uint_32 ->
    Stack (TLSError.result (option (G.erased a & uint_32)))
    (requires fun h ->
      B.live h b.LP.base /\
      from <= b.LP.len)
    (ensures fun h0 r h1 ->
      B.modifies B.loc_none h0 h1 /\
      (match r with
       | E.Error _ -> True
       | E.Correct None -> True
       | E.Correct (Some (a_msg, pos)) ->
         pos <= b.LP.len /\
         valid_parsing13 (f (G.reveal a_msg)) b from pos h1))
  = fun b from ->
    
    let pos = HSM.handshake13_validator b from in

    if pos <= LP.validator_max_length then begin
      let parsed_tag = HSM.handshakeType_reader b from in
      if parsed_tag = tag then
        let payload_begin = acc b from in
        let payload =
          let h = ST.get () in
          let payload = LP.contents p h b payload_begin in
          G.hide payload
        in
        E.Correct (Some (payload, pos))
      else E.Error unexpected_flight_error
    end
    else if pos = LP.validator_error_not_enough_data then E.Correct None
    else E.Error parsing_error

let save_incremental_state
  (st:hsl_state) (b:slice) (from to:uint_32) (in_progress:in_progress_flt_t)
  : Stack unit
    (requires fun h ->
      B.live h st.inc_st /\
      B.live h b.LP.base /\
      B.loc_disjoint (footprint st) (B.loc_buffer b.LP.base) /\
      from <= to /\ to <= b.LP.len)
    (ensures fun h0 _ h1 ->
      B.modifies (footprint st) h0 h1 /\
      parsed_bytes st h1 ==
        Seq.slice (B.as_seq h1 b.LP.base) (v from) (v to) /\
      in_progress_flt st h1 == in_progress)
  = let inc_st =
      let h = ST.get () in
      let parsed_bytes = LP.bytes_of_slice_from_to h b from to in
      G.hide (parsed_bytes, in_progress)
    in
    B.upd st.inc_st 0ul inc_st

let reset_incremental_state (st:hsl_state)
  : Stack unit
    (requires fun h -> B.live h st.inc_st)
    (ensures fun h0 _ h1 ->
      B.modifies (footprint st) h0 h1 /\
      parsed_bytes st h1 == Seq.empty /\
      in_progress_flt st h1 == F_none)
  =  let inc_st = G.hide (Seq.empty, F_none) in
     B.upd st.inc_st 0ul inc_st

let err_or_insufficient_data
  (#a:Type) (#t:Type)
  (parse_result:TLSError.result (option a))
  (in_progress:in_progress_flt_t)
  (st:hsl_state) (b:slice) (from to:uint_32)
  : Stack (TLSError.result (option t))
    (requires fun h ->
      B.live h st.inc_st /\ B.live h b.LP.base /\
      B.loc_disjoint (footprint st) (B.loc_buffer b.LP.base) /\
      from <= to /\ to <= b.LP.len /\
      (E.Error? parse_result \/ parse_result == E.Correct None))
    (ensures  fun h0 r h1 ->
      B.modifies (footprint st) h0 h1 /\
      (match parse_result with
       | E.Error e -> r == E.Error e
       | E.Correct None ->
         r == E.Correct None /\
         parsed_bytes st h1 ==
           Seq.slice (B.as_seq h0 b.LP.base) (v from) (v to) /\
         in_progress_flt st h1 == in_progress))
  = match parse_result with
    | E.Error e -> E.Error e
    | E.Correct None ->
      save_incremental_state st b from to in_progress;
      E.Correct None

unfold let parse_pre (b:slice) (from:uint_32)
  : HS.mem -> Type0
  = fun (h:HS.mem) -> B.live h b.LP.base /\ from <= b.LP.len

let parse_hsm13_ee
  =  parse_hsm13
      HSM.Encrypted_extensions HSM.M13_encrypted_extensions
      HSM.handshake13_accessor_encrypted_extensions
      
let parse_hsm13_c
  = parse_hsm13
      HSM.Certificate HSM.M13_certificate
      HSM.handshake13_accessor_certificate

let parse_hsm13_cv
  = parse_hsm13
      HSM.Certificate_verify HSM.M13_certificate_verify
      HSM.handshake13_accessor_certificate_verify

let parse_hsm13_fin
  = parse_hsm13 
      HSM.Finished HSM.M13_finished
      HSM.handshake13_accessor_finished

let parse_hsm13_cr
  = parse_hsm13 
      HSM.Certificate_request HSM.M13_certificate_request
      HSM.handshake13_accessor_certificate_request

let parse_hsm13_eoed
  = parse_hsm13 
      HSM.End_of_early_data HSM.M13_end_of_early_data
      HSM.handshake13_accessor_end_of_early_data

let parse_hsm13_nst
  = parse_hsm13 
      HSM.New_session_ticket HSM.M13_new_session_ticket
      HSM.handshake13_accessor_new_session_ticket

let frame_valid_parsing13
  (msg:HSM.handshake13)
  (b:slice)
  (from to:uint_32)
  (l:B.loc)
  (h0 h1:HS.mem)
  : Lemma
    (requires
      valid_parsing13 msg b from to h0 /\
      B.loc_disjoint l (B.loc_buffer b.LP.base) /\
      B.modifies l h0 h1)
    (ensures valid_parsing13 msg b from to h1)
    [SMTPat (valid_parsing13 msg b from to h1);
     SMTPat (B.modifies l h0 h1)]
  = ()

#reset-options "--max_fuel 0 --max_ifuel 0 --using_facts_from '* -FStar.Tactics -FStar.Reflection -LowParse +LowParse.Bytes +LowParse.Slice'"

let receive_flight13_ee_c_cv_fin st b from to =
  let r = parse_hsm13_ee b from in
  match r with
  | E.Error _ | E.Correct None ->
    err_or_insufficient_data r F13_ee_c_cv_fin st b from to
  | E.Correct (Some (ee_payload, c_begin)) ->
    let r = parse_hsm13_c b c_begin in
    match r with
    | E.Error _ | E.Correct None ->
      err_or_insufficient_data r F13_ee_c_cv_fin st b from to
    | E.Correct (Some (c_payload, cv_begin)) ->
      let r = parse_hsm13_cv b cv_begin in
      match r with
      | E.Error _ | E.Correct None ->
        err_or_insufficient_data r F13_ee_c_cv_fin st b from to
      | E.Correct (Some (cv_payload, fin_begin)) ->
        let r = parse_hsm13_fin b fin_begin in
        match r with
        | E.Error _ | E.Correct None ->
          err_or_insufficient_data r F13_ee_c_cv_fin st b from to
        | E.Correct (Some (fin_payload, pos)) ->
          if pos <> to then E.Error bytes_remain_error
          else begin
            reset_incremental_state st;
            E.Correct (Some ({
              begin_c = c_begin;
              begin_cv = cv_begin;
              begin_fin = fin_begin;
              ee_msg = ee_payload;
              c_msg = c_payload;
              cv_msg = cv_payload;
              fin_msg = fin_payload
            }))
          end

let receive_flight13_ee_cr_c_cv_fin st b from to =
  let r = parse_hsm13_ee b from in
  match r with
  | E.Error _ | E.Correct None ->
    err_or_insufficient_data r F13_ee_cr_c_cv_fin st b from to
  | E.Correct (Some (ee_payload, cr_begin)) ->
    let r = parse_hsm13_cr b cr_begin in
    match r with
    | E.Error _ | E.Correct None ->
      err_or_insufficient_data r F13_ee_cr_c_cv_fin st b from to
    | E.Correct (Some (cr_payload, c_begin)) ->
      let r = parse_hsm13_c b c_begin in
      match r with
      | E.Error _ | E.Correct None ->
        err_or_insufficient_data r F13_ee_cr_c_cv_fin st b from to
      | E.Correct (Some (c_payload, cv_begin)) ->
        let r = parse_hsm13_cv b cv_begin in
        match r with
        | E.Error _ | E.Correct None ->
          err_or_insufficient_data r F13_ee_cr_c_cv_fin st b from to
        | E.Correct (Some (cv_payload, fin_begin)) ->
          let r = parse_hsm13_fin b fin_begin in
          match r with
          | E.Error _ | E.Correct None ->
            err_or_insufficient_data r F13_ee_cr_c_cv_fin st b from to
          | E.Correct (Some (fin_payload, pos)) ->
            if pos <> to then E.Error bytes_remain_error
            else begin
              reset_incremental_state st;
              E.Correct (Some ({
                begin_cr = cr_begin;
                begin_c = c_begin;
                begin_cv = cv_begin;
                begin_fin = fin_begin;
                ee_msg = ee_payload;
                cr_msg = cr_payload;
                c_msg = c_payload;
                cv_msg = cv_payload;
                fin_msg = fin_payload
              }))
            end

let mk_ee_fin
  (begin_fin:uint_32)
  (ee_msg:G.erased HSM.handshake13_m13_encrypted_extensions) 
  (fin_msg:G.erased HSM.handshake13_m13_finished)
  : flight13_ee_fin
  = Mkflight13_ee_fin begin_fin ee_msg fin_msg

let receive_flight13_ee_fin st b from to =
  let r = parse_hsm13_ee b from in
  match r with
  | E.Error _ | E.Correct None ->
    err_or_insufficient_data r F13_ee_fin st b from to
  | E.Correct (Some (ee_payload, fin_begin)) ->
    let r = parse_hsm13_fin b fin_begin in
    match r with
    | E.Error _ | E.Correct None ->
      err_or_insufficient_data r F13_ee_fin st b from to
    | E.Correct (Some (fin_payload, pos)) ->
      if pos <> to then E.Error bytes_remain_error
      else begin
        reset_incremental_state st;
        E.Correct (Some (mk_ee_fin fin_begin ee_payload fin_payload))
      end

let receive_flight13_fin st b from to =
  let r = parse_hsm13_fin b from in
  match r with
  | E.Error _ | E.Correct None ->
    err_or_insufficient_data r F13_fin st b from to
  | E.Correct (Some (fin_payload, pos)) ->
    if pos <> to then E.Error bytes_remain_error
    else begin
      reset_incremental_state st;
      E.Correct (Some ({ fin_msg = fin_payload }))
    end

let receive_flight13_c_cv_fin st b from to =
  let r = parse_hsm13_c b from in
  match r with
  | E.Error _ | E.Correct None ->
    err_or_insufficient_data r F13_c_cv_fin st b from to
  | E.Correct (Some (c_payload, cv_begin)) ->
    let r = parse_hsm13_cv b cv_begin in
    match r with
    | E.Error _ | E.Correct None ->
      err_or_insufficient_data r F13_c_cv_fin st b from to
    | E.Correct (Some (cv_payload, fin_begin)) ->
      let r = parse_hsm13_fin b fin_begin in
      match r with
      | E.Error _ | E.Correct None ->
        err_or_insufficient_data r F13_c_cv_fin st b from to
      | E.Correct (Some (fin_payload, pos)) ->
        if pos <> to then E.Error bytes_remain_error
        else begin
          reset_incremental_state st;
          E.Correct (Some ({
            begin_cv = cv_begin;
            begin_fin = fin_begin;
            c_msg = c_payload;
            cv_msg = cv_payload;
            fin_msg = fin_payload }))
        end

let receive_flight13_eoed st b from to =
  let r = parse_hsm13_eoed b from in
  match r with
  | E.Error _ | E.Correct None ->
    err_or_insufficient_data r F13_eoed st b from to
  | E.Correct (Some (eoed_payload, pos)) ->
    if pos <> to then E.Error bytes_remain_error
    else begin
      reset_incremental_state st;
      E.Correct (Some ({ eoed_msg = eoed_payload }))
    end

let receive_flight13_nst st b from to =
  let r = parse_hsm13_nst b from in
  match r with
  | E.Error _ | E.Correct None ->
    err_or_insufficient_data r F13_nst st b from to
  | E.Correct (Some (nst_payload, pos)) ->
    if pos <> to then E.Error bytes_remain_error
    else begin
      reset_incremental_state st;
      E.Correct (Some ({ nst_msg = nst_payload }))
    end
