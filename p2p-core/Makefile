.PHONY: xcframework test clean
xcframework:
	./scripts/build-xcframework.sh
test:
	cargo test --lib
clean:
	cargo clean && rm -rf build ../Vendor/P2PCore.xcframework ../MediaHub/P2P/Generated
