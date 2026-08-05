default:
	@just --list

# Instantiate and run tests
test:
	julia --project=@. -e 'using Pkg; Pkg.instantiate(); Pkg.test()'

# Start a REPL with the project
dev:
	julia --project=@.

# Instantiate dependencies
instantiate:
	julia --project=@. -e 'using Pkg; Pkg.instantiate()'

# Build the documentation (set CI=true to deploy)
docs:
	julia --project=docs -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()'
	julia --project=docs docs/make.jl