/* tbsmbd: Tiger Build's SMB 2/3 file server. One folder shared under one name to the people in a users file, with NTLMv2 passwords and signed
   messages, written on libsmb2's server framework (third_party/libsmb2, patched: see patches/tbsmbd.patch there).
     tbsmbd --root FOLDER --share NAME --users FILE [--port N] [--readonly] [--listen-fd]
   --listen-fd: the listening socket is standard input (launchd's Wait mode on the port); otherwise the port is bound here (default 445).
   Not a Windows file server: no ACLs, streams, change notification, locking or resilient handles; symbolic links are never followed or shown;
   names are as the file system has them. The users file has one "name:password" per line (keep it private, 600). */

#define _GNU_SOURCE
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

#include "smb2.h"
#include "libsmb2.h"
#include "libsmb2-raw.h"

/* a handler's failure with an NT status of the 0xC000xxxx kind (see the libsmb2 patch) */
#define NTERR(code) (-(0x10000 + ((code) & 0xFFFF)))
#define ST_NOT_SUPPORTED     0xC00000BB
#define ST_ACCESS_DENIED     0xC0000022
#define ST_NAME_NOT_FOUND    0xC0000034
#define ST_PATH_NOT_FOUND    0xC000003A
#define ST_NAME_COLLISION    0xC0000035
#define ST_BAD_NETWORK_NAME  0xC00000CC
#define ST_INVALID_PARAMETER 0xC000000D
#define ST_INVALID_INFO      0xC0000003
#define ST_FILE_IS_DIR       0xC00000BA
#define ST_NOT_A_DIR         0xC0000103
#define ST_DIR_NOT_EMPTY     0xC0000101
#define ST_INVALID_HANDLE    0xC0000008
#define ST_OBJECT_NAME_INVALID 0xC0000033
#define ST_DISK_FULL         0xC000007F
#define ST_IO_ERROR          0xC000009C
#define ST_MEDIA_PROTECTED   0xC00000A2
#define ST_SHARING_VIOLATION 0xC0000043

#define MAX_IO (1024 * 1024)
#define MAX_OPEN 4096
#define MAX_SESSIONS 64

static const char *shareRoot, *shareName, *usersFile;
static int readOnly;
static int logging;

#define LOG(...) do { if (logging) { fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

/* ---- the open files and directories ---- */

struct ofile {
        int used;
        uint32_t generation;
        struct smb2_context *owner;
        int fd;
        char *path;             /* inside the root, always */
        char *rel;              /* as the client names it, with / */
        int isdir;
        int deleteOnClose;
        int writable;
        /* a directory listing, taken when it is first read or restarted */
        char **names;
        int nnames, next;
        char *pattern;
};

static struct ofile files[MAX_OPEN];

struct session {
        struct smb2_context *ctx;
        uint8_t lastId[SMB2_FD_SIZE];
        int haveLast;
};

static struct session sessions[MAX_SESSIONS];

static struct session *sessionFor(struct smb2_context *ctx, int create)
{
        int i, freeSlot = -1;
        for (i = 0; i < MAX_SESSIONS; i++) {
                if (sessions[i].ctx == ctx)
                        return &sessions[i];
                if (!sessions[i].ctx && freeSlot < 0)
                        freeSlot = i;
        }
        if (create && freeSlot >= 0) {
                memset(&sessions[freeSlot], 0, sizeof sessions[freeSlot]);
                sessions[freeSlot].ctx = ctx;
                return &sessions[freeSlot];
        }
        return NULL;
}

static void freeNames(struct ofile *f)
{
        int i;
        for (i = 0; i < f->nnames; i++)
                free(f->names[i]);
        free(f->names);
        f->names = NULL;
        f->nnames = f->next = 0;
}

static void releaseFile(struct ofile *f)
{
        if (f->fd >= 0)
                close(f->fd);
        freeNames(f);
        free(f->path);
        free(f->rel);
        free(f->pattern);
        f->used = 0;
        f->path = f->rel = f->pattern = NULL;
        f->fd = -1;
}

static void putId(uint8_t *id, int index, uint32_t generation)
{
        memset(id, 0, SMB2_FD_SIZE);
        id[0] = (index + 1) & 255; id[1] = ((index + 1) >> 8) & 255;
        id[4] = generation & 255; id[5] = (generation >> 8) & 255; id[6] = (generation >> 16) & 255; id[7] = (generation >> 24) & 255;
}

static struct ofile *lookup(struct smb2_context *ctx, const uint8_t *id)
{
        struct session *s = sessionFor(ctx, 0);
        uint8_t all[SMB2_FD_SIZE];
        int index;
        uint32_t generation;
        struct ofile *f;
        memset(all, 0xFF, sizeof all);
        /* the file id of the request before it in a compound request */
        if (!memcmp(id, all, SMB2_FD_SIZE)) {
                if (!s || !s->haveLast)
                        return NULL;
                id = s->lastId;
        }
        index = (id[0] | (id[1] << 8)) - 1;
        generation = id[4] | (id[5] << 8) | (id[6] << 16) | ((uint32_t)id[7] << 24);
        if (index < 0 || index >= MAX_OPEN)
                return NULL;
        f = &files[index];
        if (!f->used || f->owner != ctx || f->generation != generation)
                return NULL;
        return f;
}

/* ---- time ---- */

static uint64_t filetime(time_t sec, long nsec)
{
        return ((uint64_t)sec + 11644473600ULL) * 10000000ULL + (uint64_t)(nsec / 100);
}

#ifdef __APPLE__
#define BIRTH(st) filetime((st).st_ctimespec.tv_sec, (st).st_ctimespec.tv_nsec)   /* the creation time the old systems do not give: the last change of the file */
#define MT(st) filetime((st).st_mtimespec.tv_sec, (st).st_mtimespec.tv_nsec)
#define AT(st) filetime((st).st_atimespec.tv_sec, (st).st_atimespec.tv_nsec)
#define CT(st) filetime((st).st_ctimespec.tv_sec, (st).st_ctimespec.tv_nsec)
#define BT(st) BIRTH(st)
#else
#define MT(st) filetime((st).st_mtim.tv_sec, (st).st_mtim.tv_nsec)
#define AT(st) filetime((st).st_atim.tv_sec, (st).st_atim.tv_nsec)
#define CT(st) filetime((st).st_ctim.tv_sec, (st).st_ctim.tv_nsec)
#define BT(st) filetime((st).st_mtim.tv_sec, (st).st_mtim.tv_nsec)
#endif

