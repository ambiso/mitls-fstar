(*--build-config
options:--fstar_home ../../../FStar --max_fuel 4 --initial_fuel 0 --max_ifuel 2 --initial_ifuel 1 --z3rlimit 20 --__temp_no_proj Handshake --__temp_no_proj Connection --use_hints --include ../../../FStar/ucontrib/CoreCrypto/fst/ --include ../../../FStar/ucontrib/Platform/fst/ --include ../../../hacl-star/secure_api/LowCProvider/fst --include ../../../kremlin/kremlib --include ../../../hacl-star/specs --include ../../../hacl-star/code/lib/kremlin --include ../../../hacl-star/code/bignum --include ../../../hacl-star/code/experimental/aesgcm --include ../../../hacl-star/code/poly1305 --include ../../../hacl-star/code/salsa-family --include ../../../hacl-star/secure_api/test --include ../../../hacl-star/secure_api/utils --include ../../../hacl-star/secure_api/vale --include ../../../hacl-star/secure_api/uf1cma --include ../../../hacl-star/secure_api/prf --include ../../../hacl-star/secure_api/aead --include ../../libs/ffi --include ../../../FStar/ulib/hyperstack --include ../../src/tls/ideal-flags;
--*)
module Handshake


open FStar.Heap
open FStar.HyperHeap
open FStar.HyperStack
open FStar.Seq
open FStar.Set
open Platform.Error
open Platform.Bytes
open TLSError
open TLSInfo
open TLSConstants
open Range
open HandshakeMessages // for the message syntax
open Handshake.Log // for Outgoing
open Epochs

module Sig = Signature
module HH = FStar.HyperHeap
module MR = FStar.Monotonic.RRef
module MS = FStar.Monotonic.Seq
module Nego = Negotiation
// For readabililty, we try to open/abbreviate fewer modules


(* A flag for runtime debugging of Handshake data.
   The F* normalizer will erase debug prints at extraction
   when this flag is set to false. *)

inline_for_extraction let hs_debug = true
val discard: bool -> ST unit
  (requires (fun _ -> True))
  (ensures (fun h0 _ h1 -> h0 == h1))
let discard _ = ()
let print s = discard (IO.debug_print_string ("HS | "^s^"\n"))
unfold val trace: s:string -> ST unit
  (requires (fun _ -> True))
  (ensures (fun h0 _ h1 -> h0 == h1))
unfold let trace = if hs_debug then print else (fun _ -> ())


// TODO : implement resumption
//val getCachedSession: cfg:config -> ch:ch -> ST (option session)
//  (requires (fun h -> True))
//  (ensures (fun h0 i h1 -> True))
//let getCachedSession cfg cg = None


// *** internal stuff: state machine, reader/writer counters, etc.

// some states keep digests (irrespective of their hash algorithm)
type digest = l:bytes{length l <= 32}

type machineState =
  | C_Idle
  | C_Wait_ServerHello
  | C_Wait_Finished1           // TLS 1.3
//| C_Wait_CCS1 of digest      // TLS resume, digest to be MACed by server
//| C_Wait_Finished1 of digest // TLS resume, digest to be MACed by server
  | C_Wait_ServerHelloDone     // TLS classic
  | C_Wait_CCS2 of digest      // TLS classic, digest to be MACed by server
  | C_Wait_Finished2 of digest // TLS classic, digest to be MACed by server
  | C_Complete

  | S_Idle
  | S_Sent_ServerHello         // TLS 1.3, intermediate state to encryption
  | S_Wait_Finished2 of digest // TLS 1.3, digest to be MACed by client
  | S_Wait_CCS1                // TLS classic
  | S_Wait_Finished1 of digest // TLS classic, digest to the MACed by client
//| S_Wait_CCS2 of digest      // TLS resume, digest to be MACed by client
//| S_Wait_Finished2 of digest // TLS resume, digest to be MACed by client
  | S_Complete

//17-03-24 consider using instead "if role = Client then clientState else serverServer"
//17-03-24 but that may break extraction to Kremlin and complicate typechecking
//17-03-24 we could also use two refinements.

// Removed error states, consider adding again to ensure the machine is stuck?

noeq type hs' = | HS:
  #region: rgn {is_hs_rgn region} ->
  r: role ->
  nego: Nego.t region r ->
  log: Handshake.Log.t {Handshake.Log.region_of log = region} ->
  ks: KeySchedule.ks (*region*) ->
  epochs: epochs region (Nego.nonce nego) ->
  state: ref machineState {state.HyperStack.id = region} -> // state machine; should be opaque and depend on r.
  hs'

let hs = hs' //17-04-08 interface limitation

let nonce (s:hs) = Nego.nonce s.nego
let region_of (s:hs) = s.region
let role_of (s:hs) = s.r
let random_of (s:hs) = nonce s
let config_of (s:hs) = Nego.local_config s.nego
let version_of (s:hs) = Nego.version s.nego
let resumeInfo_of (s:hs) = Nego.resume s.nego
let epochs_of (s:hs) = s.epochs

(* WIP on the handshake invariant
let inv (s:hs) (h:HyperStack.mem) =
  // let context = Negotiation.context h hs.nego in
  let transcript = Handshake.Log.transcript h hs.log in
  match HyperStack.sel h s.state with
  | C_Wait_ServerHello ->
      hs.role = Client /\
      transcript = [clientHello hs.nonce offer] /\
      "nego in Wait_ServerHello" /\
      "ks in wait_ServerHello"
  | _ -> True
*)

