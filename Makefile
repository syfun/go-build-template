# Copyright 2016 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# The binary to build (just the basename).
BIN := myapp

# This repo's root import path (under GOPATH).
PKG := github.com/thockin/go-build-template

# Where to push the docker image.
REGISTRY ?= thockin

# Which platform to build - see $(ALL_PLATFORMS) for options.
PLATFORM ?= linux/amd64

OS := $(firstword $(subst /, ,$(PLATFORM)))
ARCH := $(lastword $(subst /, ,$(PLATFORM)))

# This version-strategy uses git tags to set the version string
VERSION := $(shell git describe --tags --always --dirty)
#
# This version-strategy uses a manual value to set the version string
#VERSION := 1.2.3

###
### These variables should not need tweaking.
###

SRC_DIRS := cmd pkg # directories which hold app source (not vendored)

ALL_PLATFORMS := linux/amd64 linux/arm linux/arm64 linux/ppc64le

# Set default base image dynamically for each arch
# TODO: make these all consistent and tagged.
ifeq ($(ARCH),amd64)
    BASEIMAGE?=alpine:3.8
endif
ifeq ($(ARCH),arm)
    BASEIMAGE?=armel/busybox
endif
ifeq ($(ARCH),arm64)
    BASEIMAGE?=aarch64/busybox
endif
ifeq ($(ARCH),ppc64le)
    BASEIMAGE?=ppc64le/busybox
endif

IMAGE := $(REGISTRY)/$(BIN)
TAG := $(VERSION)__$(OS)_$(ARCH)

BUILD_IMAGE ?= golang:1.11-alpine

# If you want to build all binaries, see the 'all-build' rule.
# If you want to build all containers, see the 'all-container' rule.
# If you want to build AND push all containers, see the 'all-push' rule.
all: build

build-%:
	@$(MAKE) --no-print-directory ARCH=$* build

container-%:
	@$(MAKE) --no-print-directory ARCH=$* container

push-%:
	@$(MAKE) --no-print-directory ARCH=$* push

all-build: $(addprefix build-, $(ALL_PLATFORMS))

all-container: $(addprefix container-, $(ALL_PLATFORMS))

all-push: $(addprefix push-, $(ALL_PLATFORMS))

build: bin/$(OS)_$(ARCH)/$(BIN)

# Directories that we need created to build/test.
BUILD_DIRS := bin/$(OS)_$(ARCH)     \
              .go/src/$(PKG)        \
              .go/pkg               \
              .go/bin               \
              .go/std/$(OS)_$(ARCH) \
              .go/cache

# TODO: This is .PHONY because building Go code uses a compiler-internal DAG,
# so we have to run the go tool.  Unfortunately, go always touches the binary
# during `go install` even if it didn't change anything (as per md5sum).  This
# makes make unhappy.  Better would be to run go, see that the result did not
# change, and then bypass further processing.  Sadly not possible for now.
.PHONY: bin/$(OS)_$(ARCH)/$(BIN)
bin/$(OS)_$(ARCH)/$(BIN): $(BUILD_DIRS)
	@echo "building: $@"
	@docker run                                                                 \
	    -i                                                                      \
	    --rm                                                                    \
	    -u $$(id -u):$$(id -g)                                                  \
	    -v $$(pwd):/go/src/$(PKG)                                               \
	    -v $$(pwd)/bin/$(OS)_$(ARCH):/go/bin                                    \
	    -v $$(pwd)/bin/$(OS)_$(ARCH):/go/bin/$(OS)_$(ARCH)                      \
	    -v $$(pwd)/.go/std/$(OS)_$(ARCH):/usr/local/go/pkg/$(OS)_$(ARCH)_static \
	    -v $$(pwd)/.go/cache:/.cache                                            \
	    -w /go/src/$(PKG)                                                       \
	    --env HTTP_PROXY=$(HTTP_PROXY)                                          \
	    --env HTTPS_PROXY=$(HTTPS_PROXY)                                        \
	    $(BUILD_IMAGE)                                                          \
	    /bin/sh -c "                                                            \
	        ARCH=$(ARCH)                                                        \
	        OS=$(OS)                                                            \
	        VERSION=$(VERSION)                                                  \
	        PKG=$(PKG)                                                          \
	        ./build/build.sh                                                    \
	    "

