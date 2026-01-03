defmodule IghEthercatPort.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/sid2baker/igh_ethercat_port"

  def project do
    [
      app: :ethercat,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Build
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_clean: ["clean"],
      make_targets: ["all"],
      make_error_message: make_error_message(),

      # Hex
      description: description(),
      package: package(),

      # Docs
      name: "EtherCAT",
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {EtherCAT.Application, []}
    ]
  end

  defp deps do
    [
      {:elixir_make, "~> 0.7", runtime: false},
      {:ex_doc, "~> 0.39", only: :dev, runtime: false}
    ]
  end

  defp description do
    """
    Elixir bindings for the IgH EtherCAT Master.
    Provides real-time fieldbus communication for industrial automation.
    """
  end

  defp package do
    [
      name: "ethercat",
      files: ~w(lib c_src priv/.gitkeep mix.exs Makefile README.md LICENSE),
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "IgH EtherCAT Master" => "https://etherlab.org/en/ethercat/"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENSE"],
      source_ref: "v#{@version}",
      groups_for_modules: [
        Core: [
          EtherCAT,
          EtherCAT.Master,
          EtherCAT.SlaveConfig,
          EtherCAT.PDO
        ]
      ]
    ]
  end

  defp make_error_message do
    """
    Could not compile the EtherCAT driver.

    Please ensure:
    1. The IgH EtherCAT Master is installed (default: /opt/etherlab)
    2. Erlang development headers are available
    3. GCC is installed

    Run 'make check' for detailed diagnostics.

    If EtherCAT is installed in a non-standard location, set:
      export ETHERCAT_PATH=/path/to/ethercat
    """
  end
end
