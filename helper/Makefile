# 获取 https://github.com/SagerNet/sing-box 最新版本的tag
SING_BOX_VERSION := $(shell curl -sL https://api.github.com/repos/SagerNet/sing-box/releases/latest | sed -n 's/.*"tag_name":[[:space:]]*"\([^"\]*\)".*/\1/p')
SING_BOX_TAG := $(notdir $(SING_BOX_VERSION))

# 获取 https://github.com/SagerNet/cronet-go 最新版本的tag
CRONET_GO_VERSION := $(shell curl -sL https://api.github.com/repos/SagerNet/cronet-go/releases/latest | sed -n 's/.*"tag_name":[[:space:]]*"\([^"\]*\)".*/\1/p')
CRONET_GO_TAG := $(notdir $(CRONET_GO_VERSION))


#  ../android/src/libs 删除并重新创建
clean_native:
	rm -rf ../android/src/libs
	mkdir -p ../android/src/libs
	rm -rf ../ios/Libbox.xcframework



# 克隆到当前目录
clone:	
	git clone --depth 1 --branch $(SING_BOX_TAG) https://github.com/SagerNet/sing-box.git
	cp main.go sing-box/cmd/internal/build_libbox


# 下载 https://github.com/SagerNet/cronet-go/releases 最新版本的所有文件到 sing-box 目录下
download_cronet:
	curl -sL https://api.github.com/repos/SagerNet/cronet-go/releases/latest \
	| grep "browser_download_url" \
	| sed -E 's/.*"([^"]+)".*/\1/' \
	| while read url; do curl -L -o sing-box/$$(basename "$$url") "$$url"; done


build: clean_native clone download_cronet
	cd sing-box && make lib_apple && make lib_android

# 测试
test:
	@echo "SING_BOX_VERSION: $(SING_BOX_VERSION)"
	@echo "SING_BOX_TAG: $(SING_BOX_TAG)"