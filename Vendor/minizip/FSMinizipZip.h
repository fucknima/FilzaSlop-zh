#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef void *FSMinizipFile;

FSMinizipFile FSMinizipOpen64(const void *path, int append);
int FSMinizipOpenNewFile64(FSMinizipFile file, const char *filename,
    const void *zipInfo, const void *localExtra, unsigned localExtraSize,
    const void *globalExtra, unsigned globalExtraSize, const char *comment,
    int method, int level, int zip64);
int FSMinizipWrite(FSMinizipFile file, const void *buffer, unsigned length);
int FSMinizipCloseFile(FSMinizipFile file);
int FSMinizipClose(FSMinizipFile file, const char *globalComment);

#ifdef __cplusplus
}
#endif