// the states of the HS sub-module will be subject to a joint invariant
// for example the Nego state is a function of ours.


let stateType (s:hs) = seq (epoch s.region (nonce s)) * machineState
let stateT (s:hs) (h:HyperStack.mem) : GTot (stateType s) = (logT s h, sel h s.state)

let forall_epochs (s:hs) h (p:(epoch s.region (nonce s) -> Type)) =
  (let es = logT s h in
   forall (i:nat{i < Seq.length es}).{:pattern (Seq.index es i)} p (Seq.index es i))
//epochs in h1 extends epochs in h0 by one

(*
#set-options "--lax"
let fresh_epoch h0 s h1 =
  let es0 = logT s h0 in
  let es1 = logT s h1 in
  Seq.length es1 > 0 &&
  es0 = Seq.slice es1 0 (Seq.length es1 - 1)

(* vs modifies clauses? *)
(* let unmodified_epochs s h0 h1 =  *)
(*   forall_epochs s h0 (fun e ->  *)
(*     let rs = regions e in  *)
(*     (forall (r:rid{Set.mem r rs}).{:pattern (Set.mem r rs)} Map.sel h0 r = Map.sel h1 r)) *)
*)

let latest h (s:hs{Seq.length (logT s h) > 0}) = // accessing the latest epoch
  let es = logT s h in
  Seq.index es (Seq.length es - 1)

// separation policy: the handshake mutates its private state,
// only depends on it, and only extends the log with fresh epochs.

// placeholder, to be implemented as a stateful property.
let completed #rgn #nonce e = True

// consider adding an optional (resume: option sid) on the client side
// for now this bit is not explicitly authenticated.

// Well-formed logs are all prefixes of (Epoch; Complete)*; Error
// This crucially assumes that TLS keeps track of OutCCS and InCCSAck
// so that it knows which reader & writer to use (not always the latest ones):
// - within InCCSAck..OutCCS, we still use the older writer
// - within OutCCS..InCCSAck, we still use the older reader
// - otherwise we use the latest readers and writers

// abstract invariant; depending only on the HS state (not the epochs state)
// no need for an epoch states invariant here: the HS never modifies them

assume val hs_invT : s:hs -> epochs:seq (epoch s.region (nonce s)) -> machineState -> Type0

let hs_inv (s:hs) (h: HyperStack.mem) = True
(* 17-04-08 TODO deal with inferred logic qualifiers
  hs_invT s (logT s h) (sel h (HS?.state s))  //An abstract invariant of HS-internal state
  /\ Epochs.containsT s.epochs h                //Nothing deep about these next two, since they can always
  /\ HyperHeap.contains_ref s.state.ref (HyperStack.HS?.h h)                 //be recovered by 'recall'; carrying them in the invariant saves the trouble

//A framing lemma with a very trivial proof, because of the way stateT abstracts the state-dependent parts
*)

#set-options "--lax"
let frame_iT_trivial  (s:hs) (rw:rw) (h0:HyperStack.mem) (h1:HyperStack.mem)
  : Lemma (stateT s h0 = stateT s h1  ==>  iT s rw h0 = iT s rw h1)
  = ()

//Here's a framing on stateT connecting it to the region discipline
let frame_stateT  (s:hs) (rw:rw) (h0:HyperStack.mem) (h1:HyperStack.mem) (mods:Set.set rid)
  : Lemma
    (requires
      HH.modifies_just mods (HyperStack.HS?.h h0) (HyperStack.HS?.h h1) /\
      Map.contains (HyperStack.HS?.h h0) s.region /\
      not (Set.mem s.region mods))
    (ensures stateT s h0 = stateT s h1)
  = ()

//This is probably the framing lemma that a client of this module will want to use
let frame_iT  (s:hs) (rw:rw) (h0:HyperStack.mem) (h1:HyperStack.mem) (mods:Set.set rid)
  : Lemma
    (requires
      HH.modifies_just mods (HyperStack.HS?.h h0) (HyperStack.HS?.h h1) /\
      Map.contains (HyperStack.HS?.h h0) s.region /\
      not (Set.mem s.region mods))
    (ensures stateT s h0 = stateT s h1 /\ iT s rw h0 = iT s rw h1)
=
  frame_stateT s rw h0 h1 mods;
  frame_iT_trivial s rw h0 h1



// factored out; indexing to be reviewed
let register hs keys =
    let ep = //? we don't have a full index yet for the epoch; reuse the one for keys??
      let h = admit() in
      Epochs.recordInstanceToEpoch #hs.region #(nonce hs) h keys in // just coercion
    Epochs.add_epoch hs.epochs ep // actually extending the epochs log


(* ---------------- signature stuff, to be moved (at least) to Nego -------------------- *)

// deep subtyping...
let optHashAlg_prime_is_optHashAlg: result hashAlg' -> Tot (result TLSConstants.hashAlg) =
  function
  | Error z -> Error z
  | Correct h -> Correct h
let sigHashAlg_is_tuple_sig_hash: sigHashAlg -> Tot (sigAlg * TLSConstants.hashAlg) =
  function | a,b -> a,b
