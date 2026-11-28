import Config

# the board, the Sipeed Tang Primer 25K (atomvm-tang25k-hls); FMRadio.start/0 runs on it (FMDemo: the scripted run)
config :elixir_hls, target: :tang25k, start: FMRadio

# the placement and routing with the most Fmax margin (sweep_soc.sh: 16.8%, on the system clock; place 1 and 2 with
# the default routing leave under 5% there)
config :elixir_hls, gowin: [place: 2, route: 1]

# the instances in the FPGA on the host too (mix compile, mix test): the radio's source and sink, usb_bulk_in and
# i2s_out, are blocks of the SoC and have no CPU version
config :elixir_hls, placement: :fpga

# this machine's paths (GOWIN_HOME, UART_PORT, ATOMVM_TANG25K, CIRCT_BIN; mix ehls.doctor lists them), kept out of
# git: config :elixir_hls, gowin_home: "~/Gowin_V1.9.11.03_Education", ...
if File.exists?(Path.join(__DIR__, "local.exs")), do: import_config("local.exs")
