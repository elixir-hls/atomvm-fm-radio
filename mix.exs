defmodule AtomVMFMRadio.MixProject do
  use Mix.Project

  def project do
    [
      app: :atomvm_fm_radio,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: [],
      deps: deps()
    ]
  end

  def application, do: []

  defp deps do
    [
      # the target (it brings elixir-hls and atomvm-tang25k) and the block packages
      {:atomvm_tang25k_hls, git: "https://github.com/elixir-hls/atomvm-tang25k-hls.git"},
      {:atomvm_tang25k_usb_host, git: "https://github.com/elixir-hls/atomvm-tang25k-usb-host.git"},
      {:atomvm_tang25k_rtlsdr, git: "https://github.com/elixir-hls/atomvm-tang25k-rtlsdr.git"},
      {:atomvm_tang25k_i2s, git: "https://github.com/elixir-hls/atomvm-tang25k-i2s.git"},
      {:atomvm_tang25k_rpi_display_35inch, git: "https://github.com/elixir-hls/atomvm-tang25k-rpi-display-3.5inch.git"}
    ]
  end
end
