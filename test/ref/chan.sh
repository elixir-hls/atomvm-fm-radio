#!/usr/bin/env bash
# FMRadio.iq_pair's signed {I, Q} |> chan_tap (as the pipeline fuses it: window(31) |>
# map(&chan_tap/1), its CPU clause) against chan_fir.v of usb-rtl-sdr-tang25k: N {I, Q}
# samples (a strong rotating phasor, random words, the corners), the output words compared.
set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh
ROOT=$APP
W=$ROOT/build/ref/chan
N=${N:-4000}
rm -rf "$W" && mkdir -p "$W/beams"
beams "$W/beams" "$ROOT/lib/fm_coeffs.ex" "$ROOT/lib/fm_radio.ex"
elixir -pa "$W/beams" -e '
  import Bitwise
  [n, dir] = System.argv(); n = String.to_integer(n)
  :rand.seed(:exsss, {2, 7, 1})
  clip = fn v -> min(255, max(0, v)) end
  corners = for i <- [0, 1, 127, 128, 129, 255], q <- [0, 1, 127, 128, 129, 255], do: i <<< 8 ||| q
  ph = for t <- 0..(div(n, 2) - 1) do
    a = 127 - rem(t, 60)
    p = 2 * :math.pi() * 0.07 * t
    clip.(round(128 + a * :math.cos(p))) <<< 8 ||| clip.(round(128 + a * :math.sin(p)))
  end
  rnd = for _ <- 1..(n - length(corners) - length(ph)), do: :rand.uniform(65536) - 1
  xs = corners ++ ph ++ rnd
  File.write!(Path.join(dir, "in.hex"), Enum.map(xs, &(Integer.to_string(&1, 16) <> "\n")))
  # iq_pair hands on the bytes as signed values
  {ys, _} = EHLS.run_cpu(&FMRadio.chan_tap_w31_e1/2, Enum.map(xs, &bxor(&1, 0x8080)), FMRadio.chan_tap_w31_e1(:init))
  File.write!(Path.join(dir, "elixir.txt"), Enum.map(ys, &(String.pad_leading(Integer.to_string(&1, 16), 4, "0") <> "\n")))
' "$N" "$W"
iverilog -g2012 -I "$RTL" -o "$W/sim" chan_tb.v "$RTL/chan_fir.v"
(cd "$W" && vvp -n sim +N="$N" | grep -E "^[0-9a-f]{4}$" | tr "a-f" "A-F") > "$W/verilog.txt"
if cmp -s "$W/elixir.txt" "$W/verilog.txt"; then
    echo "chan: $N samples, Elixir = Verilog"
else
    echo "chan: MISMATCH"; diff "$W/elixir.txt" "$W/verilog.txt" | head; exit 1
fi
