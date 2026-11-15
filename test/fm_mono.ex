defmodule FMMono do
  @moduledoc """
  The mono end of the FM radio before stereo (P3): L+R only, for the reference tests
  (test/ref/fir.sh, mono_out.sh): stream functions, run on the CPU. Not built into the SoC.
  """
  use EHLS

  @fir2 FMCoeffs.fir2()

  # MPX x (s18, 240 kS/s) -> L+R (s22): 224 taps (every 5th: 48 kHz)
  defhls audio_tap(w :: window(s18, 224)) :: s22 do
    Enum.sum(for k <- 0..223, do: w[k] * table(@fir2, k)) >>> 17
  end

  # L+R at 48 kHz (s22 in a word) -> a mono frame: DC block (rounded, 2^-10), 50 us
  # de-emphasis (y += ((v << 8) - y) * 87 >> 8), saturation to 16 bits. Bit-exact with
  # stereo_out.v at blend 0 (test/ref/mono_out.sh).
  defhls deemphasis(s :: s32, st :: {s32, s32}) :: {u32, {s32, s32}} do
    {dc, y} = st
    dc2 = dc + ((s - dc + 512) >>> 10)
    sp = s - dc2
    y2 = y + (((sp <<< 8) - y) * 87 >>> 8)
    v = y2 >>> 8
    o = if v > 32767, do: 32767, else: if(v < -32768, do: -32768, else: v)
    {(o &&& 0xFFFF) ||| (o &&& 0xFFFF) <<< 16, {dc2, y2}}
  end

  # MPX x -> L+R at 48 kHz (FIR /5)
  defhls audio(x :: stream(s18)) :: stream(s22) do
    x |> window(224) |> every(5) |> map(&audio_tap/1)
  end

  defhls mono(x :: stream(s18)) :: stream(u32) do
    x |> audio() |> transform({0, 0}, &deemphasis/2)
  end
end
