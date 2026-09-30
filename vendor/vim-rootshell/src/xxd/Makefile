# The most simplistic Makefile

# SANITIZER_CFLAGS=-g -O0  -fsanitize-recover=all -fsanitize=address -fsanitize=undefined -fno-omit-frame-pointer

# Two-step build so .o persists for dsymutil to generate a valid dSYM
xxd: xxd.o
	$(CC) $(SANITIZER_CFLAGS) $(LDFLAGS) -o xxd xxd.o $(LIBS)

xxd.o: xxd.c
	$(CC) $(SANITIZER_CFLAGS) $(CFLAGS) $(CPPFLAGS) -DUNIX -c -o xxd.o xxd.c

clean:
	rm -f xxd xxd.o
	rm -rf xxd.dSYM