let rec list_sigHashAlg_is_list_tuple_sig_hash: list sigHashAlg -> Tot (list (TLSConstants.sigAlg * TLSConstants.hashAlg)) =
  function
  | [] -> []
  | hd::tl -> (sigHashAlg_is_tuple_sig_hash hd) :: (list_sigHashAlg_is_list_tuple_sig_hash tl)

// why an option?
val to_be_signed: pv:protocolVersion -> role -> csr:option bytes{None? csr <==> pv = TLS_1p3} -> bytes -> Tot bytes
let to_be_signed pv role csr tbs =
  match pv, csr with
  | TLS_1p3, None ->
      let pad = abytes (String.make 64 (Char.char_of_int 32)) in
      let ctx =
        match role with
        | Server -> "TLS 1.3, server CertificateVerify"
        | Client -> "TLS 1.3, client CertificateVerify"  in
      pad @| abytes ctx @| abyte 0z @| tbs
  | _, Some csr -> csr @| tbs

val sigHashAlg_of_ske: bytes -> Tot (option (sigHashAlg * bytes))
let sigHashAlg_of_ske signature =
  if length signature > 4 then
   let h, sa, sigv = split2 signature 1 1 in
   match vlsplit 2 sigv with
   | Correct (sigv, eof) ->
     begin
     match length eof, parseSigAlg sa, optHashAlg_prime_is_optHashAlg (parseHashAlg h) with
     | 0, Correct sa, Correct (Hash h) -> Some ((sa,Hash h), sigv)
     | _, _, _ -> None
     end
   | Error _ -> None
  else None

let sig_algs (mode: Negotiation.mode) (sh_alg: TLSConstants.hashAlg)
 =
  // Signature agility (following the broken rules of 7.4.1.4.1. in RFC5246)
  // If no signature nego took place we use the SA and KDF hash from the CS
  let sa = mode.Nego.n_sigAlg in
  let algs =
    match mode.Nego.n_extensions.TLSInfo.ne_signature_algorithms with
    | Some l -> l
    | None -> [sa, sh_alg] in
  let algs = List.Tot.filter (fun (s,_) -> s = sa) algs in
  let sa, ha =
    match algs with
    | ha::_ -> ha
    | [] -> (sa, sh_alg) in
  let a = Signature.(Use (fun _ -> true) sa [ha] false false) in
  (a, sa, ha)

(* ------- Pure functions between offer/mode and their message encodings -------- *)

(*
let clientHello offer = // pure; shared by Client and Server
  let sid =
    match offer.co_resume with
    | None -> empty_bytes
    | Some x -> x
    in
  (* In Extensions: prepare client extensions, including key shares *)
  //17-03-30 where are the keyshares? How to convert them?
  let ext = Extensions.prepareExtensions
    offer.co_protocol_version
    offer.co_cipher_suites
    false false //17-03-30 ??
    offer.co_sigAlgs
    offer.co_namedGroups // list of named groups?
    None //17-03-30 ?? optional (cvd,svd)
    offer.co_client_shares // apparently at most one for now
    in
  {
    ch_protocol_version = offer.co_protocol_version;
    ch_client_random = offer.co_client_random;
    ch_sessionID = sid;
    ch_cipher_suites = offer.co_cipher_suites;
    ch_raw_cipher_suites = None;
    ch_compressions = offer.co_compressions;
    ch_extensions = Some ext }
*)

(* -------------------- Handshake Client ------------------------ *)

val client_ClientHello: s:hs -> i:id -> ST (result (Handshake.Log.outgoing i))
  (requires fun h0 ->
    let n = MR.m_sel h0 Nego.(s.nego.state) in
    let t = transcript h0 s.log in
    let k = HyperStack.sel h0 s.ks.KeySchedule.state in
    match n with
    | Nego.C_Init nonce -> k = KeySchedule.(C (C_Init nonce)) /\ t = []
    | _ -> False )
  (ensures fun h0 r h1 ->
    let n = MR.m_sel h0 Nego.(s.nego.state) in
    let t = transcript h0 s.log in
    let k = HyperStack.sel h1 s.ks.KeySchedule.state in
    ( Correct? r ==>
      ( match n with
        | Nego.C_Offer offer -> (
          ( if offer.ch_protocol_version = TLS_1p3
            then k = KeySchedule.(C(C_13_wait_SH
              (nonce s)
              None (*TODO: es for 0RTT*)
              None (*TODO: binders *)
              (Nego.gs_of offer)))
            else k = KeySchedule.(C(C_12_Full_CH offer.ch_client_random)) /\
          t = [ClientHello offer] ))
        | _ -> False )))

let client_ClientHello hs i =
  (* Negotiation computes the list of groups from the configuration;
     KeySchedule computes and serializes the shares from these groups (calling into CommonDH)
     Messages should do the serialization (calling into CommonDH), but dependencies are tricky *)
  let shares =
    match (config_of hs).maxVer  with
      | TLS_1p3 -> (* compute shares for groups in offer *)
        // TODO get binder keys too
        let gx = KeySchedule.ks_client_13_1rtt_init hs.ks (config_of hs).namedGroups in
        trace "offering ClientHello 1.3";
        Some gx
      | _ ->
        let si = KeySchedule.ks_client_12_init hs.ks in  // we may need si to carry looked up PSKs
        trace "offering ClientHello 1.2";
        None
    in
  let offer = Nego.client_ClientHello hs.nego shares in (* compute offer from configuration *)
  Handshake.Log.send hs.log (ClientHello offer);  // TODO decompose in two steps, appending the binders
  hs.state := C_Wait_ServerHello; // we may still need to keep parts of ch
  Correct(Handshake.Log.next_fragment hs.log i)