static uint32_t attributesOf(const struct stat *st, const char *name)
{
        uint32_t a = S_ISDIR(st->st_mode) ? 0x10 : 0x80;
        if (!(st->st_mode & 0200))
                a |= 0x01;
        if (name && name[0] == '.' && strcmp(name, ".") && strcmp(name, ".."))
                a |= 0x02;
        if (S_ISDIR(st->st_mode))
                a &= ~0x80u;
        return a;
}

static uint64_t allocationOf(const struct stat *st)
{
        return S_ISDIR(st->st_mode) ? 0 : (uint64_t)st->st_blocks * 512;
}

/* ---- little-endian writers and UTF-16 ---- */

static void p16(uint8_t *b, uint16_t v) { b[0] = v & 255; b[1] = v >> 8; }
static void p32(uint8_t *b, uint32_t v) { b[0] = v & 255; b[1] = (v >> 8) & 255; b[2] = (v >> 16) & 255; b[3] = v >> 24; }
static void p64(uint8_t *b, uint64_t v) { p32(b, (uint32_t)v); p32(b + 4, (uint32_t)(v >> 32)); }
static uint32_t g32(const uint8_t *b) { return b[0] | (b[1] << 8) | (b[2] << 16) | ((uint32_t)b[3] << 24); }
static uint64_t g64(const uint8_t *b) { return g32(b) | ((uint64_t)g32(b + 4) << 32); }

/* UTF-8 to UTF-16LE (surrogate pairs included); returns the bytes written, or -1 */
static int toUTF16(const char *s, uint8_t *out, int room)
{
        int n = 0;
        const unsigned char *p = (const unsigned char *)s;
        while (*p) {
                uint32_t c;
                if (*p < 0x80) { c = *p++; }
                else if ((*p & 0xE0) == 0xC0 && (p[1] & 0xC0) == 0x80) { c = ((p[0] & 0x1F) << 6) | (p[1] & 0x3F); p += 2; }
                else if ((*p & 0xF0) == 0xE0 && (p[1] & 0xC0) == 0x80 && (p[2] & 0xC0) == 0x80) { c = ((p[0] & 0x0F) << 12) | ((p[1] & 0x3F) << 6) | (p[2] & 0x3F); p += 3; }
                else if ((*p & 0xF8) == 0xF0 && (p[1] & 0xC0) == 0x80 && (p[2] & 0xC0) == 0x80 && (p[3] & 0xC0) == 0x80) {
                        c = ((p[0] & 0x07) << 18) | ((p[1] & 0x3F) << 12) | ((p[2] & 0x3F) << 6) | (p[3] & 0x3F); p += 4;
                } else { c = 0xFFFD; p++; }
                if (c >= 0x10000) {
                        if (n + 4 > room) return -1;
                        c -= 0x10000;
                        p16(out + n, 0xD800 + (c >> 10)); p16(out + n + 2, 0xDC00 + (c & 0x3FF));
                        n += 4;
                } else {
                        if (n + 2 > room) return -1;
                        p16(out + n, (uint16_t)c);
                        n += 2;
                }
        }
        return n;
}

/* UTF-16LE to a malloc'd UTF-8 string */
static char *fromUTF16(const uint8_t *in, int bytes)
{
        char *out = malloc((size_t)bytes * 2 + 4);
        int i, n = 0;
        if (!out)
                return NULL;
        for (i = 0; i + 1 < bytes; i += 2) {
                uint32_t c = in[i] | (in[i + 1] << 8);
                if (c >= 0xD800 && c < 0xDC00 && i + 3 < bytes) {
                        uint32_t d = in[i + 2] | (in[i + 3] << 8);
                        if (d >= 0xDC00 && d < 0xE000) {
                                c = 0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00);
                                i += 2;
                        }
                }
                if (c < 0x80) out[n++] = (char)c;
                else if (c < 0x800) { out[n++] = (char)(0xC0 | (c >> 6)); out[n++] = (char)(0x80 | (c & 0x3F)); }
                else if (c < 0x10000) { out[n++] = (char)(0xE0 | (c >> 12)); out[n++] = (char)(0x80 | ((c >> 6) & 0x3F)); out[n++] = (char)(0x80 | (c & 0x3F)); }
                else { out[n++] = (char)(0xF0 | (c >> 18)); out[n++] = (char)(0x80 | ((c >> 12) & 0x3F)); out[n++] = (char)(0x80 | ((c >> 6) & 0x3F)); out[n++] = (char)(0x80 | (c & 0x3F)); }
        }
        out[n] = 0;
        return out;
}

/* ---- names: the client's path to a path inside the root ---- */

/* The name as the client gave it ("dir\file", UTF-8) to "dir/file", or NULL when it is not allowed: no "..", no empty or odd parts. */
static char *cleanName(const char *name)
{
        size_t len = name ? strlen(name) : 0, i, n = 0;
        char *out = malloc(len + 1);
        int start = 1;
        if (!out)
                return NULL;
        for (i = 0; i < len; i++) {
                unsigned char c = (unsigned char)name[i];
                if (c == '\\' || c == '/') {
                        if (!start && n && out[n - 1] != '/')
                                out[n++] = '/';
                        start = 1;
                        continue;
                }
                if (c < 0x20 || c == ':' || c == '*' || c == '?' || c == '"' || c == '<' || c == '>' || c == '|') {
                        free(out);
                        return NULL;
                }
                if (start && c == '.') {
                        /* a component that is only dots */
                        size_t j = i;
                        while (j < len && name[j] == '.')
                                j++;
                        if (j == len || name[j] == '\\' || name[j] == '/') {
                                if (j - i == 1) { i = j - 1; start = 1; continue; }   /* "." is nothing */
                                free(out);
                                return NULL;                                                /* ".." and longer */
                        }
                }
                out[n++] = (char)c;
                start = 0;
        }
        while (n && out[n - 1] == '/')
                n--;
        out[n] = 0;
        return out;
}

