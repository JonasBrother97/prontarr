.PHONY: build test run frontend
frontend:
	npm ci --prefix frontend
	npm run build --prefix frontend
build: frontend
	zig build
run:
	./zig-out/bin/prontarr
test:
	zig build test
	python3 tests/api_smoke.py
	python3 tests/observe_contract.py
