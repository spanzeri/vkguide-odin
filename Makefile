ARGS = -vet \
       -debug \
       -vet-cast \
       -vet-using-param \
       -warnings-as-errors \
       -disallow-do \
       -vet-style \
       -vet-semicolon
       # -collection:libs=./libs/"

.PHONY: all clean

all: dirs engine

dirs:
	@mkdir -p bin

engine:
	@odin build source -out:bin/engine $(ARGS)

clean:
	@rm -rf bin
