defmodule AtomVMFMRadio.MixProject do
  use Mix.Project

  def project do
    [
      app: :atomvm_fm_radio,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: deps()
    ]
  end

  def application, do: []

  defp deps do
    [
      # the target, the Tang Primer 25K: it brings elixir-hls and atomvm-tang25k
      {:atomvm_tang25k_hls, "~> 0.1"},
      # the block packages (each a block of the SoC; config :elixir_hls, blocks: picks among them); the RTL-SDR brings
      # the USB host
      {:atomvm_tang25k_rtlsdr, "~> 0.1"},
      {:atomvm_tang25k_i2s, "~> 0.1"},
      {:atomvm_tang25k_rpi_display_35inch, "~> 0.1"}
    ]
  end
end
