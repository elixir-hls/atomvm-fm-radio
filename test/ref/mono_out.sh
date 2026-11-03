#!/usr/bin/env bash
# FMMono.deemphasis (Elixir, the CPU clause) against stereo_out.v of usb-rtl-sdr-tang25k
# (blend 0): the same N samples (a slow sine at near full scale plus noise), outputs compared.
set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh
ROOT=$APP
W=$ROOT/build/ref/mono_out
N=${N:-3000}
rm -rf "$W" && mkdir -p "$W/beams"
beams "$W/beams" "$ROOT/lib/fm_coeffs.ex" "$ROOT/test/fm_mono.ex"
elixir -pa "$W/beams" -e '
  import Bitwise
  [n, dir] = System.argv(); n = String.to_integer(n)
  :rand.seed(:exsss, {7, 8, 9})
  xs = for i <- 0..(n - 1), do: round(1_500_000 * :math.sin(i / 37.0) + 300_000 + :rand.uniform(400_000) - 200_000)
  File.write!(Path.join(dir, "in.hex"), Enum.map(xs, &(Integer.to_string(&1 &&& 0x3FFFFF, 16) <> "\n")))
  {ys, _} = Enum.map_reduce(xs, FMMono.deemphasis(:init), &FMMono.deemphasis/2)
  File.write!(Path.join(dir, "elixir.txt"), Enum.map(ys, &(String.pad_leading(Integer.to_string(&1 &&& 0xFFFF, 16), 4, "0") <> "\n")))
' "$N" "$W"
iverilog -g2012 -o "$W/sim" mono_out_tb.v "$RTL/stereo_out.v"
(cd "$W" && vvp -n sim +N="$N" | grep -E "^[0-9a-f]{4}$" | tr "a-f" "A-F") > "$W/verilog.txt"
if cmp -s "$W/elixir.txt" "$W/verilog.txt"; then
    echo "mono_out: $N samples, Elixir = Verilog"
else
    echo "mono_out: MISMATCH"; diff "$W/elixir.txt" "$W/verilog.txt" | head; exit 1
fi