/* root + "/" + rel, with no symbolic link anywhere along the way; *missingParent is set when a directory on the way does not exist */
static char *fullPath(const char *rel, int *missingParent, int *isLink)
{
        size_t rl = strlen(shareRoot), n = strlen(rel);
        char *path = malloc(rl + n + 2), *p;
        struct stat st;
        *missingParent = 0;
        *isLink = 0;
        if (!path)
                return NULL;
        memcpy(path, shareRoot, rl);
        path[rl] = 0;
        p = path + rl;
        {
                const char *c = rel;
                while (*c) {
                        const char *e = strchr(c, '/');
                        size_t part = e ? (size_t)(e - c) : strlen(c);
                        *p++ = '/';
                        memcpy(p, c, part);
                        p += part;
                        *p = 0;
                        if (lstat(path, &st) == 0) {
                                if (S_ISLNK(st.st_mode)) { *isLink = 1; free(path); return NULL; }
                                if (e && !S_ISDIR(st.st_mode)) { *missingParent = 1; }
                        } else if (e) {
                                *missingParent = 1;
                        }
                        if (!e)
                                break;
                        c = e + 1;
                }
        }
        return path;
}

/* ---- users ---- */

static int findPassword(const char *user, char *password, size_t room)
{
        FILE *f = fopen(usersFile, "r");
        char line[512];
        int found = 0;
        if (!f)
                return 0;
        while (fgets(line, sizeof line, f)) {
                char *colon, *end;
                if (line[0] == '#' || line[0] == '\n')
                        continue;
                end = line + strlen(line);
                while (end > line && (end[-1] == '\n' || end[-1] == '\r'))
                        *--end = 0;
                colon = strchr(line, ':');
                if (!colon)
                        continue;
                *colon = 0;
                if (strcasecmp(line, user) == 0 && strlen(colon + 1) < room && colon[1]) {
                        strcpy(password, colon + 1);
                        found = 1;
                        break;
                }
        }
        fclose(f);
        return found;
}

/* ---- handlers ---- */

static int authorize(struct smb2_server *srvr, struct smb2_context *smb2, const char *user, const char *domain, const char *workstation)
{
        char password[256];
        (void)srvr; (void)domain; (void)workstation;
        if (!user || !user[0] || !findPassword(user, password, sizeof password)) {
                usleep(500000);
                LOG("refused sign-in of \"%s\"", user ? user : "");
                return -1;
        }
        smb2_set_user(smb2, user);
        smb2_set_password(smb2, password);
        memset(password, 0, sizeof password);
        return 0;
}

static int sessionOK(struct smb2_server *srvr, struct smb2_context *smb2)
{
        (void)srvr;
        sessionFor(smb2, 1);
        LOG("signed in (SMB %04x)", smb2_get_dialect(smb2));
        return 0;
}

static int treeConnect(struct smb2_server *srvr, struct smb2_context *smb2, struct smb2_tree_connect_request *req, struct smb2_tree_connect_reply *rep)
{
        char *path = fromUTF16((const uint8_t *)req->path, req->path_length), *last;
        int ok;
        (void)srvr; (void)smb2;
        if (!path)
                return NTERR(ST_BAD_NETWORK_NAME);
        last = strrchr(path, '\\');
        last = last ? last + 1 : path;
        ok = strcasecmp(last, shareName) == 0;
        free(path);
        if (!ok)
                return NTERR(ST_BAD_NETWORK_NAME);
        rep->share_type = SMB2_SHARE_TYPE_DISK;
        rep->share_flags = 0;
        rep->capabilities = 0;
        rep->maximal_access = readOnly ? 0x001200A9 : 0x001F01FF;
        return 0;
}

static int treeDisconnect(struct smb2_server *srvr, struct smb2_context *smb2, const uint32_t tree_id)
{
        (void)srvr; (void)smb2; (void)tree_id;
        return 0;
}

static int logoff(struct smb2_server *srvr, struct smb2_context *smb2)
{
        (void)srvr; (void)smb2;
        return 0;
}

static int destroyed(struct smb2_server *srvr, struct smb2_context *smb2)
{
        int i;
        struct session *s = sessionFor(smb2, 0);
        (void)srvr;
        for (i = 0; i < MAX_OPEN; i++)
                if (files[i].used && files[i].owner == smb2)
                        releaseFile(&files[i]);
        if (s)
                s->ctx = NULL;
        return 0;
}

static int errnoStatus(int e)
{
        switch (e) {
        case ENOENT: return NTERR(ST_NAME_NOT_FOUND);
        case EEXIST: return NTERR(ST_NAME_COLLISION);
        case EACCES: case EPERM: return NTERR(ST_ACCESS_DENIED);
        case EISDIR: return NTERR(ST_FILE_IS_DIR);
        case ENOTDIR: return NTERR(ST_NOT_A_DIR);
        case ENOTEMPTY: return NTERR(ST_DIR_NOT_EMPTY);
        case ENOSPC: case EDQUOT: return NTERR(ST_DISK_FULL);
        case EROFS: return NTERR(ST_MEDIA_PROTECTED);
        case EBUSY: return NTERR(ST_SHARING_VIOLATION);
        default: return NTERR(ST_IO_ERROR);
        }
}

static void remember(struct smb2_context *smb2, int index)
{
        struct session *s = sessionFor(smb2, 1);
        if (s) {
                putId(s->lastId, index, files[index].generation);
                s->haveLast = 1;
        }
}