// requires !hs.state = Wait_ServerHello
// ensures TLS 1.3 ==> installed handshake keys
let client_ServerHello (s:hs) (sh:sh) (* digest:Hashing.anyTag *) : St incoming =
  trace "client_ServerHello";
  match Nego.client_ServerHello s.nego sh with
  | Error z -> InError z
  | Correct mode ->
    let pv = mode.Nego.n_protocol_version in
    let ha = aeAlg_hash mode.Nego.n_aeAlg in
    let ka = mode.Nego.n_kexAlg in 
    Handshake.Log.setParams s.log pv ha (Some ka) None (*?*);
    match pv, ka with
    | TLS_1p3, Kex_DHE //, Some gy
    | TLS_1p3, Kex_ECDHE //, Some gy
    ->
      begin
        trace "Running TLS 1.3";
        let digest = Handshake.Log.hash_tag #ha s.log in 
        let hs_keys = KeySchedule.ks_client_13_sh s.ks
          mode.Nego.n_server_random
          mode.Nego.n_cipher_suite
          digest
          (Some?.v mode.Nego.n_server_share)
          false (* in case we provided PSKs earlier, ignore them from now on *)
          in
        register s hs_keys; // register new epoch
        s.state := C_Wait_Finished1;
        Epochs.incr_reader s.epochs; // Client 1.3 HSK switch to handshake key for decrypting EE etc...
        InAck true false // Client 1.3 HSK
      end
    | TLS_1p3, _ -> InError(AD_internal_error, perror __SOURCE_FILE__ __LINE__ "Unsupported group negotiated")
    | _, _ ->
      begin
        trace "Running TLS classic";
        s.state := C_Wait_ServerHelloDone;
        InAck false false
      end

