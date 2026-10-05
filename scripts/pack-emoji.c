/* Packs Twemoji's 72x72 PNGs into the one file Tiger Build reads: tiger-build/Emoji.pack.
     git clone --depth 1 --filter=blob:none --sparse https://github.com/jdecked/twemoji
     git -C twemoji sparse-checkout set --no-cone assets/72x72
     cc -o /tmp/pack-emoji scripts/pack-emoji.c && /tmp/pack-emoji twemoji/assets/72x72 tiger-build/Emoji.pack
   Layout, all numbers big-endian: "TBEM", count, then per picture: name length (1 byte), name (the file name without .png),
   offset (4), length (4); then the PNGs. Offsets count from the end of the index. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>

static int compare(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }
static void put32(FILE *f, unsigned long v) { fputc(v >> 24, f); fputc(v >> 16, f); fputc(v >> 8, f); fputc(v, f); }

int main(int argc, char **argv)
{
    DIR *d;
    struct dirent *e;
    char **names = NULL, path[1024];
    unsigned long count = 0, offset = 0, i, *sizes;
    FILE *out, *in;
    if (argc != 3) { fprintf(stderr, "usage: pack-emoji folder output\n"); return 2; }
    if (!(d = opendir(argv[1]))) { perror(argv[1]); return 1; }
    while ((e = readdir(d))) {
        size_t n = strlen(e->d_name);
        if (n > 4 && !strcmp(e->d_name + n - 4, ".png")) {
            names = realloc(names, (count + 1) * sizeof *names);
            names[count] = strdup(e->d_name);
            names[count++][n - 4] = 0;
        }
    }
    closedir(d);
    qsort(names, count, sizeof *names, compare);
    sizes = calloc(count, sizeof *sizes);
    for (i = 0; i < count; i++) {
        snprintf(path, sizeof path, "%s/%s.png", argv[1], names[i]);
        if (!(in = fopen(path, "rb"))) { perror(path); return 1; }
        fseek(in, 0, SEEK_END);
        sizes[i] = ftell(in);
        fclose(in);
    }
    if (!(out = fopen(argv[2], "wb"))) { perror(argv[2]); return 1; }
    fwrite("TBEM", 1, 4, out);
    put32(out, count);
    for (i = 0; i < count; i++) {
        fputc((int)strlen(names[i]), out);
        fwrite(names[i], 1, strlen(names[i]), out);
        put32(out, offset);
        put32(out, sizes[i]);
        offset += sizes[i];
    }
    for (i = 0; i < count; i++) {
        char *buffer = malloc(sizes[i]);
        snprintf(path, sizeof path, "%s/%s.png", argv[1], names[i]);
        in = fopen(path, "rb");
        if (fread(buffer, 1, sizes[i], in) != sizes[i]) { perror(path); return 1; }
        fclose(in);
        fwrite(buffer, 1, sizes[i], out);
        free(buffer);
    }
    fclose(out);
    printf("%lu pictures\n", count);
    return 0;
}