static int create(struct smb2_server *srvr, struct smb2_context *smb2, struct smb2_create_request *req, struct smb2_create_reply *rep)
{
        static uint32_t generations = 1000;
        char *rel = cleanName(req->name), *path = NULL;
        int missingParent = 0, isLink = 0, exists, isdir = 0, i, fd = -1, created = 0, truncated = 0, index = -1, status = 0;
        uint32_t disposition = req->create_disposition, options = req->create_options;
        struct stat st;
        int wantWrite;
        (void)srvr;
        if (!rel)
                return NTERR(ST_OBJECT_NAME_INVALID);
        path = fullPath(rel, &missingParent, &isLink);
        if (!path) {
                free(rel);
                return NTERR(isLink ? ST_ACCESS_DENIED : ST_IO_ERROR);
        }
        exists = lstat(path, &st) == 0 && !missingParent;
        if (exists && S_ISLNK(st.st_mode))
                exists = 0, status = NTERR(ST_ACCESS_DENIED);
        if (status)
                goto fail;
        if (exists && !S_ISDIR(st.st_mode) && !S_ISREG(st.st_mode)) {
                status = NTERR(ST_ACCESS_DENIED);
                goto fail;
        }
        isdir = exists ? S_ISDIR(st.st_mode) : (options & 0x1) != 0;
        wantWrite = (req->desired_access & (0x2 | 0x4 | 0x10 | 0x100 | 0x10000 | 0x40000000 | 0x10000000)) != 0;
        if (exists && (options & 0x1) && !S_ISDIR(st.st_mode)) { status = NTERR(ST_NOT_A_DIR); goto fail; }
        if (exists && (options & 0x40) && S_ISDIR(st.st_mode)) { status = NTERR(ST_FILE_IS_DIR); goto fail; }
        switch (disposition) {
        case 1: /* open */ case 4: /* overwrite */
                if (!exists) { status = NTERR(missingParent ? ST_PATH_NOT_FOUND : ST_NAME_NOT_FOUND); goto fail; }
                break;
        case 2: /* create */
                if (exists) { status = NTERR(ST_NAME_COLLISION); goto fail; }
                break;
        case 0: case 3: case 5:
                break;
        default:
                status = NTERR(ST_INVALID_PARAMETER);
                goto fail;
        }
        if (!exists && missingParent) { status = NTERR(ST_PATH_NOT_FOUND); goto fail; }
        if (!exists && !rel[0]) { status = NTERR(ST_NAME_NOT_FOUND); goto fail; }
        /* what changes things is refused on a share that is read only */
        if (readOnly && (!exists || disposition == 0 || disposition == 4 || disposition == 5 || (options & 0x1000))) { status = NTERR(ST_ACCESS_DENIED); goto fail; }
        for (i = 0; i < MAX_OPEN; i++)
                if (!files[i].used) { index = i; break; }
        if (index < 0) { status = NTERR(ST_IO_ERROR); goto fail; }
        if (!exists) {
                if (isdir) {
                        if (mkdir(path, 0777) != 0) { status = errnoStatus(errno); goto fail; }
                } else {
                        fd = open(path, O_RDWR | O_CREAT | O_EXCL, 0666);
                        if (fd < 0) { status = errnoStatus(errno); goto fail; }
                }
                created = 1;
        } else if (!isdir) {
                int flags = (wantWrite && !readOnly) ? O_RDWR : O_RDONLY;
                if (disposition == 0 || disposition == 4 || disposition == 5) {
                        flags = O_RDWR | O_TRUNC;
                        truncated = 1;
                }
                fd = open(path, flags);
                if (fd < 0 && (flags & O_RDWR) && !(flags & O_TRUNC) && errno == EACCES) {
                        fd = open(path, O_RDONLY);   /* a file the account can only read: the client sees it as read only */
                }
                if (fd < 0) { status = errnoStatus(errno); goto fail; }
        }
        if (isdir || !created) {
                if (isdir) {
                        /* a directory is held by its path; listing opens it when asked */
                        fd = -1;
                }
        }
        if (lstat(path, &st) != 0) { status = errnoStatus(errno); if (fd >= 0) close(fd); goto fail; }
        files[index].used = 1;
        files[index].generation = generations++;
        files[index].owner = smb2;
        files[index].fd = fd;
        files[index].path = path;
        files[index].rel = rel;
        files[index].isdir = S_ISDIR(st.st_mode);
        files[index].deleteOnClose = (options & 0x1000) != 0;
        files[index].writable = !readOnly;
        files[index].names = NULL;
        files[index].nnames = files[index].next = 0;
        files[index].pattern = NULL;
        rep->oplock_level = 0;
        rep->flags = 0;
        rep->create_action = created ? 2 : (truncated ? (disposition == 0 ? 0 : 3) : 1);
        rep->creation_time = BT(st);
        rep->last_access_time = AT(st);
        rep->last_write_time = MT(st);
        rep->change_time = CT(st);
        rep->allocation_size = allocationOf(&st);
        rep->end_of_file = S_ISDIR(st.st_mode) ? 0 : (uint64_t)st.st_size;
        rep->file_attributes = attributesOf(&st, strrchr(rel, '/') ? strrchr(rel, '/') + 1 : rel);
        putId(rep->file_id, index, files[index].generation);
        remember(smb2, index);
        LOG("open %s%s", rel[0] ? rel : "(root)", created ? " (new)" : "");
        return 0;
fail:
        free(path);
        free(rel);
        return status ? status : NTERR(ST_IO_ERROR);
}

static int doClose(struct smb2_context *smb2, struct ofile *f, struct smb2_close_reply *rep, int wantInfo)
{
        struct stat st;
        int have = f->path && lstat(f->path, &st) == 0;
        if (rep && wantInfo && have) {
                rep->flags = SMB2_CLOSE_FLAG_POSTQUERY_ATTRIB;
                rep->creation_time = BT(st);
                rep->last_access_time = AT(st);
                rep->last_write_time = MT(st);
                rep->change_time = CT(st);
                rep->allocation_size = allocationOf(&st);
                rep->end_of_file = S_ISDIR(st.st_mode) ? 0 : (uint64_t)st.st_size;
                rep->file_attributes = attributesOf(&st, NULL);
        }
        if (f->deleteOnClose && !readOnly && have) {
                if (f->isdir)
                        rmdir(f->path);
                else
                        unlink(f->path);
        }
        (void)smb2;
        releaseFile(f);
        return 0;
}