(* receive Certificate...ServerHelloDone, with optional cert request. Not for TLS 1.3 *)
val client_ServerHelloDone:
  hs ->
  HandshakeMessages.crt ->
  HandshakeMessages.ske ->
  option HandshakeMessages.cr ->
  ST incoming
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))
let client_ServerHelloDone hs c ske ocr =
    trace "processing ...ServerHelloDone";
    match Nego.client_ServerKeyExchange hs.nego c ske ocr with
    | Error z -> InError z
    | Correct mode -> (
      ( match ocr with
        | None -> ()
        | Some cr ->
            trace "processing certificate request (TODO)";
            let cc = {crt_chain = []} in
            Handshake.Log.send hs.log (Certificate cc));

      let gy = Some?.v (mode.Nego.n_server_share) in // already set in KS
      let gx =
        KeySchedule.ks_client_12_full_dh hs.ks
        mode.Nego.n_server_random
        mode.Nego.n_protocol_version
        mode.Nego.n_cipher_suite
        mode.Nego.n_extensions.ne_extended_ms // a flag controlling the use of ems
        gy in
      let (|g, _|) = gy in
      let msg = ClientKeyExchange ({cke_kex_c = kex_c_of_dh_key #g gx}) in
      let ha = verifyDataHashAlg_of_ciphersuite (mode.Nego.n_cipher_suite) in
      let digestClientKeyExchange = Handshake.Log.send_tag #ha hs.log msg  in
      let cfin_key, app_keys = KeySchedule.ks_client_12_set_session_hash hs.ks digestClientKeyExchange in
      register hs app_keys;
      // we send CCS then Finished;  we will use the new keys only after CCS

      let cvd = TLSPRF.verifyData (mode.Nego.n_protocol_version,mode.Nego.n_cipher_suite) cfin_key Client digestClientKeyExchange in
      let digestClientFinished = Handshake.Log.send_CCS_tag #ha hs.log (Finished ({fin_vd = cvd})) false in
      hs.state := C_Wait_CCS2 digestClientFinished;
      InAck false false)

#set-options "--lax"
(* receive EncryptedExtension...ServerFinished for TLS 1.3, roughly mirroring client_ServerHelloDone *)
val client_ServerFinished_13:
  s: hs ->
  ee: HandshakeMessages.ee ->
  ocr: option HandshakeMessages.cr ->
  c: HandshakeMessages.crt ->
  cv: HandshakeMessages.cv ->
  svd: bytes ->
  digestCert: Hashing.anyTag ->
  digestCertVerify: Hashing.anyTag ->
  digestServerFinished: Hashing.anyTag ->
  St incoming
let client_ServerFinished_13 hs ee ocr c cv (svd:bytes) digestCert digestCertVerify digestServerFinished =
    match Nego.clientComplete_13 hs.nego ee ocr c cv digestCert with
    | Error z -> InError z
    | Correct mode ->
        let (sfin_key, cfin_key, app_keys) = KeySchedule.ks_client_13_sf hs.ks digestServerFinished in
        let (| finId, sfin_key |) = sfin_key in
        if not (HMAC.UFCMA.verify sfin_key digestCertVerify svd)
        then InError (AD_decode_error, "Finished MAC did not verify")
        else (
          let ha = verifyDataHashAlg_of_ciphersuite (mode.Nego.n_cipher_suite) in
          let digest =
            match ocr with
            | Some cr -> Handshake.Log.send_tag #ha hs.log (Certificate ({crt_chain = []}))
            | None -> digestServerFinished in
          let (| finId, cfin_key |) = cfin_key in
          let cvd = HMAC.UFCMA.mac cfin_key digest in
          Handshake.Log.send hs.log (Finished ({fin_vd = cvd}));

          register hs app_keys; // start using ATKs in both directions
          Epochs.incr_reader hs.epochs;
          Epochs.incr_writer hs.epochs; // 17-04-01 TODO how to signal incr_writer to TLS?
          hs.state := C_Complete; // full_mode (cvd,svd); do we still need to keep those?
          InAck true true // Client 1.3 ATK
          )

let client_ServerFinished hs f digest =
    let sfin_key = KeySchedule.ks_12_finished_key hs.ks in
    let mode = Nego.getMode hs.nego in
    if f.fin_vd = TLSPRF.verifyData (mode.Nego.n_protocol_version,mode.Nego.n_cipher_suite) sfin_key Server digest
    then (
      hs.state := C_Complete; // ADL: TODO need a proper renego state Idle (Some (vd,svd)))};
      InAck false true // Client 1.2 ATK
      )
    else
      InError (AD_decode_error, "Finished MAC did not verify")


(* -------------------- Handshake Server ------------------------ *)

(* called by server_ClientHello after sending TLS 1.2 ServerHello *)
// static precondition: n.n_protocol_version <> TLS_1p3 && Some? n.n_sigAlg && (n.n_kexAlg = Kex_DHE || n.n_kexAlg = Kex_ECDHE)
// should instead use Nego for most of this processing
let server_ServerHelloDone hs =
  trace "Sending ...ServerHelloDone";
  let mode = Nego.getMode hs.nego in
  let Some chain = mode.Nego.n_server_cert in // was using Cert.lookup_chain cfg.cert_chain_file

  let ngroups =
    match mode.Nego.n_extensions.ne_supported_groups with
    | Some gl -> List.Tot.choose CommonDH.group_of_namedGroup gl
    | None -> List.Tot.choose
        // Cannot use an elliptic curve if SupportedGroups is missing in TLS<=1.2
        (fun ng -> if SEC? ng then CommonDH.group_of_namedGroup ng else None)
        (config_of hs).namedGroups in

  match ngroups with
  | [] -> InError (AD_handshake_failure,
     perror __SOURCE_FILE__ __LINE__ "no shared supported group")
  | g::_ ->
   begin
    let cr = mode.Nego.n_offer.ch_client_random in
    let gy = KeySchedule.ks_server_12_init_dh hs.ks
      cr
      mode.Nego.n_protocol_version
      mode.Nego.n_cipher_suite
      mode.Nego.n_extensions.ne_extended_ms
      g in
    // ad hoc signing of the nonces and server key share
    let kex_s = KEX_S_DHE gy in
    let tbs =
      let sv = kex_s_to_bytes kex_s in
      let csr = cr @| mode.Nego.n_server_random in
      to_be_signed mode.Nego.n_protocol_version Server (Some csr) sv in

    // easier: let signature = Nego.sign hs.nego tbs, already in the right format, so that we can entirely hide agility.

    let a, sa, ha = sig_algs mode (Hash Hashing.Spec.SHA1) in
    let skey = admit() in //Nego.getSigningKey #a hs.nego in
    let sigv = Signature.sign #a ha skey tbs in
    if not (length sigv >= 2 && length sigv < 65536)
    then InError (AD_decode_error, perror __SOURCE_FILE__ __LINE__ "signature length out of range")
    else
      begin
        lemma_repr_bytes_values (length sigv);
        let signature = hashAlgBytes ha @| sigAlgBytes sa @| vlbytes 2 sigv in
        let ske = {ske_kex_s = kex_s; ske_sig = signature} in
        Handshake.Log.send hs.log (Certificate ({crt_chain = chain}));
        Handshake.Log.send hs.log (ServerKeyExchange ske);
        Handshake.Log.send hs.log ServerHelloDone;
        hs.state := S_Wait_CCS1;
        InAck true false // Server 1.2 ATK
      end
   end

assume val serverHello: TLSInfo.random -> Negotiation.mode -> sh

(* receive ClientHello, and choose a protocol version and mode *)
val server_ClientHello: hs -> HandshakeMessages.ch -> ST incoming
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))
let server_ClientHello hs offer =
    trace "Processing ClientHello";
    let sid = CoreCrypto.random 32 (* always? discard in 1.3? *) in
    match Nego.server_ClientHello hs.nego offer sid with
    | Error z -> InError z
    | Correct mode -> (
      let server_share =
        match mode.Nego.n_protocol_version, mode.Nego.n_client_share  with
        | TLS_1p3, Some  (| g, gx |) ->
          Some (CommonDH.ServerKeyShare (
            KeySchedule.ks_server_13_1rtt_init hs.ks offer.ch_client_random mode.Nego.n_cipher_suite g gx
          ))
        | _ -> None in
      (* Extensions:negotiateServerExtensions *)
      match Extensions.negotiateServerExtensions
        mode.Nego.n_protocol_version
        offer.ch_extensions
        offer.ch_cipher_suites
        (config_of hs)
        mode.Nego.n_cipher_suite
        None (*Nego.resume hs.nego *)
        server_share
        false
      with
        | Error z -> InError z
        | Correct sext -> (
          let msg = serverHello (nonce hs) mode in
          let ha = verifyDataHashAlg_of_ciphersuite (mode.Nego.n_cipher_suite) in
          let digestServerHello = Handshake.Log.send_tag #ha hs.log (ServerHello msg) in
          if mode.Nego.n_protocol_version = TLS_1p3
          then (
            trace "Derive handshake keys";
            let hs_keys = KeySchedule.ks_server_13_sh hs.ks digestServerHello (* digestServerHello *)  in
            register hs hs_keys;
            // We will start using the HTKs later (after sending SH, and after receiving 0RTT traffic)
            hs.state := S_Sent_ServerHello;
            InAck false false)

          else server_ServerHelloDone hs // sending our whole flight hopefully in a single packet.
          ))

