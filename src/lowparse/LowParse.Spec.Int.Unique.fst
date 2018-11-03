module LowParse.Spec.Int.Unique

module Aux = LowParse.Spec.Int.Aux
module I = LowParse.Spec.Int
module Seq = FStar.Seq

module U8 = FStar.UInt8
module U16 = FStar.UInt16
module U32 = FStar.UInt32

open LowParse.Spec.Base

friend LowParse.Spec.Int

let le_refl (x y: int) : Lemma (requires (x <= y /\ y <= x)) (ensures (x == y)) = ()

let parse_u8_unique b
= if Seq.length b < 1
  then ()
  else begin
    I.parse_u8_spec b;
    Aux.parse_u8_spec b;
    let (Some (vI, consumedI)) = parse I.parse_u8 b in
    let (Some (vAux, consumedAux)) = parse Aux.parse_u8 b in
    le_refl consumedI 1;
    le_refl consumedAux 1;
    ()
  end

let serialize_u8_unique x
= Classical.forall_intro parse_u8_unique;
  let s : serializer I.parse_u8 = serialize_ext Aux.parse_u8 Aux.serialize_u8 I.parse_u8 in
  serializer_unique I.parse_u8 I.serialize_u8 s x

let parse_u16_unique b
= if Seq.length b < 2
  then ()
  else begin
    I.parse_u16_spec b;
    Aux.parse_u16_spec b;
    let (Some (vI, consumedI)) = parse I.parse_u16 b in
    let (Some (vAux, consumedAux)) = parse Aux.parse_u16 b in
    le_refl consumedI 2;
    le_refl consumedAux 2;
    ()
  end

let serialize_u16_unique x
= Classical.forall_intro parse_u16_unique;
  let s : serializer I.parse_u16 = serialize_ext Aux.parse_u16 Aux.serialize_u16 I.parse_u16 in
  serializer_unique I.parse_u16 I.serialize_u16 s x

let parse_u32_unique b
= if Seq.length b < 4
  then ()
  else begin
    I.parse_u32_spec b;
    Aux.parse_u32_spec b;
    let (Some (vI, consumedI)) = parse I.parse_u32 b in
    let (Some (vAux, consumedAux)) = parse Aux.parse_u32 b in
    le_refl consumedI 4;
    le_refl consumedAux 4;
    ()
  end

let serialize_u32_unique x
= Classical.forall_intro parse_u32_unique;
  let s : serializer I.parse_u32 = serialize_ext Aux.parse_u32 Aux.serialize_u32 I.parse_u32 in
  serializer_unique I.parse_u32 I.serialize_u32 s x
