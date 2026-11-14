defmodule FMPanel do
  @moduledoc """
  The touch screen front panel of the FM radio on the 3.5inch RPi Display (480 x 320, the
  `lcd` NIFs), laid out as usb-rtl-sdr-tang25k's ui.c:

      82.5 MHz                     STEREO
                                   NHK-FM      station name when the frequency is in the list
      VOL 4   LVL -18dB   SN 52dB         pilot / noise (FMStereo)
      [ -1.0 ] [ -0.1 ] [ +0.1 ] [ +1.0 ]      tuning, MHz (76.0 .. 95.0, wraps around)
      [ VOL- ] [ VOL+ ] [ <ST  ] [  ST> ]      volume, previous / next station of the Kanto list

  One process, `run/1`, owns the radio's controls: every 50 ms it reads the touch panel,
  acts on a press (tuning and volume repeat while held), reads the pilot PLL's window (a new
  one every 68 ms: FMStereo sets the stereo blend from it; STEREO while the blend is at
  least half) and redraws only what changed; once a second it reads the level and redraws
  the status line (the LCD's SPI lines sit next to the radio, so the screen stays
  quiet otherwise). Without a panel it plays on (touch reads as not pressed).
  """
  import Bitwise

  @tick_ms 50
  @repeat_first_ms 500
  @repeat_ms 150
  @freq_min 76_000_000
  @freq_max 95_000_000

  # RGB565
  @bg 0x0000
  @fg 0xFFFF
  @dim (110 >>> 3 <<< 11) ||| (110 >>> 2 <<< 5) ||| (110 >>> 3)
  @accent (80 >>> 3 <<< 11) ||| (220 >>> 2 <<< 5) ||| (120 >>> 3)
  @btn (40 >>> 3 <<< 11) ||| (60 >>> 2 <<< 5) ||| (100 >>> 3)
  @btn_down (90 >>> 3 <<< 11) ||| (140 >>> 2 <<< 5) ||| (220 >>> 3)

  @lcd_w 480
  @labels ["-1.0", "-0.1", "+0.1", "+1.0", "VOL-", "VOL+", "<ST", "ST>"]
  @actions [{:tune, -1_000_000}, {:tune, -100_000}, {:tune, 100_000}, {:tune, 1_000_000},
            {:vol, -1}, {:vol, 1}, {:station, -1}, {:station, 1}]

  # Kanto FM stations, ascending (ASCII names for the font)
  @stations [{78_000_000, "bayfm"}, {79_500_000, "NACK5"}, {80_000_000, "TOKYO FM"},
             {81_300_000, "J-WAVE"}, {82_500_000, "NHK-FM"}, {84_700_000, "FM YOKOHAMA"},
             {89_700_000, "InterFM897"}, {90_500_000, "TBS Radio"}, {91_600_000, "Bunka Hoso"},
             {92_400_000, "Radio Nippon"}, {93_000_000, "Nippon Hoso"}]

  # volume 0 (mute) .. 15 in 3 dB steps -> the volume kernel's gain (256 = 0 dB)
  @gains {0, 2, 3, 4, 6, 8, 11, 16, 23, 32, 45, 64, 91, 128, 181, 256}
  @default_vol 4

  @doc "Runs the panel for the radio playing at `freq` (never returns)."
  def run(freq) do
    :lcd.init()
    buttons = layout()
    for {b, i} <- :lists.zip(buttons, :lists.seq(0, 7)), do: draw_button(b, i, false)
    FMRadio.gain_hw(elem(@gains, @default_vol))

    st = %{freq: freq, vol: @default_vol, stereo: false, blend: FMStereo.new(), seq: nil,
           buttons: buttons, pressed: nil, repeat: 0, age: 1000, level: nil, sn: nil,
           status_due: false, pkts: nil, errs: nil, shown: %{}}

    loop(redraw(st))
  end

  # the 8 buttons: {x, y, w, h}, two rows of four
  defp layout do
    {bw, bh, gap} = {114, 78, 8}
    x0 = div(@lcd_w - 4 * bw - 3 * gap, 2)
    for i <- 0..7, do: {x0 + rem(i, 4) * (bw + gap), 148 + div(i, 4) * (bh + gap), bw, bh}
  end

  defp loop(st) do
    :timer.sleep(@tick_ms)
    st = st |> touch() |> pilot() |> status()
    loop(redraw(st))
  end

  # -- touch --

  defp touch(st) do
    b =
      case :lcd.touch() do
        {x, y} -> hit(st.buttons, x, y, 0)
        false -> nil
      end

    cond do
      b != st.pressed ->
        if st.pressed != nil, do: draw_button(Enum.at(st.buttons, st.pressed), st.pressed, false)
        st = %{st | pressed: b, repeat: @repeat_first_ms}
        if b != nil do
          # act first, then draw the button: drawn just before a tune, the tuner's PLL lock
          # bit read false every time
          st = act(st, Enum.at(@actions, b))
          draw_button(Enum.at(st.buttons, b), b, true)
          st
        else
          st
        end

      # tuning and volume repeat while held (not the station list)
      b != nil and b < 6 ->
        r = st.repeat - @tick_ms
        if r <= 0, do: act(%{st | repeat: @repeat_ms}, Enum.at(@actions, b)), else: %{st | repeat: r}

      true ->
        st
    end
  end

  defp hit([], _x, _y, _i), do: nil
  defp hit([{bx, by, bw, bh} | _], x, y, i) when x >= bx and x < bx + bw and y >= by and y < by + bh, do: i
  defp hit([_ | rest], x, y, i), do: hit(rest, x, y, i + 1)

  defp act(st, {:tune, step}) do
    f = st.freq + step
    f = if f < @freq_min, do: @freq_max, else: if(f > @freq_max, do: @freq_min, else: f)
    tune(st, f)
  end

  defp act(st, {:vol, step}) do
    v = min(15, max(0, st.vol + step))
    FMRadio.gain_hw(elem(@gains, v))
    %{st | vol: v}
  end

  defp act(st, {:station, dir}) do
    d = div(st.freq, 100_000)
    hzs = for {hz, _} <- @stations, do: hz

    f =
      if dir > 0 do
        case for(hz <- hzs, div(hz, 100_000) > d, do: hz) do
          [] -> hd(hzs)
          [h | _] -> h
        end
      else
        case for(hz <- :lists.reverse(hzs), div(hz, 100_000) < d, do: hz) do
          [] -> :lists.last(hzs)
          [h | _] -> h
        end
      end

    tune(st, f)
  end

  defp tune(st, f) do
    locked = RTLSDR.tune(f)
    IO.puts("panel: tune #{mhz(f)} MHz -> #{locked}")
    # the blend follows the new station's pilot window by window (FMStereo)
    %{st | freq: f, age: 0}
  end

  # -- stereo: each new pilot window (68 ms) moves the blend --

  defp pilot(st) do
    {seq, pi, pq} = FMRadio.pilot()

    cond do
      st.seq == nil ->
        %{st | seq: seq}

      seq == st.seq ->
        st

      true ->
        b = FMStereo.window(st.blend, pi, pq)
        if b.blend != st.blend.blend, do: FMRadio.blend_hw(b.blend)
        stereo = b.blend >= 128

        if stereo != st.stereo,
          do: IO.puts("panel: #{if stereo, do: "STEREO", else: "MONO"} (pilot #{pi}, SN #{div(b.db, 10)} dB)")

        %{st | seq: seq, blend: b, stereo: stereo}
    end
  end

  # -- status (once a second) --

  defp status(st) do
    age = st.age + @tick_ms

    if age < 1000 do
      %{st | age: age}
    else
      %{st | age: 0, level: 0, sn: st.blend.db, status_due: true}
      |> watchdog()
    end
  end

  # The IQ stream stopped (the bulk IN packet count stood still for a second): log it with
  # the USB host's state and open the RTL-SDR again at the same frequency (bus reset, PHY
  # reset if it does not answer, enumeration, tuner init; ~1 s), as usb-rtl-sdr-tang25k
  # did after 0.5 s without IQ. (It happened every minute or so while the PHY's RESET wire
  # touched the I2S data line.)
  defp watchdog(st) do
    {pkts, naks, errs} = RTLSDR.stats()

    if errs != st.errs and st.errs != nil,
      do: IO.puts("panel: USB errors +#{errs - st.errs} (#{errs})")
    st = %{st | errs: errs}

    if pkts != st.pkts do
      %{st | pkts: pkts}
    else
      # still NAKing (the device has no data) or no IN tokens at all (the host side)?
      :timer.sleep(100)
      {_, naks2, _} = RTLSDR.stats()
      IO.puts("panel: IQ stopped at #{mhz(st.freq)} MHz (packets #{pkts}, errors #{errs}, " <>
                "NAKs +#{naks2 - naks} in 100 ms): open again")
      IO.puts("panel:   usb debug #{inspect(RTLSDR.debug())} then #{inspect(RTLSDR.debug())}")
      RTLSDR.stop()
      FMRadio.radio__pre(:stop)
      r = FMRadio.open(st.freq, 3)
      FMRadio.radio__pre(:start)
      RTLSDR.start()
      IO.puts("panel:   open #{inspect(r)}")
      %{st | pkts: nil}
    end
  end

  # -- drawing: each field when its value differs from what is on the screen --

  defp redraw(st) do
    shown = st.shown
    shown = field(shown, :freq, div(st.freq, 100_000), fn -> draw_freq(st.freq) end)
    shown = field(shown, :stereo, st.stereo, fn -> draw_stereo(st.stereo) end)

    line = status_line(st)
    shown =
      if Map.get(shown, :vol) != st.vol or st.status_due do
        field(shown, :line, line, fn -> :lcd.text(16, 100, line, @fg, @bg, 1) end)
      else
        shown
      end

    %{st | shown: Map.put(shown, :vol, st.vol), status_due: false}
  end

  defp field(shown, key, value, draw) do
    if Map.get(shown, key) == value do
      shown
    else
      draw.()
      Map.put(shown, key, value)
    end
  end

  defp draw_freq(f) do
    x = :lcd.text(16, 16, pad(mhz(f), 5), @fg, @bg, 2)
    :lcd.text(x + 8, 48, "MHz", @dim, @bg, 1)
    name = for({hz, n} <- @stations, div(hz, 100_000) == div(f, 100_000), do: n)
    # right-aligned, 12 characters (clears the old name)
    :lcd.text(@lcd_w - 16 - 12 * 16, 56, pad(Enum.join(name), 12), @accent, @bg, 1)
  end

  defp draw_stereo(true), do: :lcd.text(@lcd_w - 16 - 6 * 16, 16, "STEREO", @accent, @bg, 1)
  defp draw_stereo(false), do: :lcd.text(@lcd_w - 16 - 6 * 16, 16, "  MONO", @dim, @bg, 1)

  defp status_line(st) do
    lvl =
      case st.level do
        nil -> "  --"
        0 -> " -99"
        l -> pad("#{max(-99, round(20 * :math.log10(l / 32768)))}", 4)
      end

    # pilot / noise in dB (as usb-rtl-sdr-tang25k's ui.c: -9 .. 99)
    sn = if st.sn in [nil, -999], do: "--", else: "#{st.sn |> div(10) |> max(-9) |> min(99)}"
    # 30 characters: the whole width, so a shorter line clears the old one
    rpad("VOL #{rpad("#{st.vol}", 2)}  LVL #{lvl}dB  SN #{sn}dB", 30)
  end

  defp draw_button({x, y, w, h}, i, down) do
    bg = if down, do: @btn_down, else: @btn
    label = Enum.at(@labels, i)
    :lcd.fill(x, y, w, h, bg)
    :lcd.text(x + div(w - byte_size(label) * 16, 2), y + div(h - 32, 2), label, @fg, bg, 1)
  end

  defp mhz(f) do
    d = div(f + 50_000, 100_000)
    "#{div(d, 10)}.#{rem(d, 10)}"
  end

  defp pad(s, n), do: :erlang.iolist_to_binary([:lists.duplicate(max(0, n - byte_size(s)), ?\s), s])
  defp rpad(s, n), do: :erlang.iolist_to_binary([s, :lists.duplicate(max(0, n - byte_size(s)), ?\s)])
end
