ARGS = -vet \
       -debug \
       -vet-cast \
       -vet-using-param \
       -warnings-as-errors \
       -disallow-do \
       -vet-style \
       -vet-semicolon \
       -collection:lib=./libs/

SHADER_BIN_DIR = bin/shaders
SHADER_SRC_DIR = shaders

SHADER_SRCS = $(wildcard $(SHADER_SRC_DIR)/*.glsl)
SHADER_BINS = $(patsubst $(SHADER_SRC_DIR)/%.glsl, $(SHADER_BIN_DIR)/%.spv, $(SHADER_SRCS))

.PHONY: all clean

all: dirs engine

dirs:
	@mkdir -p bin

engine: libs shaders
	@odin build source -out:bin/engine $(ARGS)

libs: vma

vma:
	@cmake -B build/vma -S 3rdparty/VulkanMemoryAllocator-3.3.0/ -DVMA_ENABLE_INSTALL=OFF
	@mkdir -p build/vma
	@c++ -c 3rdparty/vma_impl.cpp -o build/vma/vma_impl.o -fno-exceptions -fno-rtti -std=c++20
	@ar rcs build/libvma-3.3.0.a build/vma/vma_impl.o

shaders: $(SHADER_BINS)

$(SHADER_BIN_DIR)/%.spv: $(SHADER_SRC_DIR)/%.glsl
	@mkdir -p $(dir $@)
	@glslangValidator -V $< -o $@

clean:
	@rm -rf bin
	@rm -rf build
