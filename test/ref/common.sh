# Sourced by the reference tests (test/ref/*.sh): the application (APP), atomvm-tang25k-hls
# (PLATFORM, from ATOMVM_TANG25K_HLS or next to the application; its env.sh finds elixir-hls),
# the reference RTL (RTL: the Verilog of usb-rtl-sdr-tang25k the Elixir functions are
# compared with) and beams <dir> <file.ex>...: the block packages (hls.env) and the given
# files compiled for the host against elixir-hls.
APP=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PLATFORM=$(cd "${ATOMVM_TANG25K_HLS:-$APP/../atomvm-tang25k-hls}" && pwd)
RTL=$APP/test/ref/rtl
beams() {
    local dir=$1; shift
    (
        cd "$APP" && source "$PLATFORM/scripts/env.sh" && hls_ebin
        local pkg_ex=() d f
        for d in "${PKG_DIRS[@]+"${PKG_DIRS[@]}"}"; do     # (built-in blocks: in elixir-hls)
            for f in "$d"/lib/*.ex; do [ -e "$f" ] && pkg_ex+=("$f"); done
        done
        elixirc -pa "$EHLS_EBIN" -o "$dir" "${pkg_ex[@]+"${pkg_ex[@]}"}" "$@" > /dev/null 2>&1
        cp "$EHLS_EBIN"/*.beam "$dir/"
    )
}
