always: game.bin

clean:
	rm -f *.lst *.bin *.map *.sym  labels.txt *~ src/*~

COPT = -C -Wall -Werror -Wno-shadow --verbose-list --labels=labels.txt

image:
	(cd c; make)

SRC	= \
	src/game.asm \
	src/api.asm \

game.bin: $(SRC)
	64tass $(COPT) $^ -b -L $(basename $@).lst -o $@