(* receive ClientKeyExchange; CCS *)
let server_ClientCCS1 hs cke (* clientCert *) digestCCS1 =
    // FIXME support optional client c and cv
    // let ems = n.n_extensions.ne_extended_ms in // ask Nego?
    trace "Process Client CCS";
    match cke.cke_kex_c with
      | KEX_C_RSA _ | KEX_C_DH -> InError(AD_decode_error, perror __SOURCE_FILE__ __LINE__ "Expected DHE/ECDHE CKE")
      | KEX_C_DHE gyb
      | KEX_C_ECDHE gyb -> (
          let mode = Nego.getMode hs.nego in  //TODO read back from mode.

          // ADL: the type of gyb will change from bytes to g & share g; for now we parse here.
          let Some (|g,  _|) = mode.Nego.n_server_share in
          let gy: CommonDH.share g = CommonDH.parse g gyb in
          let g_gy = (|g, gy|) in
          let app_keys = KeySchedule.ks_server_12_cke_dh hs.ks g_gy digestCCS1 in
          register hs app_keys;
          Epochs.incr_reader hs.epochs;
          // use the new reader; will use the new writer only after sending CCS
          hs.state := S_Wait_Finished1 digestCCS1; // keep digest to verify the Client Finished
          InAck true false  // Server 1.2 ATK
          )

(* receive ClientFinish *)
val server_ClientFinished:
  hs -> bytes -> Hashing.anyTag -> Hashing.anyTag -> St incoming
let server_ClientFinished hs cvd digestCCS digestClientFinished =
    trace "Process Client Finished";
    let fink = KeySchedule.ks_12_finished_key hs.ks in
    let mode = Nego.getMode hs.nego in
    let alpha = (mode.Nego.n_protocol_version, mode.Nego.n_cipher_suite) in
    let ha = verifyDataHashAlg_of_ciphersuite (mode.Nego.n_cipher_suite) in
    if cvd = TLSPRF.verifyData alpha fink Client digestCCS
    then
      let svd = TLSPRF.verifyData alpha fink Server digestClientFinished in
      let unused_digest = Handshake.Log.send_CCS_tag #ha hs.log (Finished ({fin_vd = svd})) true in
      InAck false false
      // TODO hs.state := S_Complete; InAck false true // Server 1.2 ATK
      // ? tricky before installing the ATK writer
    else
      InError (AD_decode_error, "Finished MAC did not verify")

(* send EncryptedExtensions; Certificate; CertificateVerify; Finish (1.3) *)
val server_ServerFinished_13: hs -> i:id -> ST (result (outgoing i))
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))
let server_ServerFinished_13 hs i =
    // static pre: n.n_protocol_version = TLS_1p3 && Some? n.n_sigAlg && (n.n_kexAlg = Kex_DHE || n.n_kexAlg = Kex_ECDHE)
    // most of this should go to Nego
    trace "Prepare Server Finished";
    let mode = Nego.getMode hs.nego in
    let Some chain = mode.Nego.n_server_cert in
    let pv = mode.Nego.n_protocol_version in
    let cs = mode.Nego.n_cipher_suite in
    let sh_alg = sessionHashAlg pv cs in
    let halg = verifyDataHashAlg_of_ciphersuite cs in // Same as sh_alg but different type FIXME

    Handshake.Log.send hs.log (EncryptedExtensions ({ee_extensions = []}));
    let digestSig = Handshake.Log.send_tag #halg hs.log (Certificate ({crt_chain = chain})) in

    // signing of the formatted session digest
    let tbs : bytes =
      let Hash sh_alg = sh_alg in
      let hL = Hashing.Spec.tagLen sh_alg in
      let zeroes = Platform.Bytes.abytes (String.make hL (Char.char_of_int 0)) in
      let rc = Hashing.compute sh_alg zeroes in
      let lb = digestSig @| rc in
      to_be_signed pv Server None lb in

    let a, sa, ha = sig_algs mode sh_alg in
    let skey: Signature.skey a = admit() in // Nego.getSigningKey #a hs.nego in // Signature.lookup_key #a mode.Nego.n_offer.private_key_file
    let sigv = Signature.sign #a ha skey tbs in
    if not (length sigv >= 2 && length sigv < 65536)
    then Error (AD_decode_error, perror __SOURCE_FILE__ __LINE__ "signature length out of range")
    else
      begin
        lemma_repr_bytes_values (length sigv);
        let signature = hashAlgBytes ha @| sigAlgBytes sa @| vlbytes 2 sigv in
        let digestFinished = Handshake.Log.send_tag #halg hs.log (CertificateVerify ({cv_sig = signature})) in
        let (| sfinId, sfin_key |), _ = KeySchedule.ks_server_13_finished_keys hs.ks in
        let svd = HMAC.UFCMA.mac #sfinId sfin_key digestFinished in
        let digestServerFinished = Handshake.Log.send_tag #halg hs.log (Finished ({fin_vd = svd})) in
        // we need to call KeyScheduke twice, to pass this digest
        let app_keys = KeySchedule.ks_server_13_sf hs.ks digestServerFinished in
        register hs app_keys;
        Epochs.incr_writer hs.epochs; // Switch to ATK after the SF
        Epochs.incr_reader hs.epochs; // TODO when to increment the reader?
        hs.state := S_Wait_Finished2 digestServerFinished;
        Handshake.Log.send_signals hs.log true true;
        Correct(Handshake.Log.next_fragment hs.log i)
      end