static int closeFile(struct smb2_server *srvr, struct smb2_context *smb2, struct smb2_close_request *req, struct smb2_close_reply *rep)
{
        struct ofile *f = lookup(smb2, req->file_id);
        (void)srvr;
        if (!f)
                return NTERR(ST_INVALID_HANDLE);
        return doClose(smb2, f, rep, (req->flags & SMB2_CLOSE_FLAG_POSTQUERY_ATTRIB) != 0);
}

static int flushFile(struct smb2_server *srvr, struct smb2_context *smb2, struct smb2_flush_request *req)
{
        struct ofile *f = lookup(smb2, req->file_id);
        (void)srvr;
        if (!f)
                return NTERR(ST_INVALID_HANDLE);
        if (f->fd >= 0)
                fsync(f->fd);
        return 0;
}

static int readFile(struct smb2_server *srvr, struct smb2_context *smb2, struct smb2_read_request *req, struct smb2_read_reply *rep)
{
        struct ofile *f = lookup(smb2, req->file_id);
        uint32_t want;
        ssize_t got;
        uint8_t *data;
        (void)srvr;
        if (!f || f->fd < 0)
                return NTERR(f ? ST_FILE_IS_DIR : ST_INVALID_HANDLE);
        want = req->length > MAX_IO ? MAX_IO : req->length;
        if (want == 0)
                return 0;
        data = malloc(want);
        if (!data)
                return NTERR(ST_IO_ERROR);
        got = pread(f->fd, data, want, (off_t)req->offset);
        if (got < 0) {
                int e = errno;
                free(data);
                return errnoStatus(e);
        }
        if (got == 0) {
                free(data);
                return NTERR(0xC0000011);   /* end of file */
        }
        rep->data = data;
        rep->data_length = (uint32_t)got;
        rep->data_remaining = 0;
        return 0;
}

static int writeFile(struct smb2_server *srvr, struct smb2_context *smb2, struct smb2_write_request *req, struct smb2_write_reply *rep)
{
        struct ofile *f = lookup(smb2, req->file_id);
        ssize_t put;
        (void)srvr;
        if (!f || f->fd < 0)
                return NTERR(f ? ST_FILE_IS_DIR : ST_INVALID_HANDLE);
        if (readOnly || !f->writable)
                return NTERR(ST_ACCESS_DENIED);
        put = pwrite(f->fd, req->buf, req->length, (off_t)req->offset);
        if (put < 0)
                return errnoStatus(errno);
        rep->count = (uint32_t)put;
        rep->remaining = 0;
        return 0;
}

static int lockFile(struct smb2_server *srvr, struct smb2_context *smb2, struct smb2_lock_request *req)
{
        (void)srvr; (void)smb2; (void)req;
        return 0;
}

static int ioctl_(struct smb2_server *srvr, struct smb2_context *smb2, struct smb2_ioctl_request *req, struct smb2_ioctl_reply *rep)
{
        (void)srvr; (void)smb2; (void)req; (void)rep;
        return NTERR(ST_NOT_SUPPORTED);
}

static int cancel(struct smb2_server *srvr, struct smb2_context *smb2) { (void)srvr; (void)smb2; return 0; }
static int echo(struct smb2_server *srvr, struct smb2_context *smb2) { (void)srvr; (void)smb2; return 0; }

static int changeNotify(struct smb2_server *srvr, struct smb2_context *smb2, struct smb2_change_notify_request *req, struct smb2_change_notify_reply *rep)
{
        (void)srvr; (void)smb2; (void)req; (void)rep;
        return NTERR(ST_NOT_SUPPORTED);
}

/* ---- directory listings ---- */

/* The DOS wildcards ("*", "?", "<", ">", """) against a name, ignoring case. */
static int wildMatch(const char *pat, const char *name)
{
        for (; *pat; pat++) {
                if (*pat == '*' || *pat == '<') {
                        while (pat[1] == '*' || pat[1] == '<')
                                pat++;
                        if (!pat[1])
                                return 1;
                        for (; *name; name++)
                                if (wildMatch(pat + 1, name))
                                        return 1;
                        return wildMatch(pat + 1, name);
                }
                if (*name == 0)
                        return 0;
                if (*pat == '?' || *pat == '>') { name++; continue; }
                if (*pat == '"') { if (*name != '.') return 0; name++; continue; }
                if (tolower((unsigned char)*pat) != tolower((unsigned char)*name))
                        return 0;
                name++;
        }
        return *name == 0;
}

static void readListing(struct ofile *f, const char *pattern)
{
        DIR *d;
        struct dirent *e;
        int cap = 64;
        freeNames(f);
        free(f->pattern);
        f->pattern = strdup(pattern && pattern[0] ? pattern : "*");
        f->names = malloc(sizeof(char *) * cap);
        if (!f->names)
                return;
        if (wildMatch(f->pattern, "."))
                f->names[f->nnames++] = strdup(".");
        if (wildMatch(f->pattern, ".."))
                f->names[f->nnames++] = strdup("..");
        d = opendir(f->path);
        while (d && (e = readdir(d))) {
                if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
                        continue;
                if (!wildMatch(f->pattern, e->d_name))
                        continue;
                if (f->nnames == cap) {
                        char **bigger = realloc(f->names, sizeof(char *) * (cap *= 2));
                        if (!bigger)
                                break;
                        f->names = bigger;
                }
                f->names[f->nnames++] = strdup(e->d_name);
        }
        if (d)
                closedir(d);
        f->next = 0;
}

static uint8_t *scratch;
static size_t scratchRoom;

static uint8_t *scratchBuffer(size_t n)
{
        if (n > scratchRoom) {
                free(scratch);
                scratch = malloc(n);
                scratchRoom = scratch ? n : 0;
        }
        return scratch;
}

