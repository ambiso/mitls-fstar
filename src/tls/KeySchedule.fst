module KeySchedule
(*the top level key schedule module, it should not expose secrets to Handshake *)

(* the goal is to keep ephemerals like eph_s and eph_c as currently defined 
   in Handshake local *)

open FStar.Heap
open FStar.HyperHeap
open FStar.Seq
open FStar.SeqProperties
open FStar.Set  

open Platform.Bytes
open Platform.Error
open TLSError
open TLSConstants
open TLSExtensions
open TLSInfo
open Range
open HandshakeMessages
open StatefulLHAE
open HSCrypto

// KEF.fst/TLSPRF.fst for TLS 1.2
// CoreCrypto.hkdf for TLS 1.3

// does NOT subsumes the idealized module PRF.fst
// (we do not solve the circular dependency properly)


// LONG TERM GLOBAL SECRETS
// ******************************************

// For now, we stick to the style of miTLS 0.9
// to avoid a circular dependency between KEF and StatefulLHAE

// PRF (type pms) -> TLSInfo (type id) -> KEF (extract pms)
//                     \ StatefulLHAE (coerce id) / 

// Morally, we would like the following types to be
// abstract, but they must be concrete in order for the definition
// of id to appear in StatefulLHAE.

//abstract type ms = b:bytes{length b == 48}
// ADL: Unsound!!
type ms = bytes
type pms = PMS.pms 
// Requires meta-argument to show that pms is not used concretely in other modules

// type pms =
// | DH_PMS of CommonDH.dhpms // concrete
// | RSA_PMS of RSAKey.rsapms // concrete

// Index type for keys; it is morally abstract in
// StatefulLHAE (but has functions safeId: id->bool,
// algId: id -> aeAlg) and its concrete definition may
// be used to prove that StatefulLHAE.gen is not called
// twice with the same id
//type id = TLSInfo.id

// (in TLSInfo.fst)
// type id = {
//  msId   : msId;            // the index of the master secret used for key derivation
//  kdfAlg : kdfAlg_t;          // the KDF algorithm used for key derivation
//  pv     : protocolVersion; // should be part of aeAlg
//  aeAlg  : aeAlg;           // the authenticated-encryption algorithms
//  csrConn: csRands;         // the client-server random of the connection
//  ext: negotiatedExtensions;// the extensions negotiated for the current session
//  writer : role             // the role of the writer
//  }

// abstract type resumption_secret = b:bytes{}
//type resumption_secret = b:bytes{}

//type exporter_secret = b:bytes{}

// abstract type pre_share_key = b:bytes{}
//type pre_shared_key = PSK.psk

// ******************************************
// ADL: I don't think these can be module-wide variables
// let's encapsulate in state
//val cert_keys: ref RSAKey.RSA_PK; 
//val ticket_key: ref bytes // TODO
// ******************************************

(**
 ** ADL: commenting out this attempt to share common arguments
 ** (e.g. PMS, DH values) accross similar states (client/server, 1.2/1.3...)
 ** Below is the more standard encoding of arguments as part of
 ** the key exchange internal state, at the cost of heavy redundancy
 ** and a state space blowup.
 **
type client_schedule_state =
| C_KXS_INIT //initial state, state to get back to for renegotiation
| C_KXS_NEGO //process server finished and go to one of following states, corresponds to C_HelloSent 
| C_KXS12_RESUME //separate states for different handshake modes, these correspond to C_HelloReceived
| C_KXS12_DHE
| C_KXS12_RSA
| C_KXS12_FINISH // keys are derived, only finished message computation, corresponds to C_CCSReceived
//TLS13
| C_KXS13_NEGO
| C_KXS13_PSK


type server_schedule_state =
| S_KXS_INIT
| S_KXS_NEGO //process server finished
| S_KXS12_RESUME //separate states for different handshake modes
| S_KXS12_DHE
| S_KXS12_RSA
| S_KXS12_RSA

type schedule_state =
| KXS_Client of client_schedule_state
| KXS_Server of server_schedule_state

type ks =
  | KS:
    #r:rid ->
    cfg:config ->
    r:role ->
    pv: rref r ProtocolVersion ->
    alpha: rref r alpha ->
    dh_secret: rref r (option bytes) ->
    our_share: rref r (option CommonDH.share) ->
    peer_share: rref r (option CommonDH.share) ->
    dh_pms: rref r (option PMS.dhpms) ->
    msId: rref r (option TLSInfo.msId) ->
    ms: rref r (option bytes) ->
    pmsId: rref r (option TLSInfo.pmsId) ->
    state: rref r schedule_state ->
    ks

**)