(* receive ClientFinish 1.3 *)
val server_ClientFinished_13: hs ->
  bytes ->
  Hashing.anyTag ->
  option (HandshakeMessages.crt * HandshakeMessages.cv * Hashing.anyTag) -> St incoming
let server_ClientFinished_13 hs f digestClientFinished clientAuth =
   trace "Process Client Finished";
   match clientAuth with
   | Some  (c,cv,digest) ->
      InError(AD_internal_error,
        perror __SOURCE_FILE__ __LINE__ "Client CertificateVerify validation not implemented")
   | None ->
       let _, (| i, cfin_key |) = KeySchedule.ks_server_13_finished_keys hs.ks in
       // TODO MACVerify digestClientFinished
       if HMAC.UFCMA.verify #i cfin_key digestClientFinished f
       then (
          hs.state := S_Complete;
          Epochs.incr_reader hs.epochs; // finally start reading with AKTs
          InAck true true  // Server 1.3 ATK
          )
       else InError (AD_decode_error, "Finished MAC did not verify")

(* TODO: resumption *)
assume val server_send_server_finished_res: hs -> ST unit
  (requires (fun h -> True))
  (ensures (fun h0 i h1 -> True))

(* Handshake API: PUBLIC Functions, taken from FSTI *)

// returns the protocol version negotiated so far
// (used for formatting outgoing packets, but not trusted)
(*
val version: s:hs -> Tot protocolVersion
  (requires (hs_inv s))
  (ensures (fun h0 pv h1 -> h0 = h1))
  *)