static int queryDirectory(struct smb2_server *srvr, struct smb2_context *smb2, struct smb2_query_directory_request *req, struct smb2_query_directory_reply *rep)
{
        struct ofile *f = lookup(smb2, req->file_id);
        uint8_t *out;
        size_t used = 0, room = req->output_buffer_length, prevStart = 0;
        int single = (req->flags & 0x02) != 0, restart = (req->flags & 0x01) != 0, count = 0;
        int cls = req->file_information_class;
        int nameAt;
        (void)srvr;
        if (!f)
                return NTERR(ST_INVALID_HANDLE);
        if (!f->isdir)
                return NTERR(ST_NOT_A_DIR);
        switch (cls) {
        case 1: nameAt = 64; break;     /* FileDirectoryInformation */
        case 2: nameAt = 68; break;     /* FileFullDirectoryInformation */
        case 3: nameAt = 94; break;     /* FileBothDirectoryInformation */
        case 12: nameAt = 12; break;    /* FileNamesInformation */
        case 37: nameAt = 104; break;   /* FileIdBothDirectoryInformation */
        case 38: nameAt = 80; break;    /* FileIdFullDirectoryInformation */
        default: return NTERR(ST_INVALID_INFO);
        }
        if (restart || !f->names || ((req->flags & 0x10) != 0))
                readListing(f, req->name);
        else if (req->name && req->name[0] && f->pattern && strcmp(req->name, f->pattern) && f->next == 0)
                readListing(f, req->name);
        if (room > MAX_IO)
                room = MAX_IO;
        out = scratchBuffer(room + 8);
        if (!out)
                return NTERR(ST_IO_ERROR);
        while (f->next < f->nnames) {
                const char *name = f->names[f->next];
                uint8_t u16[1024];
                int nlen = toUTF16(name, u16, sizeof u16);
                size_t entry, padded;
                char *child;
                struct stat st;
                uint8_t *e;
                if (nlen < 0) { f->next++; continue; }
                entry = (size_t)nameAt + (size_t)nlen;
                padded = (entry + 7) & ~(size_t)7;
                if (used + padded > room) {
                        if (count == 0)
                                return NTERR(0xC0000023);   /* buffer too small: not even one entry fits */
                        break;
                }
                child = malloc(strlen(f->path) + strlen(name) + 2);
                if (!child) break;
                sprintf(child, "%s/%s", f->path, name);
                if (!strcmp(name, ".")) strcpy(child, f->path);
                if (!strcmp(name, "..")) sprintf(child, "%s/..", f->path);
                if (lstat(child, &st) != 0 || S_ISLNK(st.st_mode)) {
                        free(child);
                        f->next++;
                        continue;      /* gone meanwhile, or a link, which is not shown */
                }
                free(child);
                e = out + used;
                memset(e, 0, padded);
                if (cls == 12) {
                        p32(e + 8, (uint32_t)nlen);
                } else {
                        p32(e + 4, (uint32_t)(f->next));
                        p64(e + 8, BT(st)); p64(e + 16, AT(st)); p64(e + 24, MT(st)); p64(e + 32, CT(st));
                        p64(e + 40, S_ISDIR(st.st_mode) ? 0 : (uint64_t)st.st_size);
                        p64(e + 48, allocationOf(&st));
                        p32(e + 56, attributesOf(&st, name));
                        p32(e + 60, (uint32_t)nlen);
                        if (cls == 37) p64(e + 96, (uint64_t)st.st_ino);
                        if (cls == 38) p64(e + 72, (uint64_t)st.st_ino);
                }
                memcpy(e + nameAt, u16, (size_t)nlen);
                if (count > 0)
                        p32(out + prevStart, (uint32_t)(used - prevStart));
                prevStart = used;
                used += padded;
                count++;
                f->next++;
                if (single)
                        break;
        }
        if (count == 0) {
                rep->output_buffer = NULL;
                rep->output_buffer_length = 0;     /* the library answers: no more files */
                return 0;
        }
        rep->output_buffer = out;
        rep->output_buffer_length = (uint32_t)used;
        return 0;
}

/* ---- file and file system information ---- */

static int putName(uint8_t *out, size_t room, const char *rel)
{
        uint8_t u16[1024];
        char *with = malloc(strlen(rel) + 2), *c;
        int n;
        if (!with)
                return -1;
        sprintf(with, "\\%s", rel);
        for (c = with; *c; c++)
                if (*c == '/')
                        *c = '\\';
        n = toUTF16(with, u16, sizeof u16);
        free(with);
        if (n < 0 || (size_t)n + 4 > room)
                return -1;
        p32(out, (uint32_t)n);
        memcpy(out + 4, u16, (size_t)n);
        return n + 4;
}

