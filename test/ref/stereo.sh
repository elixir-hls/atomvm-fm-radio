#!/usr/bin/env bash
# FMRadio.pilot_pll |> stereo_tap (as the pipeline fuses it) |> stereo_out (the CPU clauses)
# against the stereo end of fm_stereo.v of usb-rtl-sdr-tang25k (stereo_pll, fir_dec x 2,
# stereo_out at blend 256): N MPX samples at 240 kS/s (L = 1 kHz, R = 1.7 kHz, the 38 kHz
# subcarrier, the 19 kHz pilot, noise), the {R, L} output frames and the pilot windows (2^14
# samples each: pilot_i / pilot_q / count) compared.
set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh
ROOT=$APP
W=$ROOT/build/ref/stereo
N=${N:-34000}
rm -rf "$W" && mkdir -p "$W/beams"
beams "$W/beams" "$ROOT/lib/fm_coeffs.ex" "$ROOT/lib/fm_radio.ex"
elixir -pa "$W/beams" -e '
  import Bitwise
  [n, dir] = System.argv(); n = String.to_integer(n)
  :rand.seed(:exsss, {9, 8, 7})
  pi2 = 2 * :math.pi()
  xs = for i <- 0..(n - 1) do
    t = i / 240_000
    l = :math.sin(pi2 * 1000 * t); r = 0.8 * :math.sin(pi2 * 1700 * t)
    mpx = 0.45 * (l + r) / 2 + 0.45 * (l - r) / 2 * :math.sin(pi2 * 38_000 * t) + 0.1 * :math.sin(pi2 * 19_000 * t)
    round(20480 * 2 * mpx) + :rand.uniform(400) - 200
  end
  File.write!(Path.join(dir, "in.hex"), Enum.map(xs, &(Integer.to_string(&1 &&& 0x3FFFF, 16) <> "\n")))
  {xm, sts} = Enum.map_reduce(xs, {FMRadio.pilot_pll(:init), []}, fn x, {st, ps} ->
    {y, st} = FMRadio.pilot_pll(x, st)
    {_, _, _, _, win, _, _, p} = st
    # a window ended: the pilot word and the window count
    ps = if (win &&& 0x3FFF) == 0, do: [{p, win >>> 14} | ps], else: ps
    {y, {st, ps}}
  end)
  {_, ps} = sts
  File.write!(Path.join(dir, "elixir_pilot.txt"), for({p, s} <- Enum.reverse(ps),
    do: "P #{String.pad_leading(Integer.to_string(p, 16), 8, "0")} #{String.pad_leading(Integer.to_string(s, 16), 2, "0")}\n"))
  {sd, _} = EHLS.run_cpu(&FMRadio.stereo_tap_w224_e5/2, xm, FMRadio.stereo_tap_w224_e5(:init))
  {ys, _} = Enum.map_reduce(sd, FMRadio.stereo_out(:init), &FMRadio.stereo_out(&1, &2, 256))
  File.write!(Path.join(dir, "elixir.txt"), Enum.map(ys, &(String.pad_leading(Integer.to_string(&1, 16), 8, "0") <> "\n")))
' "$N" "$W"
iverilog -g2012 -I "$RTL" -o "$W/sim" stereo_tb.v "$RTL/stereo_pll.v" \
    "$RTL/fir_dec.v" "$RTL/stereo_out.v"
(cd "$W" && vvp -n sim +N="$N") > "$W/vvp.txt"
grep -E "^[0-9a-f]{8}$" "$W/vvp.txt" | tr "a-f" "A-F" > "$W/verilog.txt"
grep "^P " "$W/vvp.txt" | tr "a-f" "A-F" | sed "s/^p /P /" > "$W/verilog_pilot.txt"
if ! cmp -s "$W/elixir_pilot.txt" "$W/verilog_pilot.txt" || [ ! -s "$W/verilog_pilot.txt" ]; then
    echo "stereo: pilot windows MISMATCH ($(wc -l < "$W/elixir_pilot.txt") / $(wc -l < "$W/verilog_pilot.txt"))"
    diff "$W/elixir_pilot.txt" "$W/verilog_pilot.txt" | head -6; exit 1
fi
if cmp -s "$W/elixir.txt" "$W/verilog.txt"; then
    echo "stereo: $N MPX samples, $(wc -l < "$W/verilog.txt") frames, $(wc -l < "$W/verilog_pilot.txt") pilot windows ($(tail -1 "$W/verilog_pilot.txt")), Elixir = Verilog"
else
    echo "stereo: MISMATCH ($(wc -l < "$W/elixir.txt") / $(wc -l < "$W/verilog.txt") frames)"
    diff "$W/elixir.txt" "$W/verilog.txt" | head -6; exit 1
fi
