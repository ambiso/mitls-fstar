module LowParseExample

let f (input: FStar.Bytes.bytes) : Tot (option (LowParseExample.Aux.t * FStar.UInt32.t)) =
  LowParseExample.Aux.parse32_t input

let g (input: FStar.Bytes.bytes) : Tot (option (LowParse.SLow.array LowParseExample.Aux.t 18 * FStar.UInt32.t)) =
  LowParseExample.Aux.parse32_t_array input