static int queryInfo(struct smb2_server *srvr, struct smb2_context *smb2, struct smb2_query_info_request *req, struct smb2_query_info_reply *rep)
{
        struct ofile *f = lookup(smb2, req->file_id);
        struct stat st;
        uint8_t *o;
        size_t n = 0;
        int cls = req->file_info_class;
        const char *base;
        (void)srvr;
        if (!f)
                return NTERR(ST_INVALID_HANDLE);
        if (lstat(f->path, &st) != 0)
                return errnoStatus(errno);
        base = strrchr(f->rel, '/') ? strrchr(f->rel, '/') + 1 : f->rel;
        o = scratchBuffer(2048);
        if (!o)
                return NTERR(ST_IO_ERROR);
        memset(o, 0, 2048);
        if (req->info_type == 1) {       /* SMB2_0_INFO_FILE */
                int all = cls == 18;
                if (cls == 4 || all) {
                        p64(o, BT(st)); p64(o + 8, AT(st)); p64(o + 16, MT(st)); p64(o + 24, CT(st)); p32(o + 32, attributesOf(&st, base));
                        n = 40;
                }
                if (cls == 5 || all) {
                        uint8_t *s = o + n;
                        p64(s, allocationOf(&st)); p64(s + 8, S_ISDIR(st.st_mode) ? 0 : (uint64_t)st.st_size);
                        p32(s + 16, (uint32_t)(st.st_nlink ? st.st_nlink : 1)); s[20] = f->deleteOnClose; s[21] = S_ISDIR(st.st_mode);
                        n += 24;
                }
                if (all) {
                        int nm;
                        p64(o + n, (uint64_t)st.st_ino); n += 8;
                        p32(o + n, 0); n += 4;                 /* EA size */
                        p32(o + n, 0x001F01FF); n += 4;        /* access */
                        p64(o + n, 0); n += 8;                 /* position */
                        p32(o + n, 0); n += 4;                 /* mode */
                        p32(o + n, 0); n += 4;                 /* alignment */
                        nm = putName(o + n, 2048 - n, f->rel);
                        if (nm < 0)
                                return NTERR(ST_IO_ERROR);
                        n += (size_t)nm;
                } else switch (cls) {
                case 4: case 5: break;
                case 6: p64(o, (uint64_t)st.st_ino); n = 8; break;
                case 7: p32(o, 0); n = 4; break;
                case 8: p32(o, 0x001F01FF); n = 4; break;
                case 9: { int nm = putName(o, 2048, f->rel); if (nm < 0) return NTERR(ST_IO_ERROR); n = (size_t)nm; break; }
                case 14: n = 8; break;
                case 16: n = 4; break;
                case 17: n = 4; break;
                case 34:
                        p64(o, BT(st)); p64(o + 8, AT(st)); p64(o + 16, MT(st)); p64(o + 24, CT(st));
                        p64(o + 32, allocationOf(&st)); p64(o + 40, S_ISDIR(st.st_mode) ? 0 : (uint64_t)st.st_size); p32(o + 48, attributesOf(&st, base));
                        n = 56;
                        break;
                case 35: p32(o, attributesOf(&st, base)); p32(o + 4, 0); n = 8; break;
                default:
                        return NTERR(ST_INVALID_INFO);
                }
        } else if (req->info_type == 2) {   /* SMB2_0_INFO_FILESYSTEM */
                struct statfs sf;
                uint64_t unit = 4096, total = 0, avail = 0;
                if (statfs(shareRoot, &sf) == 0) {
                        unit = sf.f_bsize ? sf.f_bsize : 4096;
                        total = sf.f_blocks;
                        avail = sf.f_bavail;
                }
                switch (cls) {
                case 1: {   /* volume */
                        uint8_t lab[128];
                        int ln = toUTF16(shareName, lab, sizeof lab);
                        p64(o, BT(st)); p32(o + 8, 0x54424B31); p32(o + 12, (uint32_t)ln); o[16] = 0;
                        memcpy(o + 18, lab, (size_t)ln);
                        n = 18 + (size_t)ln;
                        break; }
                case 3: p64(o, total); p64(o + 8, avail); p32(o + 16, (uint32_t)(unit / 512)); p32(o + 20, 512); n = 24; break;
                case 4: p32(o, 7); p32(o + 4, readOnly ? 0x20 : 0); n = 8; break;
                case 5: {   /* attributes */
                        uint8_t nm[32];
                        int ln = toUTF16("NTFS", nm, sizeof nm);
                        p32(o, 0x00000006 | (readOnly ? 0x00080000 : 0)); p32(o + 4, 255); p32(o + 8, (uint32_t)ln);
                        memcpy(o + 12, nm, (size_t)ln);
                        n = 12 + (size_t)ln;
                        break; }
                case 6: p32(o + 40, 0); n = 48; break;
                case 7: p64(o, total); p64(o + 8, avail); p64(o + 16, avail); p32(o + 24, (uint32_t)(unit / 512)); p32(o + 28, 512); n = 32; break;
                case 11: p32(o, 512); p32(o + 4, 4096); p32(o + 8, 4096); p32(o + 12, 4096); p32(o + 16, 0); n = 28; break;
                default:
                        return NTERR(ST_INVALID_INFO);
                }
        } else if (req->info_type == 3) {   /* SMB2_0_INFO_SECURITY: everyone may do everything the share allows */
                static const uint8_t sd[48] = {1, 0, 0x04, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 20, 0, 0, 0,
                        2, 0, 28, 0, 1, 0, 0, 0,
                        0, 0, 20, 0, 0xFF, 0x01, 0x1F, 0x00, 1, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0};
                memcpy(o, sd, 48);
                n = 48;
        } else {
                return NTERR(ST_INVALID_INFO);
        }
        rep->output_buffer = o;
        rep->output_buffer_length = (uint32_t)n;
        return 0;
}

