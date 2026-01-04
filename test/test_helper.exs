# Compile support files
Code.require_file("test/support/fake_ethercat.ex")

# Compile hardware configs
for file <- Path.wildcard("test/support/hardware_configs/*.ex") do
  Code.require_file(file)
end

# Compile driver modules
# for file <- Path.wildcard("test/support/drivers/*.ex") do
# Code.require_file(file)
# end

ExUnit.start()
