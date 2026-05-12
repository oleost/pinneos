VERSION  ?= dev
DEVICE   ?=
IMAGE     = ../release/pinneos-$(VERSION)-x86_64.iso
IMG       = ../release/pinneos-$(VERSION)-x86_64.img
BUILDER   = pinneos-builder

.PHONY: build image img clean write release qemu help

help:
	@echo "PinneOS build targets:"
	@echo "  make build           Build the Docker build container"
	@echo "  make image           Build ISO + A/B USB image (.img, Etcher-ready)"
	@echo "  make img             Rebuild only the .img (reuses existing ISO, ~5 min)"
	@echo "  make write DEVICE=X  Quick dd ISO to USB for VM/testing (no A/B)"
	@echo "  make release         Build + generate SHA256 + manifest"
	@echo "  make qemu            Boot ISO in QEMU for local testing"
	@echo "  make clean           Remove build artifacts"

build:
	docker build -t $(BUILDER) .

image: build
	@mkdir -p ../release
	docker run --rm --privileged \
		-v $(realpath ../build/profile):/profile:ro \
		-v $(realpath ../overlay):/overlay:ro \
		-v $(realpath ../grub):/grub:ro \
		-v $(realpath ../release):/out \
		$(BUILDER) $(VERSION)

img: build
	@test -f ../release/pinneos-$(VERSION)-x86_64.iso || \
	    (echo "No ISO found. Run: make image VERSION=$(VERSION)" && exit 1)
	@mkdir -p ../release
	@rm -f ../release/pinneos-$(VERSION)-x86_64.img
	docker run --rm --privileged \
		-v $(realpath ../build/profile):/profile:ro \
		-v $(realpath ../overlay):/overlay:ro \
		-v $(realpath ../grub):/grub:ro \
		-v $(realpath ../release):/out \
		-e SKIP_ISO=1 \
		$(BUILDER) $(VERSION)

clean:
	rm -rf ../release/*.iso ../release/*.img ../release/*.sha256 ../release/*.json

write:
	@test -n "$(DEVICE)" || (echo "Usage: make write DEVICE=/dev/sdX" && exit 1)
	@test -f "$(IMAGE)" || (echo "No image found. Run: make image" && exit 1)
	@echo ""
	@echo "  WARNING: This will ERASE $(DEVICE)"
	@echo "  Image:   $(IMAGE)"
	@echo ""
	@read -p "  Type YES to continue: " ans; [ "$$ans" = "YES" ] || exit 1
	sudo dd if="$(IMAGE)" of="$(DEVICE)" bs=4M status=progress conv=fsync
	@echo "Done. You can now boot from $(DEVICE)."

release: image
	sha256sum "$(IMAGE)" > "$(IMAGE).sha256"
	@echo "Compressing IMG for release (this takes a few minutes)..."
	gzip -k -9 "$(IMG)"
	sha256sum "$(IMG).gz" > "$(IMG).gz.sha256"
	printf '{"version":"%s","min_compatible":"0.1.0","channel":"stable"}\n' \
	    "$(VERSION)" > "../release/pinneos-$(VERSION)-manifest.json"
	@echo "Release artifacts:"
	@ls -lh ../release/

qemu: image
	@command -v qemu-system-x86_64 >/dev/null || \
	    (echo "Install qemu-system-x86 first" && exit 1)
	@test -f /tmp/pinneos-test-disk.qcow2 || \
	    qemu-img create -f qcow2 /tmp/pinneos-test-disk.qcow2 20G
	qemu-system-x86_64 \
		-m 4096 \
		-smp 2 \
		-enable-kvm \
		-drive file="$(IMAGE)",format=raw,if=virtio,readonly=on \
		-drive file=/tmp/pinneos-test-disk.qcow2,format=qcow2,if=virtio \
		-netdev user,id=net0,hostfwd=tcp::9090-:9090,hostfwd=tcp::5001-:5001,hostfwd=tcp::8080-:80 \
		-device virtio-net-pci,netdev=net0 \
		-display sdl 2>/dev/null || \
		qemu-system-x86_64 \
		-m 4096 \
		-smp 2 \
		-enable-kvm \
		-drive file="$(IMAGE)",format=raw,if=virtio,readonly=on \
		-drive file=/tmp/pinneos-test-disk.qcow2,format=qcow2,if=virtio \
		-netdev user,id=net0,hostfwd=tcp::9090-:9090,hostfwd=tcp::5001-:5001,hostfwd=tcp::8080-:80 \
		-device virtio-net-pci,netdev=net0 \
		-nographic