// Agility parameters, extend as needed
// may be moved to TLSInfo for joint idealization with Handshake
type ks_alpha = pv:protocolVersion * cs:cipherSuite * nego:negotiatedExtensions

// Internal KS state, now with ad-hoc parameters
type ks_state =
| KS_C_Init
| KS_C_12_Resume_CH: cr:random -> si:sessionInfo -> msId:TLSInfo.msId -> ms:ms -> ks_state
| KS_C_12_Full_CH: cr:random -> ks_state
| KS_C_12_wait_MS: csr:csRands -> alpha:ks_alpha -> id:TLSInfo.pmsId -> pms:bytes -> ks_state
| KS_12_has_MS: r:role -> csr:csRands -> alpha:ks_alpha -> id:TLSInfo.msId -> ms:ms -> ks_state
| KS_S_Init
| KS_Done

type ks =
| KS: #region:rid -> cfg:config -> state:rref region ks_state -> ks

// Create a fresh key schedule instance
// We expect this to be called when the Handshake instance is created
val create: #rid:rid -> config -> role -> ST ks
  (requires fun h -> rid<>root)
  (ensures fun h0 r h1 ->
    let KS #ks_region cfg state = r in
    fresh_region ks_region h0 h1
    /\ extends ks_region rid)

let create #rid cfg r =
  ST.recall_region rid;
  let ks_region = new_region rid in 
  let istate = match r with | Client -> KS_C_Init | Server -> KS_S_Init in
  KS #ks_region cfg (ralloc ks_region istate)

// Called before sending client hello
// (the external style of resumption may become internal to protect ms abstraction)
val ks_client_init_12: ks:ks -> ST (random * option sessionInfo)
  (requires fun h0 -> sel h0 (KS.state ks) = KS_C_Init)
  (ensures fun h0 r h1 -> True)

// TODO resumption support
let ks_client_init_12 ks =
  let cr = Nonce.mkHelloRandom () in
  let osi, ns = None, (KS_C_12_Full_CH cr) in
//    match cfg.resuming with
//    | None -> None, (KS_C_12_Full_CH cr)
//    | Some shard ->
//      (match DB.lookup shard with TODO
//      | Some (si, msId, ms) -> (Some si), (KS_C_12_Resume_CH cr si msId ms)
//      | None -> None, (KS_C_12_Full_CH cr)) in
  (KS.state ks) := ns;
  cr, osi

// Called after receiving server hello; server accepts resumption proposal
// This function only checks the agility paramaters compared to the resumed sessionInfo
// and returns to the handshake whether the resumption is permissible
val ks_client_12_resume: ks:ks -> random -> alpha:ks_alpha -> ST unit
  (requires fun h0 ->
    let kss = sel h0 (KS.state ks) in
    let (pv, cs, nego) = alpha in
    is_KS_C_12_Resume_CH kss
    /\ (let si = KS_C_12_Resume_CH.si kss in
      si.protocol_version = pv /\ si.cipher_suite = cs
      /\ (si.extensions.ne_extended_ms <==> nego.ne_extended_ms)))
  (ensures fun h0 cvd h1 -> True)

let ks_client_12_resume ks sr alpha =
  let KS #region cfg st = ks in
  let KS_C_12_Resume_CH cr si msId ms = !st in
  let csr = cr @| sr in
  st := KS_12_has_MS Client csr alpha msId ms

// The two functions below are similar but we decide not to factor them because:
//   1. they use different arguemtns
//   2. they use different return types
//   3. they are called at different locations

// Called by Hanshake when DH key echange is negotiated
val ks_client_12_full_dh: ks:ks -> random -> ks_alpha -> CommonDH.params -> peer_share:CommonDH.key -> ST CommonDH.key
  (requires fun h0 ->
    let st = sel h0 (KS.state ks) in
    is_KS_C_12_Full_CH st \/ is_KS_C_12_Resume_CH st)
  (ensures fun h0 r h1 -> True)

