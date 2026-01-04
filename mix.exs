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
      make_env: make_env(),
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

  defp make_env do
    # Setup environment for Nerves cross-compilation
    base_env = %{}

    case System.get_env("NERVES_SDK_SYSROOT") do
      nil ->
        # Native build - pkg-config will find system libraries
        base_env

      sysroot ->
        # Nerves cross-compilation
        pkg_config_path = Path.join([sysroot, "usr", "lib", "pkgconfig"])
        pkg_config_libdir = "#{pkg_config_path}:#{Path.join([sysroot, "usr", "share", "pkgconfig"])}"

        Map.merge(base_env, %{
          "PKG_CONFIG_SYSROOT_DIR" => sysroot,
          "PKG_CONFIG_LIBDIR" => pkg_config_libdir,
          "CROSSCOMPILE" => System.get_env("CROSSCOMPILE", "")
        })
    end
  end

  defp make_error_message do
    """
    Could not compile the EtherCAT driver.

    Please ensure:
    1. The IgH EtherCAT Master is installed with pkg-config support
    2. Erlang development headers are available
    3. GCC or cross-compiler toolchain is installed

    For native builds (real driver):
      - Ensure libethercat.pc is in your PKG_CONFIG_PATH
      - Install EtherCAT master with: ./configure --enable-shared

    For testing (fake driver):
      - Ensure libfakeethercat.pc is in your PKG_CONFIG_PATH
      - Install with: ./configure --enable-fakeuserlib
      - The fake driver will be used automatically when MIX_ENV=test

    For Nerves cross-compilation:
      - Set NERVES_SDK_SYSROOT to your Nerves sysroot path
      - Set CROSSCOMPILE to your cross-compiler prefix
      - Ensure libethercat is built in the Nerves system
    """
  end
end
