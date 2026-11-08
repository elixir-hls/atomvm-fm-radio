#!/usr/bin/env bash
# FMRadio.discriminator (map(&phase/1) |> transform(0, &phase_step/2) on the CPU: CORDIC +
# phase difference) against
# fm_disc.v of usb-rtl-sdr-tang25k: N {I, Q} samples (an FM-like rotating phasor of varying
# amplitude, plus random words and the corners), the outputs d compared.
set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh
ROOT=$APP
W=$ROOT/build/ref/disc
N=${N:-4000}
rm -rf "$W" && mkdir -p "$W/beams"
beams "$W/beams" "$ROOT/lib/fm_coeffs.ex" "$ROOT/lib/fm_radio.ex"
elixir -pa "$W/beams" -e '
  import Bitwise
  [n, dir] = System.argv(); n = String.to_integer(n)
  :rand.seed(:exsss, {4, 5, 6})
  clip = fn v -> min(255, max(0, v)) end
  corners = for i <- [0, 1, 127, 128, 129, 255], q <- [0, 1, 127, 128, 129, 255], do: i <<< 8 ||| q
  fm = for t <- 0..(div(n, 2) - 1) do
    a = 20 + rem(t, 108)
    ph = 2 * :math.pi() * (0.05 * t + 0.6 * :math.sin(t / 50.0))
    clip.(round(128 + a * :math.cos(ph))) <<< 8 ||| clip.(round(128 + a * :math.sin(ph)))
  end
  rnd = for _ <- 1..(n - length(corners) - length(fm)), do: :rand.uniform(65536) - 1
  xs = corners ++ fm ++ rnd
  File.write!(Path.join(dir, "in.hex"), Enum.map(xs, &(Integer.to_string(&1, 16) <> "\n")))
  ds = FMRadio.discriminator(xs)
  File.write!(Path.join(dir, "elixir.txt"), Enum.map(ds, &(String.pad_leading(Integer.to_string(&1 &&& 0xFFFF, 16), 4, "0") <> "\n")))
' "$N" "$W"
iverilog -g2012 -o "$W/sim" disc_tb.v "$RTL/fm_disc.v"
(cd "$W" && vvp -n sim +N="$N" | grep -E "^[0-9a-f]{4}$" | tr "a-f" "A-F") > "$W/verilog.txt"
if cmp -s "$W/elixir.txt" "$W/verilog.txt"; then
    echo "disc: $N samples, Elixir = Verilog"
else
    echo "disc: MISMATCH"; diff "$W/elixir.txt" "$W/verilog.txt" | head; exit 1
fi