# Example: make shell CMD="-c 'date > datefile'"
shell: $(BUILD_DIRS)
	@echo "launching a shell in the containerized build environment"
	@docker run                                                                 \
	    -ti                                                                     \
	    --rm                                                                    \
	    -u $$(id -u):$$(id -g)                                                  \
	    -v $$(pwd):/go/src/$(PKG)                                               \
	    -v $$(pwd)/bin/$(OS)_$(ARCH):/go/bin                                    \
	    -v $$(pwd)/bin/$(OS)_$(ARCH):/go/bin/$(OS)_$(ARCH)                      \
	    -v $$(pwd)/.go/std/$(OS)_$(ARCH):/usr/local/go/pkg/$(OS)_$(ARCH)_static \
	    -v $$(pwd)/.go/cache:/.cache                                            \
	    -w /go/src/$(PKG)                                                       \
	    --env HTTP_PROXY=$(HTTP_PROXY)                                          \
	    --env HTTPS_PROXY=$(HTTPS_PROXY)                                        \
	    $(BUILD_IMAGE)                                                          \
	    /bin/sh $(CMD)

DOTFILE_IMAGE = $(subst /,_,$(IMAGE))-$(TAG)

container: .container-$(DOTFILE_IMAGE) say_container_name
.container-$(DOTFILE_IMAGE): bin/$(OS)_$(ARCH)/$(BIN) Dockerfile.in
	@sed                                 \
	    -e 's|{ARG_BIN}|$(BIN)|g'        \
	    -e 's|{ARG_ARCH}|$(ARCH)|g'      \
	    -e 's|{ARG_OS}|$(OS)|g'          \
	    -e 's|{ARG_FROM}|$(BASEIMAGE)|g' \
	    Dockerfile.in > .dockerfile-$(OS)_$(ARCH)
	@docker build -t $(IMAGE):$(TAG) -f .dockerfile-$(OS)_$(ARCH) .
	@docker images -q $(IMAGE):$(TAG) > $@

say_container_name:
	@echo "container: $(IMAGE):$(TAG)"

push: .push-$(DOTFILE_IMAGE) say_push_name
.push-$(DOTFILE_IMAGE): .container-$(DOTFILE_IMAGE)
	@docker push $(IMAGE):$(TAG)

say_push_name:
	@echo "pushed: $(IMAGE):$(TAG)"

manifest-list: push
	platforms=$$(echo $(ALL_PLATFORMS) | sed 's/ /,/g');  \
	manifest-tool                                         \
	    --username=oauth2accesstoken                      \
	    --password=$$(gcloud auth print-access-token)     \
	    push from-args                                    \
	    --platforms "$$platforms"                         \
	    --template $(REGISTRY)/$(BIN):$(VERSION)__OS_ARCH \
	    --target $(REGISTRY)/$(BIN):$(VERSION)

version:
	@echo $(VERSION)

test: $(BUILD_DIRS)
	@docker run                                                                  \
	    -i                                                                       \
	    --rm                                                                     \
	    -u $$(id -u):$$(id -g)                                                   \
	    -v $$(pwd)/.go:/go                                                       \
	    -v $$(pwd):/go/src/$(PKG)                                                \
	    -v $$(pwd)/bin/$(OS)_$(ARCH):/go/bin                                     \
	    -v $$(pwd)/.go/std/$(OS)_$(ARCH):/usr/local/go/pkg/$(OS)_$(ARCH)_static  \
	    -v $$(pwd)/.go/cache:/.cache                                             \
	    -w /go/src/$(PKG)                                                        \
	    --env HTTP_PROXY=$(HTTP_PROXY)                                           \
	    --env HTTPS_PROXY=$(HTTPS_PROXY)                                         \
	    $(BUILD_IMAGE)                                                           \
	    /bin/sh -c "                                                             \
	        ARCH=$(ARCH)                                                         \
	        OS=$(OS)                                                             \
	        VERSION=$(VERSION)                                                   \
	        PKG=$(PKG)                                                           \
	        ./build/test.sh $(SRC_DIRS)                                          \
	    "

$(BUILD_DIRS):
	@mkdir -p $@

clean: container-clean bin-clean

container-clean:
	rm -rf .container-* .dockerfile-* .push-*

bin-clean:
	rm -rf .go bin
