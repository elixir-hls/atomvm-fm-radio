defmodule FMRadio do
  @moduledoc """
  A stereo FM radio described in Elixir. The RTL-SDR's IQ goes from the USB host through the
  demodulator to the I2S amplifiers inside the FPGA; Elixir sets the RTL-SDR up, starts /
  stops the instance `radio` and controls it while it runs (tuning, volume, level).
  """
  use EHLS, blocks: [EHLS.USBHost, {EHLS.I2S, wait: true}, EHLS.RPiDisplay35], peripherals: [:lcd]

  # Saturation, to 16 bits and to the 8 bits of offset binary
  defhls sat16(v :: s32) :: s16 do
    if v > 32767, do: 32767, else: if(v < -32768, do: -32768, else: v)
  end

  defhls offset8(v :: s32) :: u8 do
    if v > 127, do: 255, else: if(v < -128, do: 0, else: v + 128)
  end

  # The volume, gain / 256 on both channels (32 = -18 dB, at most 256): in the radio the
  # level gain_hw gives, set while playing with gain_hw(g)
  defhls volume(frame :: u32, gain :: u9) :: u32 do
    g = if gain > 256, do: 256, else: gain
    l = signed(frame &&& 0xFFFF, 16) * g >>> 8
    r = signed(frame >>> 16, 16) * g >>> 8
    (l &&& 0xFFFF) ||| (r &&& 0xFFFF) <<< 16
  end

  # The peak level of the audio (decaying by 2^-12 per sample, ~85 ms): the frames pass
  # through, the state is the level; placed as transform(0, &level/2, name: :level),
  # radio__pre(:state, :level) reads it while playing
  defhls level(frame :: u32, peak :: state(u16)) :: u32 do
    v = signed(frame &&& 0xFFFF, 16)
    a = if v < 0, do: -v, else: v
    decayed = peak - (peak >>> 12)
    {frame, if(a > decayed, do: a, else: decayed)}
  end

  # IQ bytes (I, Q, I, Q, ...; offset binary) -> one {I[15:8], Q[7:0]} word per sample, the
  # bytes as signed values (so that a zero-filled history means silence): every other byte
  # produces nothing (emit / skip)
  defhls iq_pair(b :: u8, st :: state({u8, u8})) :: emit(u16) do
    {have_i, i} = st
    if have_i == 1, do: {emit((i <<< 8 ||| b) ^^^ 0x8080), {0, 0}}, else: {skip(), {1, b}}
  end

  # The channel filter (31 taps, 120 kHz low-pass, symmetric) on I and Q: signed {I, Q} in,
  # offset binary out (rounded, saturated to 8 bits). Two symmetric pairs per loop iteration.
  # Bit-exact with chan_fir.v (test/ref/chan.sh).
  @chan FMCoeffs.chan()

  defhls chan_tap(w :: window(u16, 31)) :: u16 do
    {ai, aq} =
      for j <- 0..7, reduce: {0, 0} do
        acc ->
          Enum.reduce(0..1, acc, fn u, {ai, aq} ->
            k = 2 * j + u
            a = w[k]
            b = w[30 - k]
            c = table(@chan, k)
            # pairs (k, 30 - k); the centre tap (15) once
            {bi, bq} = if k == 15, do: {0, 0}, else: {signed(b >>> 8, 8), signed(b &&& 0xFF, 8)}
            {signed(ai + (signed(a >>> 8, 8) + bi) * c, 32), signed(aq + (signed(a &&& 0xFF, 8) + bq) * c, 32)}
          end)
      end

    yi = (ai + 32768) >>> 16
    yq = (aq + 32768) >>> 16
    (offset8(yi) <<< 8) ||| offset8(yq)
  end

  # The FM discriminator: the phase of each IQ sample by CORDIC (vectoring mode, 15
  # micro-rotations, 2^16 units per turn), then the difference to the previous phase (the
  # instantaneous frequency, 75 kHz = 5120 at 960 kS/s). Bit-exact with fm_disc.v
  # (test/ref/disc.sh).
  @atan [8192, 4836, 2555, 1297, 651, 326, 163, 81, 41, 20, 10, 5, 3, 1, 1, 0]

  defhls phase(iq :: u16) :: u16 do
    i = (iq >>> 8 &&& 0xFF) - 128
    q = (iq &&& 0xFF) - 128
    # into the right half plane (x >= 0)
    {x0, y0, z0} = if i < 0, do: {-(i <<< 9), -(q <<< 9), 0x8000}, else: {i <<< 9, q <<< 9, 0}

    # 8 loop iterations (for: time-multiplexed) of 2 micro-rotations each (Enum.reduce:
    # unrolled); the 16th rotates by atan 0, so z stays as after 15
    {_x, _y, z} =
      for j <- 0..7, reduce: {x0, y0, z0} do
        acc ->
          Enum.reduce(0..1, acc, fn u, {x, y, z} ->
            k = 2 * j + u
            if y >= 0 do
              {signed(x + (y >>> k), 21), signed(y - (x >>> k), 21), unsigned(z + table(@atan, k), 16)}
            else
              {signed(x - (y >>> k), 21), signed(y + (x >>> k), 21), unsigned(z - table(@atan, k), 16)}
            end
          end)
      end

    z
  end

  defhls phase_step(ph :: u16, prev :: state(u16)) :: s16 do
    {signed(ph - prev, 16), ph}
  end

  @fir1 FMCoeffs.fir1()
  @fir2 FMCoeffs.fir2()

  # The FIRs as pure functions of a window of the stream (w[0] the newest element);
  # window(n) |> every(k) |> map(&f/1) places each one as a time-multiplexed kernel (a ring
  # buffer in a memory, the taps in a loop). Bit-exact with fir_dec.v (test/ref/fir.sh).

  # d (s16, 960 kS/s) -> MPX x (s18): 32 taps, saturated (every 4th: 240 kS/s)
  defhls mpx_tap(w :: window(s16, 32)) :: s18 do
    v = Enum.sum(for k <- 0..31, do: w[k] * table(@fir1, k)) >>> 15
    if v > 131_071, do: 131_071, else: if(v < -131_072, do: -131_072, else: v)
  end

  # Stereo. The pilot PLL locks to the 19 kHz pilot and mixes the L-R channel down from 38
  # kHz: each MPX sample x becomes {x, m} (a tuple: one element, both in one clock). It also
  # measures the pilot: over each window of 2^14 samples (68 ms) the sums of its low-passed
  # in-phase and quadrature parts, at the window's end their means (saturated to 16 bits) in
  # `pilot` {Q[31:16], I[15:0]} and the window count in `win` (bits 21:14; bits 13:0 count
  # the samples) for FMStereo, which reads the state (named :pilot) with pilot/0. Bit-exact
  # with stereo_pll.v (test/ref/stereo.sh). The sums fit 32 bits: |i_lp|, |q_lp| < 2^17.
  @sin FMCoeffs.sin()

  defhls pilot_pll(x :: s18, st :: state({u32, s32, s24, s24, u32, s32, s32, u32})) :: {s18, s20} do
    {theta, integ, i_lp, q_lp, win, si, sq, pilot} = st
    a = theta >>> 22
    s1 = table(@sin, a)
    c1 = table(@sin, a + 256)
    s2 = table(@sin, theta >>> 21)
    # phase detector, L-R (the subcarrier sin(2 theta)), the pilot's I / Q (low-passed)
    pd = x * c1
    m = (x * s2) >>> 14
    i2 = signed(i_lp + (((x * s1) >>> 15) - i_lp + 128 >>> 8), 24)
    q2 = signed(q_lp + ((pd >>> 15) - q_lp + 128 >>> 8), 24)
    integ2 = signed(integ + (pd >>> 16), 32)
    theta2 = unsigned(theta + 0x14444444 + (pd >>> 6) + integ2, 32)
    # the window: the sums, at its last sample the means and the next window count
    si2 = signed(si + i2, 32)
    sq2 = signed(sq + q2, 32)
    win2 = unsigned(win + 1, 22)

    {si3, sq3, pilot2} =
      if (win &&& 0x3FFF) == 0x3FFF do
        mi = si2 >>> 14
        mq = sq2 >>> 14
        pi = sat16(mi)
        pq = sat16(mq)
        {0, 0, (pi &&& 0xFFFF) ||| (pq &&& 0xFFFF) <<< 16}
      else
        {si2, sq2, pilot}
      end

    {{x, m}, {theta2, integ2, i2, q2, win2, si3, sq3, pilot2}}
  end

  # {x, m} (240 kS/s) -> {L+R, L-R} (s22 each, 48 kHz): FIR2 (224 taps, every 5th) on both, in
  # one loop (two buffer reads and one coefficient per tap)
  defhls stereo_tap(w :: window({s18, s20}, 224)) :: {s22, s22} do
    {s, d} =
      for k <- 0..223, reduce: {0, 0} do
        {s, d} ->
          {x, m} = w[k]
          c = table(@fir2, k)
          {signed(s + x * c, 44), signed(d + m * c, 46)}
      end

    {s >>> 17, d >>> 17}
  end

  # {L+R, L-R} -> a frame {R, L} (16 bits each): DC block (rounded, 2^-10), blend (0 = mono
  # .. 256 = full stereo, a level after the state), matrix, 50 us de-emphasis per channel,
  # saturation. Bit-exact with stereo_out.v.
  defhls stereo_out(sd :: {s22, s22}, st :: state({s22, s32, s32}), blend :: u9) :: u32 do
    {s, d} = sd
    {dc, yl, yr} = st
    dc2 = signed(dc + ((s - dc + 512) >>> 10), 22)
    sp = signed(s - dc2, 22)
    dg = (d * blend) >>> 8
    l = signed(sp + dg, 24)
    r = signed(sp - dg, 24)
    yl2 = yl + (((l <<< 8) - yl) * 87 >>> 8)
    yr2 = yr + (((r <<< 8) - yr) * 87 >>> 8)
    vl = yl2 >>> 8
    vr = yr2 >>> 8
    ol = sat16(vl)
    orr = sat16(vr)
    {(ol &&& 0xFFFF) ||| (orr &&& 0xFFFF) <<< 16, {dc2, yl2, yr2}}
  end

  # The demodulator in four stream functions, each one compared with the Verilog it replaces
  # (test/ref/*.sh): on the CPU they take a list and give a list, from the initial states.

  # signed {I, Q} words -> the channel filter's output (offset binary)
  defhls channel(iq :: stream(u16)) :: stream(u16) do
    iq |> window(31) |> map(&chan_tap/1)
  end

  # {I, Q} (offset binary) -> the instantaneous frequency d (960 kS/s)
  defhls discriminator(iq :: stream(u16)) :: stream(s16) do
    iq |> map(&phase/1) |> transform(0, &phase_step/2)
  end

  # d -> MPX x (FIR /4: 240 kS/s)
  defhls mpx(d :: stream(s16)) :: stream(s18) do
    d |> window(32) |> every(4) |> map(&mpx_tap/1)
  end

  # MPX x -> {R, L} frames at 48 kHz: the pilot PLL (its state named :pilot), FIR /5 on
  # {L+R, L-R}, blend (0 = mono .. 256 = full stereo), matrix, de-emphasis
  defhls stereo(x :: stream(s18), blend :: u9) :: stream(u32) do
    x
    |> transform({0, 0, 0, 0, 0, 0, 0, 0}, &pilot_pll/2, name: :pilot)
    |> window(224) |> every(5) |> map(&stereo_tap/1)
    |> transform({0, 0, 0}, &stereo_out(&1, &2, blend))
  end

  # what the CPU changes while the radio plays: the volume and the stereo blend, levels the
  # radio's functions read at each sample
  definstance gain_hw(g :: u9), initial: 6 do
    g
  end

  definstance blend_hw(b :: u9), initial: 256 do
    b
  end

  # the level on the CPU (its C, in a driver process between radio__pre and radio__post, started
  # by play_at); the tuner cannot wait, so what the CPU does not take in time is dropped. No
  # circuit holds the level's state then, so nothing reads it.
  definstance radio, overflow: :drop, buffer: 512 do
    usb_bulk_in()
    |> transform({0, 0}, &iq_pair/2)
    |> channel()
    |> discriminator()
    |> mpx()
    |> stereo(blend_hw(:value))
    |> transform(0, &level/2, on: :cpu)
    |> map(&volume(&1, gain_hw(:value)))
    |> i2s_out()
  end

  # the station the radio starts on (82.5 MHz: NHK-FM in the Kanto region)
  @freq 82_500_000

  @doc """
  The radio with its touch screen panel (FMPanel): plays the station it starts on (`@freq`),
  tuning and volume from the panel; the stereo blend from the pilot (FMStereo). Runs until
  the board is reset.
  """
  def start do
    play_at(@freq)
    FMPanel.run(@freq)
  end

  # what i2s_out's FIFO did so far (EHLS.I2S registers)
  defp i2s do
    for r <- [:underruns, :repeats, :drops, :overruns, :level], do: {r, :hwstream.reg_read(:hw_kernels.reg(:hls_i2s, r))}
  end

  defp play_at(freq) do
    IO.puts("fm: open RTL-SDR at #{mhz(freq)} MHz: #{inspect(open(freq, 3))}")
    # the level stage on the CPU
    pid = radio(:cpu_start, batch: 8192)
    :erlang.put(:cpu_driver, pid)
    :ok = RTLSDR.start()
  end

  @doc """
  Plays the station it starts on (`@freq`) in stereo and works the controls while the
  radio runs: the level and the pilot every second, mono and back to stereo, a station
  1 MHz up and back (FMDemo, 32 s).
  """
  def demo do
    play_at(@freq)
    other = @freq + 1_000_000

    steps = [
      {0, "#{mhz(@freq)} MHz, stereo", fn -> :ok end},
      {8, "mono (blend 0)", fn -> blend_hw(0) end},
      {14, "stereo (blend 256)", fn -> blend_hw(256) end},
      {20, "tune #{mhz(other)} MHz", fn -> RTLSDR.tune(other) end},
      {26, "tune #{mhz(@freq)} MHz", fn -> RTLSDR.tune(@freq) end}
    ]

    play(0, 32, steps)
    {pkts, naks, errs} = RTLSDR.stats()
    IO.puts("fm: bulk packets #{pkts}, naks #{naks}, errors #{errs}")
    RTLSDR.stop()
    radio__pre(:stop)
    :ok
  end

  @doc """
  The pilot PLL's last window (2^14 MPX samples, 68 ms): {window count (8 bits), the pilot's
  in-phase level, its quadrature} (signed 16 bit each).
  """
  def pilot do
    {_theta, _integ, _i, _q, win, _si, _sq, p} = radio__pre(:state, :pilot)
    {win >>> 14, signed(p &&& 0xFFFF, 16), signed(p >>> 16, 16)}
  end

  # Hz -> "82.5"
  defp mhz(f) do
    d = div(f + 50_000, 100_000)
    "#{div(d, 10)}.#{rem(d, 10)}"
  end

  # a control transfer of the tuner's init fails now and then ({:error, {:init, n}}): again
  def open(freq, tries) do
    case RTLSDR.open(freq, 0) do
      {:error, _} = e when tries > 1 ->
        IO.puts("fm: open: #{inspect(e)}, again")
        open(freq, tries - 1)

      r ->
        r
    end
  end

  defp play(t, stop, _steps) when t >= stop, do: :ok

  defp play(t, stop, steps) do
    steps =
      case steps do
        [{^t, what, f} | rest] ->
          IO.puts("fm: #{t} s: #{what} -> #{inspect(f.())}")
          rest

        _ ->
          steps
      end

    :timer.sleep(1000)
    {seq, pilot_i, pilot_q} = pilot()
    IO.puts("fm: #{t + 1} s: pilot window #{seq}: #{pilot_i} / #{pilot_q}, cpu #{inspect(radio(:cpu_stats, :erlang.get(:cpu_driver)))}, i2s #{inspect(i2s())}")
    play(t + 1, stop, steps)
  end
end
