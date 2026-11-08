#!/usr/bin/env bash
# The FIRs as placed, window |> every |> map: the stream functions FMRadio.mpx (mpx_tap) and
# FMMono.audio (audio_tap) on the CPU against fir_dec.v of usb-rtl-sdr-tang25k with the same
# parameters: N random samples at full scale, outputs compared.
set -euo pipefail
cd "$(dirname "$0")"
source ./common.sh
ROOT=$APP
W=$ROOT/build/ref/fir
N=${N:-2000}
rm -rf "$W" && mkdir -p "$W/beams"
beams "$W/beams" "$ROOT/lib/fm_coeffs.ex" "$ROOT/lib/fm_radio.ex" "$ROOT/test/fm_mono.ex"
#          module  fun               IW OW TAPS DEC PHASE SH SAT AW TABLE
for cfg in "FMRadio mpx   16 18 32  4 3 15 1 6 1" "FMMono  audio 18 22 224 5 4 17 0 8 2"; do
    read -r MODULE FUN IW OW TAPS DEC PHASE SH SAT AW TABLE <<< "$cfg"
    D=$W/$FUN; mkdir -p "$D"
    elixir -pa "$W/beams" -e '
      import Bitwise
      [mod, fun, n, iw, ow, dir] = System.argv()
      mod = Module.concat([mod]); fun = String.to_atom(fun); n = String.to_integer(n); iw = String.to_integer(iw); ow = String.to_integer(ow)
      :rand.seed(:exsss, {3, 1, 4})
      half = 1 <<< (iw - 1)
      xs = for _ <- 1..n, do: :rand.uniform(2 * half) - half - 1
      File.write!(Path.join(dir, "in.hex"), Enum.map(xs, &(Integer.to_string(&1 &&& ((1 <<< iw) - 1), 16) <> "\n")))
      ys = apply(mod, fun, [xs])
      digits = div(ow + 3, 4)
      File.write!(Path.join(dir, "elixir.txt"), Enum.map(ys, &(String.pad_leading(Integer.to_string(&1 &&& ((1 <<< ow) - 1), 16), digits, "0") <> "\n")))
    ' "$MODULE" "$FUN" "$N" "$IW" "$OW" "$D"
    iverilog -g2012 -DIW=$IW -DOW=$OW -DTAPS=$TAPS -DDEC=$DEC -DPHASE=$PHASE -DSH=$SH -DSAT=$SAT -DAW=$AW \
        -DTABLE=$TABLE -I "$RTL" -o "$D/sim" fir_tb.v "$RTL/fir_dec.v"
    (cd "$D" && vvp -n sim +N="$N" | grep -E "^[0-9a-f]+$" | tr "a-f" "A-F") > "$D/verilog.txt"
    if cmp -s "$D/elixir.txt" "$D/verilog.txt"; then
        echo "$FUN: $N samples, $(wc -l < "$D/verilog.txt") outputs, Elixir = Verilog"
    else
        echo "$FUN: MISMATCH"; diff "$D/elixir.txt" "$D/verilog.txt" | head -6; exit 1
    fi
done