(* // JP: the outside has been checked against the fsti which had another *)
(* // definition (at the bottom of this file) *)
(* val iT_old:  s:hs -> rw:rw -> ST int *)
(*   (requires (fun h -> True)) *)
(*   (ensures (fun h0 i h1 -> True)) *)
(* let iT_old (HS r res cfg id l st) rw = *)
(*   match rw with *)
(*   | Reader -> (!st).hs_reader *)
(*   | Writer -> (!st).hs_writer *)


(* ----------------------- Control Interface -------------------------*)

let create (parent:rid) cfg role resume =
  let r = new_region parent in
  let log = Handshake.Log.create r None (* cfg.maxVer (Nego.hashAlg nego) *) in
  //let nonce = Nonce.mkHelloRandom r r0 in //NS: should this really be Client?
  let ks, nonce = KeySchedule.create #r role in
  let nego = Nego.create r role cfg resume nonce in
  let epochs = Epochs.create r nonce in
  let state = ralloc r (if role = Client then C_Idle else S_Idle) in
  let x: hs = HS role nego log ks epochs state in //17-04-17 why needed?
  x

let rehandshake s c = Platform.Error.unexpected "rehandshake: not yet implemented"

let rekey s c = Platform.Error.unexpected "rekey: not yet implemented"

let request s c = Platform.Error.unexpected "request: not yet implemented"

let invalidateSession hs = ()
// ADL: disabling this for top-level API testing purposes
// Platform.Error.unexpected "invalidateSession: not yet implemented"


(* ------------------ Outgoing -----------------------*)

let next_fragment (hs:hs) i =
    trace "next_fragment";
    let outgoing = Handshake.Log.next_fragment hs.log i in
    match outgoing, !hs.state with
    // when the output buffer is empty, we send extra messages in two cases
    // we prepare the initial ClientHello; or
    // after sending ServerHello in plaintext, we continue with encrypted traffic
    // otherwise, we just returns buffered messages and signals
    | Outgoing None false false false, C_Idle -> client_ClientHello hs i
    | Outgoing None false false false, S_Sent_ServerHello -> server_ServerFinished_13 hs i
    | _ -> Correct outgoing // nothing to do

(* ----------------------- Incoming ----------------------- *)

let recv_fragment (hs:hs) #i rg f =
    trace "recv_fragment";
    let h0 = ST.get() in
    let flight = Handshake.Log.receive hs.log f in
    match !hs.state, flight with
      | _, None -> InAck false false // nothing happened

      | C_Idle, _ -> InError (AD_unexpected_message, "Client hasn't sent hello yet")
      | C_Wait_ServerHello, Some ([ServerHello sh], []) -> client_ServerHello hs sh 
      //| C_Wait_ServerHello, Some ([ServerHello sh], [digest]) -> client_ServerHello hs sh digest
      | C_Wait_ServerHelloDone, Some ([Certificate c; ServerKeyExchange ske; ServerHelloDone], [unused_digestCert]) ->
          // assert (Some? pv && pv <> Some TLS_1p3 && res = Some false && (kex = Some Kex_DHE || kex = Some Kex_ECDHE))
          client_ServerHelloDone hs c ske None

      | C_Wait_ServerHelloDone, Some ([Certificate c; ServerKeyExchange ske; CertificateRequest cr; ServerHelloDone], [unused_digestCert]) ->
          // assert (Some? pv && pv <> Some TLS_1p3 && res = Some false && (kex = Some Kex_DHE || kex = Some Kex_ECDHE))
          client_ServerHelloDone hs c ske (Some cr)

      | C_Wait_Finished1, Some ([EncryptedExtensions ee; Certificate c; CertificateVerify cv; Finished f], [digestCert; digestCertVerify; digestServerFinished]) ->
          // assert (Some? pv && pv = Some TLS_1p3 && (kex = Some Kex_DHE || kex = Some Kex_ECDHE))
          client_ServerFinished_13 hs ee None c cv f.fin_vd digestCert digestCertVerify digestServerFinished

      | C_Wait_Finished1, Some ([EncryptedExtensions ee; CertificateRequest cr; Certificate c; CertificateVerify cv; Finished f], [digestCert; digestCertVerify; digestServerFinished]) ->
          // assert (Some? pv && pv = Some TLS_1p3 && (kex = Some Kex_DHE || kex = Some Kex_ECDHE));
          client_ServerFinished_13 hs ee (Some cr) c cv f.fin_vd digestCert digestCertVerify digestServerFinished

      // we'll have other variants for resumption, shc as ([EncryptedExtensions ee; Finished f], [...])

      | C_Wait_Finished2 digest, Some ([Finished f], [digestServerFinished]) ->
          // assert Some? pv && pv <> Some TLS_1p3
          client_ServerFinished hs f digest

      //17-03-24 how to receive binders? we need the intermediate hash
      | S_Idle, Some ([ClientHello ch], [])  -> server_ClientHello hs ch
      | S_Wait_Finished1 digest, Some ([Finished f], [digestClientFinish]) ->
          server_ClientFinished hs f.fin_vd digest digestClientFinish

      | S_Wait_Finished2 s, Some ([Finished f], [digest]) -> server_ClientFinished_13 hs f.fin_vd digest None
      | S_Wait_Finished2 s, Some ([Certificate c; CertificateVerify cv; Finished f], [digestSigned; digestClientFinished; _]) ->
          server_ClientFinished_13 hs f.fin_vd digestClientFinished (Some (c,cv,digestSigned))

       // are we missing the case with a Certificate but no CertificateVerify?
      | _, Some _ -> 
          trace "DISCARD FLIGHT";
          InAck false false
          //InError(AD_unexpected_message, "unexpected flight")


// TODO check CCS once committed to TLS 1.3 yields an alert
let recv_ccs (hs:hs) =
    trace "recv_ccs";
    // assert pv <> TLS 1.3
    // CCS triggers completion of the incoming flight of messages.
    match Handshake.Log.receive_CCS #(Nego.hashAlg hs.nego) hs.log with
    | None -> InError(AD_unexpected_message, "CCS received at wrong time")
    | Some (ms, digests, digest) ->
        match !hs.state, ms, digests with
        | C_Wait_CCS2 digest, [], [] -> (
            trace "Processing CCS"; 
            hs.state := C_Wait_Finished2 digest;
            Epochs.incr_reader hs.epochs;
            InAck true false // Client 1.2 ATK
            )

        | C_Wait_CCS2 digest, [SessionTicket st], [] -> (
            trace "Processing SessionTicket; CCS. WARNING: no support for tickets"; 
            // now expect encrypted finish on this digest; shall we tell Nego? 
            hs.state := C_Wait_Finished2 digest;
            Epochs.incr_reader hs.epochs;
            InAck true false // Client 1.2 ATK
            )

        | S_Wait_CCS1, [ClientKeyExchange cke], [] ->
            // assert (Some? pv && pv <> Some TLS_1p3 && (kex = Some Kex_DHE || kex = Some Kex_ECDHE))
            server_ClientCCS1 hs cke digest
(*
        // FIXME support optional client c and cv
        | S_HelloDone n, [Certificate c; ClientKeyExchange cke], [digestClientKeyExchange]
          when (c.crt_chain = [] && Some? pv && pv <> Some TLS_1p3 && (kex = Some Kex_DHE || kex = Some Kex_ECDHE)) ->
            server_ClientCCS hs cke digestClientKeyExchange (Some (c, None))

        | S_HelloDone n, [Certificate c; ClientKeyExchange cke; CertificateVerify cv], [digestClientKeyExchange; digestCertificateVerify]]
          when (Some? pv && pv <> Some TLS_1p3 && (kex = Some Kex_DHE || kex = Some Kex_ECDHE)) ->
            server_ClientCCS hs cke digestClientKeyExchange (Some (c, Some (cv, digestCertificateVerify)))
*)
        | _, _, _ -> InError(AD_unexpected_message, "CCS received at wrong time")


let authorize s ch = Platform.Error.unexpected "authorize: not yet implemented"