let ks_client_12_full_dh ks sr alpha dhp peer_share =
  let KS #region cfg st = ks in
  let (pv, cs, nego) = alpha in
  let cr = match !st with
    | KS_C_12_Full_CH cr -> cr
    | KS_C_12_Resume_CH cr _ _ _ -> cr in
  let csr = cr @| sr in
  let our_share, pmsb = CommonDH.dh_responder peer_share in
  let dhpms = PMS.DHPMS(dhp, our_share, peer_share, PMS.ConcreteDHPMS(pmsb)) in
  let dhpmsId = TLSInfo.SomePmsId(dhpms) in
  let ns = 
    if nego.ne_extended_ms then
      KS_C_12_wait_MS csr alpha dhpmsId pmsb
    else
      let kef = kefAlg pv cs false in
      let ms = TLSPRF.extract kef pmsb csr 48 in
//      let ms = TLSPRF.prf (pv,cs) pmsb (utf8 "master secret") csr 48 in
      let msId = StandardMS dhpmsId csr kef in
      KS_12_has_MS Client csr alpha msId ms in
  st := ns; our_share

// Called by Handshake after server hello when a full RSA key exchange is negotiated
val ks_client_12_full_rsa: ks:ks -> random -> ks_alpha -> RSAKey.pk -> ST bytes
  (requires fun h0 ->
    let st = sel h0 (KS.state ks) in
    is_KS_C_12_Full_CH st \/ is_KS_C_12_Resume_CH st)
  (ensures fun h0 r h1 -> True)

let ks_client_12_full_rsa ks sr alpha pk =
  let KS #region cfg st = ks in
  let (pv, cs, nego) = alpha in
  let cr = match !st with
    | KS_C_12_Full_CH cr -> cr
    | KS_C_12_Resume_CH cr _ _ _ -> cr in
  let csr = cr @| sr in
  let rsapms = PMS.genRSA pk pv in
  let pmsb = PMS.leakRSA pk pv rsapms in
  let encrypted = CoreCrypto.rsa_encrypt (RSAKey.repr_of_rsapkey pk) CoreCrypto.Pad_PKCS1 pmsb in
  let rsapmsId = TLSInfo.SomePmsId(PMS.RSAPMS(pk, pv, rsapms)) in
  let ns =
    if nego.ne_extended_ms then
      KS_C_12_wait_MS csr alpha rsapmsId pmsb
    else
      let kef = kefAlg pv cs false in
      let ms = TLSPRF.extract kef pmsb csr 48 in
      let msId = StandardMS rsapmsId csr kef in
      KS_12_has_MS Client csr alpha msId ms in
  st := ns; encrypted

// This MUST be called by handshake as soon as session hash is available if EMS was negotiated
val ks_client_12_set_session_hash: ks:ks -> bytes -> ST unit
  (requires fun h0 ->
    let st = sel h0 (KS.state ks) in
    is_KS_C_12_wait_MS st)
  (ensures fun h0 r h1 -> True)

let ks_client_12_set_session_hash ks session_hash =
  let KS #region cfg st = ks in
  let KS_C_12_wait_MS csr alpha pmsid pms = !st in
  let (pv, cs, nego) = alpha in
  let kef = kefAlg pv cs true in
  let ms = TLSPRF.prf_hashed (pv,cs) pms (utf8 "extended master secret") session_hash 48 in
  let msId = ExtendedMS pmsid session_hash kef in
  st := KS_12_has_MS Client csr alpha msId ms

// *********************************************************************************
//  All functions below assume that the MS is already computed (and thus they are
//  shared accross role, key exchange, handshake mode...)
// *********************************************************************************

val ks_12_finished: ks:ks -> bytes -> ST (vd:bytes * wk:bytes * wiv:bytes * rk:bytes * riv:bytes)
  (requires fun h0 ->
    let st = sel h0 (KS.state ks) in
    is_KS_12_has_MS st)
  (ensures fun h0 r h1 -> True)