static int setInfo(struct smb2_server *srvr, struct smb2_context *smb2, struct smb2_set_info_request *req)
{
        struct ofile *f = lookup(smb2, req->file_id);
        const uint8_t *d = req->input_data;
        uint32_t len = req->buffer_length;
        (void)srvr;
        if (!f)
                return NTERR(ST_INVALID_HANDLE);
        if (req->info_type == 3)
                return 0;                           /* security descriptors are accepted and ignored */
        if (req->info_type != 1)
                return NTERR(ST_INVALID_INFO);
        switch (req->file_info_class) {
        case 4: {   /* basic: times */
                struct timeval tv[2];
                struct stat st;
                uint64_t a, m;
                if (len < 36)
                        return NTERR(ST_INVALID_PARAMETER);
                if (readOnly)
                        return NTERR(ST_ACCESS_DENIED);
                a = g64(d + 8); m = g64(d + 16);
                if (lstat(f->path, &st) != 0)
                        return errnoStatus(errno);
                tv[0].tv_sec = st.st_atime; tv[0].tv_usec = 0;
                tv[1].tv_sec = st.st_mtime; tv[1].tv_usec = 0;
                if (a && a != ~(uint64_t)0 && a >= 116444736000000000ULL) tv[0].tv_sec = (time_t)((a - 116444736000000000ULL) / 10000000ULL);
                if (m && m != ~(uint64_t)0 && m >= 116444736000000000ULL) tv[1].tv_sec = (time_t)((m - 116444736000000000ULL) / 10000000ULL);
                utimes(f->path, tv);
                return 0; }
        case 10: case 65: {   /* rename */
                uint32_t nlen;
                char *name, *rel, *dest;
                int missing, link, replace = d && len > 0 && d[0] != 0;
                struct stat st;
                if (readOnly)
                        return NTERR(ST_ACCESS_DENIED);
                if (len < 20)
                        return NTERR(ST_INVALID_PARAMETER);
                nlen = g32(d + 16);
                if (nlen > len - 20)
                        return NTERR(ST_INVALID_PARAMETER);
                name = fromUTF16(d + 20, (int)nlen);
                if (!name)
                        return NTERR(ST_IO_ERROR);
                rel = cleanName(name);
                free(name);
                if (!rel || !rel[0]) { free(rel); return NTERR(ST_OBJECT_NAME_INVALID); }
                dest = fullPath(rel, &missing, &link);
                if (!dest || missing) { free(rel); free(dest); return NTERR(link ? ST_ACCESS_DENIED : ST_PATH_NOT_FOUND); }
                if (lstat(dest, &st) == 0 && !replace) { free(rel); free(dest); return NTERR(ST_NAME_COLLISION); }
                if (rename(f->path, dest) != 0) {
                        int e = errno;
                        free(rel); free(dest);
                        return errnoStatus(e);
                }
                free(f->path); free(f->rel);
                f->path = dest; f->rel = rel;
                return 0; }
        case 13: case 64: {   /* delete on close */
                int del = len > 0 && (req->file_info_class == 13 ? d[0] != 0 : (g32(d) & 1) != 0);
                if (del && readOnly)
                        return NTERR(ST_ACCESS_DENIED);
                if (del && f->isdir) {
                        DIR *dir = opendir(f->path);
                        struct dirent *e;
                        while (dir && (e = readdir(dir)))
                                if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) { closedir(dir); return NTERR(ST_DIR_NOT_EMPTY); }
                        if (dir) closedir(dir);
                }
                f->deleteOnClose = del;
                return 0; }
        case 20: {   /* end of file */
                if (len < 8)
                        return NTERR(ST_INVALID_PARAMETER);
                if (readOnly || f->fd < 0)
                        return NTERR(ST_ACCESS_DENIED);
                if (ftruncate(f->fd, (off_t)g64(d)) != 0)
                        return errnoStatus(errno);
                return 0; }
        case 19: case 14: case 16:   /* allocation, position, mode */
                return 0;
        default:
                return NTERR(ST_INVALID_INFO);
        }
}

static struct smb2_server_request_handlers handlers = {
        destroyed,
        authorize,
        sessionOK,
        logoff,
        treeConnect,
        treeDisconnect,
        create,
        closeFile,
        flushFile,
        readFile,
        writeFile,
        NULL,
        NULL,
        lockFile,
        ioctl_,
        cancel,
        echo,
        queryDirectory,
        changeNotify,
        queryInfo,
        setInfo
};

static struct smb2_server server;

static void onError(struct smb2_context *smb2, const char *text)
{
        (void)smb2;
        if (text && logging)
                fprintf(stderr, "libsmb2: %s\n", text);
}

static void onClient(struct smb2_context *smb2, void *data)
{
        (void)data;
        smb2_set_version(smb2, SMB2_VERSION_ANY);
        smb2_set_passthrough(smb2, 1);        /* the replies are built here, in the wire format */
        smb2_register_error_callback(smb2, onError);
        sessionFor(smb2, 1);
        LOG("a computer connected");
}

static void stop(int sig)
{
        (void)sig;
        server.stop_requested = 1;
}

int main(int argc, char **argv)
{
        int i, listenFd = 0, err;
        long port = 445;
        char resolved[1024];
        for (i = 1; i < argc; i++) {
                if (!strcmp(argv[i], "--root") && i + 1 < argc) shareRoot = argv[++i];
                else if (!strcmp(argv[i], "--share") && i + 1 < argc) shareName = argv[++i];
                else if (!strcmp(argv[i], "--users") && i + 1 < argc) usersFile = argv[++i];
                else if (!strcmp(argv[i], "--port") && i + 1 < argc) port = strtol(argv[++i], NULL, 10);
                else if (!strcmp(argv[i], "--readonly")) readOnly = 1;
                else if (!strcmp(argv[i], "--listen-fd")) listenFd = 1;
                else if (!strcmp(argv[i], "--log")) logging = 1;
                else { fprintf(stderr, "usage: tbsmbd --root FOLDER --share NAME --users FILE [--port N] [--readonly] [--listen-fd] [--log]\n"); return 2; }
        }
        if (!shareRoot || !shareName || !usersFile || port < 1 || port > 65535) {
                fprintf(stderr, "usage: tbsmbd --root FOLDER --share NAME --users FILE [--port N] [--readonly] [--listen-fd] [--log]\n");
                return 2;
        }
        if (!realpath(shareRoot, resolved) || strlen(resolved) < 2) {
                fprintf(stderr, "tbsmbd: %s is not a folder\n", shareRoot);
                return 1;
        }
        shareRoot = strdup(resolved);
        {
                struct stat st;
                if (stat(usersFile, &st) != 0 || (st.st_mode & 077)) {
                        fprintf(stderr, "tbsmbd: %s must exist and be readable by its owner only (chmod 600)\n", usersFile);
                        return 1;
                }
        }
        for (i = 0; i < MAX_OPEN; i++)
                files[i].fd = -1;
        signal(SIGPIPE, SIG_IGN);
        signal(SIGTERM, stop);
        signal(SIGINT, stop);
        memset(&server, 0, sizeof server);
        server.handlers = &handlers;
        server.signing_enabled = 1;
        server.allow_anonymous = 0;
        server.port = (uint16_t)port;
        server.max_transact_size = MAX_IO;
        server.max_read_size = MAX_IO;
        server.max_write_size = MAX_IO;
        if (listenFd) {
                /* launchd hands the bound socket over as standard input; libsmb2 takes a descriptor above 2 */
                if (dup2(0, 3) < 0) { perror("tbsmbd: dup2"); return 1; }
                server.fd = 3;
        }
        err = smb2_serve_port(&server, 16, onClient, NULL);
        if (err) {
                fprintf(stderr, "tbsmbd: stopped (%d)%s\n", err, err == -EADDRINUSE ? ": the port is in use (is File Sharing on?)" : "");
                return 1;
        }
        return 0;
}
