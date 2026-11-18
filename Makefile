.PHONY: build test run frontend
frontend:
	npm ci --prefix frontend
	npm run build --prefix frontend
build: frontend
	zig build
run:
	./zig-out/bin/prontarr
test:
	npm run build --prefix frontend
	zig build
	npm test --prefix frontend
	zig build test
	python3 tests/api_smoke.py
	python3 tests/observe_contract.py
	python3 tests/controller_contract.py
	python3 tests/ownership_contract.py