let ks_12_finished ks log =
  let KS #region cfg st = ks in
  let KS_12_has_MS role csr alpha msId ms = !st in
  let cr, sr = split csr 32 in
  let (pv, cs, nego) = alpha in
  let vd = TLSPRF.verifyData (pv,cs) ms role log in
  let ae_id = {
    msId = msId;
    kdfAlg = kdfAlg pv cs;
    pv = pv;
    aeAlg = get_aeAlg cs;
    csrConn = csr;
    ext = nego;
    writer = role
  } in
  let expand = TLSPRF.kdf ae_id.kdfAlg ms (sr @| cr) 40 in
  let k1, expand = split expand 16 in
  let k2, expand = split expand 16 in
  let iv1, iv2 = split expand 4 in
  let wk, wiv, rk, riv =
    match role with
    | Client -> k1, iv1, k2, iv2
    | Server -> k2, iv2, k1, iv1 in
  st := KS_Done; // Destroy MS
  (vd, wk, wiv, rk, riv)


(* MK: older experiment with Antoine

val kx_init: #region:rid -> role:role -> pv:pv -> g:dh_group -> gx:option dh_pub{gx=None <==> (pv=TLS_1p3 /\ role = Client) \/ (role = Server /\ pv<>TLS_1p3)} -> ST dh_pub

val kx_set_peer: #region:rid -> gx:dh_pub -> ST unit (requires (sel !state_map rid).kx_state = KX .... ) 

// New handshake interface:
//val dh_init_server_exchange: #region:rid -> g:dh_group -> ST (gy: dh_key)
//val dh_client_exchange: #region:rid -> g:

// TLS 1.2 + 1.3
// state-aware
val dh_next_key: #region:rid -> log:bytes -> 

*)

// OLD 

(*
assume val dh_commit
assume val dh_server_verify
assume val dh_client_verify

(* For TLS12 and below only the server keeps state concretely *)
type ks_12S =
    | KS_12S: #region: rid -> x: rref region (KEX_S_PRIV) -> ks_12S
    
  
(* For TLS13 both client and server keep state concretely *)    
type ks_13C
    | KS_13C: #region: rid -> x: rref region HSCrypto.dh_key -> ks_13C
    ...


(* for idealization we need a global log *)
type state =
  | Init
  | Committed of ProtocolVersion * aeAlg * negotiatedExtensions
  | Derived: a:id -> b:id -> derived a b -> state
  
type kdentry = CsRands * state 
let kdlog : ref<list<kdentry>> = ref [] 
  
(* TLS 1.2 *)
val dh_init_12S: #region:rid -> g:dh_group -> ST (state:ks_12S * gx:dh_key)

let dh_init_12S r g =
  let x = dh_keygen g
  let xref = ralloc r 0 in
  let xref := KEX_S_PRIV_DHE x
  KS_12S r xref, x.public
  
assume val derive_12C: gx:dh_key -> ... -> ST(gy:dh_key * (both i) * ms)

let derive12C gx cr sr log rd wr i = 
  let (y, gxy) = dh_shared_secret2 gx 
  y.public, derive_keys gxy cr sr log rd wr i


assume val derive_12S: state:ks_12S -> gy:dh_key -> ... -> ST ((both i) * ms)

let derive_12S state gy cr sr log rd wr i =
  let (KS_12S xref) = state 
  derive_keys (dh_shared_secret1 !xref) cr sr log rd wr i

(* TLS 1.3 *)

val dh_init_13S: #region:rid g:dh_group -> ST (state:ks_13S * gs:dh_key) //s
val dh_init_13C: #region:rid g:dh_group -> ST (state:ks_13C * gx:dh_key) //x

assume val derive_13S_1: state:ks_13S -> gx:dh_key -> ... -> ST(gy:dh_key * (both i)) //handshake
assume val derive_13S_2: state:ks_13S -> ... -> ST(cf:ms * sf:ms) //finished
assume val derive_13S_3: state:ks_13S -> ... -> ST(both i) //traffic

assume val derive_13C_1: state:ks_13C -> gy:dh_key -> ... -> ST(both i) //handshake
assume val derive_13C_2: state:ks_13C -> gs:dh_key -> ... -> ST(cf:ms * sf:ms) //finished
assume val derive_13C_3: state:ks_13C -> ... -> ST(both i) //traffic
*)

