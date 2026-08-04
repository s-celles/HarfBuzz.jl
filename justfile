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