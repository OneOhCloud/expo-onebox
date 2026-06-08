SING_BOX_TAG = "v1.13.13"
CRONET_ANDROID_MODULES = \
	github.com/sagernet/cronet-go/lib/android_386 \
	github.com/sagernet/cronet-go/lib/android_amd64 \
	github.com/sagernet/cronet-go/lib/android_arm \
	github.com/sagernet/cronet-go/lib/android_arm64

# 获取 https://github.com/SagerNet/cronet-go 最新版本的tag
CRONET_GO_VERSION := $(shell curl -sL https://api.github.com/repos/SagerNet/cronet-go/releases/latest | sed -n 's/.*"tag_name":[[:space:]]*"\([^"\]*\)".*/\1/p')
CRONET_GO_TAG := $(notdir $(CRONET_GO_VERSION))


#  ../android/libs 删除并重新创建
clean_native:
	rm -rf ../android/libs
	mkdir -p ../android/libs
	rm -rf ../ios/Libbox.xcframework



# 克隆到当前目录
clone_sing_box:	
	git clone --depth 1 --branch $(SING_BOX_TAG) https://github.com/SagerNet/sing-box.git
	cp main.go sing-box/cmd/internal/build_libbox


# 下载 https://github.com/SagerNet/cronet-go/releases 最新版本的所有文件到 sing-box 目录下
download_cronet:
	curl -sL https://api.github.com/repos/SagerNet/cronet-go/releases/latest \
	| grep "browser_download_url" \
	| sed -E 's/.*"([^"]+)".*/\1/' \
	| while read url; do curl -L -o sing-box/$$(basename "$$url") "$$url"; done

# 自愈 Go module cache：Android cronet-go 包必须包含 libcronet.a。
# 如果解压目录损坏或缺失静态库，从 Go 下载缓存 zip 重新解压对应模块。
ensure_cronet_android_cache:
	@set -eu; \
	if [ ! -d sing-box ]; then \
		echo "sing-box not found, run clone_sing_box first"; \
		exit 1; \
	fi; \
	cd sing-box; \
	gomodcache=$$(go env GOMODCACHE); \
	for module in $(CRONET_ANDROID_MODULES); do \
		version=$$(go list -m -f '{{.Version}}' "$$module"); \
		dir="$$gomodcache/$$module@$$version"; \
		if [ -f "$$dir/libcronet.a" ]; then \
			echo "cronet cache ok: $$module@$$version"; \
			continue; \
		fi; \
		echo "repairing cronet cache: $$module@$$version"; \
		zip=$$(go mod download -json "$$module@$$version" | sed -n 's/^[[:space:]]*"Zip":[[:space:]]*"\(.*\)",/\1/p'); \
		if [ -z "$$zip" ] || [ ! -f "$$zip" ]; then \
			echo "missing module zip for $$module@$$version"; \
			exit 1; \
		fi; \
		if ! unzip -l "$$zip" "$$module@$$version/libcronet.a" >/dev/null; then \
			echo "module zip does not contain libcronet.a: $$module@$$version"; \
			exit 1; \
		fi; \
		if [ -d "$$dir" ]; then \
			chmod -R u+w "$$dir"; \
		fi; \
		unzip -q -o "$$zip" "$$module@$$version/*" -d "$$gomodcache"; \
		if [ ! -f "$$dir/libcronet.a" ]; then \
			echo "failed to repair libcronet.a: $$dir"; \
			exit 1; \
		fi; \
		chmod -R u-w "$$dir"; \
	done

build:
	rm -rf sing-box
	$(MAKE) clean_native
	$(MAKE) clone_sing_box
	$(MAKE) ensure_cronet_android_cache
	$(MAKE) download_cronet
	cd sing-box && make lib_apple && make lib_android
	mv sing-box/libbox-sources.jar ../android/libs/

# 测试
test:
	@echo "SING_BOX_VERSION: $(SING_BOX_VERSION)"
	@echo "SING_BOX_TAG: $(SING_BOX_TAG)"
