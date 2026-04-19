SING_BOX_TAG = "v1.13.8"

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


build:
	rm -rf sing-box
	$(MAKE) clean_native
	$(MAKE) clone_sing_box
	$(MAKE) download_cronet
	cd sing-box && make lib_apple && make lib_android
	mv sing-box/libbox-sources.jar ../android/libs/

# 测试
test:
	@echo "SING_BOX_VERSION: $(SING_BOX_VERSION)"
	@echo "SING_BOX_TAG: $(SING_BOX_TAG)"