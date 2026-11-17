defmodule FMStereo do
  @moduledoc """
  The stereo blend from the pilot, as usb-rtl-sdr-tang25k's radio.c: per window of 2^14 MPX
  samples (68 ms) the pilot PLL gives the pilot's in-phase level (pilot_i) and its
  quadrature (pilot_q). Locked, pilot_q averages to zero and its spread over windows is the
  noise next to 19 kHz (program content is >= 4 kHz away). The metric
  mean(pilot_i)^2 / var(pilot_q) over the last 32 windows (2.2 s) maps to the L-R weight:
  >= 44 dB full stereo, <= 36 dB mono, linear in between (a strong station at 42..46 dB is
  stereo; by ear, at 54 dB stereo is no noisier than mono). The weight rises by at most 16 per window and falls by at most 8
  (slowly, so a short dip does not drop to mono), or by 16 when the pilot is gone
  (pilot_i < 300: a mono broadcast).

      st = FMStereo.new()
      st = FMStereo.window(st, pilot_i, pilot_q)   # once per window
      st.blend                                     # 0 (mono) .. 256 (full stereo)
      st.db                                        # the metric, tenths of dB (-999: none)
  """
  import Bitwise

  @n 32
  @full_db 440
  @mono_db 360
  @up 16
  @down 8
  @pilot_min 300

  defstruct blend: 0, db: -999, pilot: 0, pi: [], pq: []

  def new, do: %FMStereo{}

  @doc "One window's pilot_i / pilot_q (signed 16 bit): the next blend and metric."
  def window(st, pi, pq) do
    pis = take([pi | st.pi], @n)
    pqs = take([pq | st.pq], @n)
    st = %{st | pilot: pi, pi: pis, pq: pqs}

    if length(pis) < @n do
      st
    else
      s = sum(pqs, 0)
      s2 = sum_sq(pqs, 0)
      pm = div(sum(pis, 0), @n)
      # 4 * N^2 * var = 4 * (N * s2 - s^2); metric = pm^2 / (var + 1/4)
      v4 = 4 * (@n * s2 - s * s)
      db = if pm > 0, do: db_x10(pm * pm * 4 * @n * @n, v4 + @n * @n), else: -999

      target =
        if pi < @pilot_min,
          do: 0,
          else: clamp(div((db - @mono_db) * 256, @full_db - @mono_db), 0, 256)

      down = if pi < @pilot_min, do: @up, else: @down
      %{st | db: db, blend: st.blend + clamp(target - st.blend, -down, @up)}
    end
  end

  @doc "10 * log10(num / den) in tenths of dB; log2 with a linear fraction (error < 0.3 dB)."
  def db_x10(num, den) when den == 0 or num == 0, do: if(num != 0, do: 999, else: -999)

  def db_x10(num, den) do
    case shrink(num, den) do
      :inf ->
        999

      {num, den} ->
        q = div(num <<< 16, den)

        if q == 0 do
          -999
        else
          n = log2(q, 0)
          l2 = n * 256 + ((q <<< 8 >>> n) - 256) - 16 * 256
          # div truncates towards zero, as C's division in radio.c
          div(div(l2 * 30103, 256), 1000)
        end
    end
  end

  # num below 2^46 (num << 16 stays in 64 bits), den shifted along; with den >= 1024 (the
  # variance term) q << 8 stays below 2^61
  defp shrink(num, den) when num >= 1 <<< 46 do
    den = den >>> 1
    if den == 0, do: :inf, else: shrink(num >>> 1, den)
  end

  defp shrink(num, den), do: {num, den}

  defp log2(q, n), do: if(q >>> n > 1, do: log2(q, n + 1), else: n)

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  # plain recursion: AtomVM's exavmlib has no Enum.take/2
  defp take(_, 0), do: []
  defp take([], _), do: []
  defp take([x | xs], n), do: [x | take(xs, n - 1)]

  defp sum([], a), do: a
  defp sum([x | xs], a), do: sum(xs, a + x)

  defp sum_sq([], a), do: a
  defp sum_sq([x | xs], a), do: sum_sq(xs, a + x * x)
end
