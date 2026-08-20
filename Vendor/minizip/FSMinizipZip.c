/*
 * The bundled minizip writer is built with private symbol names so it cannot
 * bind to Filza's incomplete, separately compiled minizip implementation.
 * Upstream license: ZLIB-LICENSE.txt in this directory.
 */

#define call_ztell64 FSMinizip_call_ztell64
#define fill_zlib_filefunc64_32_def_from_filefunc32 \
    FSMinizip_fill_zlib_filefunc64_32_def_from_filefunc32
#define fill_fopen_filefunc FSMinizip_fill_fopen_filefunc
#define fill_fopen64_filefunc FSMinizip_fill_fopen64_filefunc

#define zipAlreadyThere FSMinizip_zipAlreadyThere
#define zipOpen3 FSMinizip_zipOpen3
#define zipOpen2 FSMinizip_zipOpen2
#define zipOpen2_64 FSMinizip_zipOpen2_64
#define zipOpen FSMinizip_zipOpen
#define zipOpen64 FSMinizipOpen64
#define zipOpenNewFileInZip4_64 FSMinizip_zipOpenNewFileInZip4_64
#define zipOpenNewFileInZip4 FSMinizip_zipOpenNewFileInZip4
#define zipOpenNewFileInZip3 FSMinizip_zipOpenNewFileInZip3
#define zipOpenNewFileInZip3_64 FSMinizip_zipOpenNewFileInZip3_64
#define zipOpenNewFileInZip2 FSMinizip_zipOpenNewFileInZip2
#define zipOpenNewFileInZip2_64 FSMinizip_zipOpenNewFileInZip2_64
#define zipOpenNewFileInZip64 FSMinizipOpenNewFile64
#define zipOpenNewFileInZip FSMinizip_zipOpenNewFileInZip
#define zipWriteInFileInZip FSMinizipWrite
#define zipCloseFileInZipRaw FSMinizip_zipCloseFileInZipRaw
#define zipCloseFileInZipRaw64 FSMinizip_zipCloseFileInZipRaw64
#define zipCloseFileInZip FSMinizipCloseFile
#define zipClose FSMinizipClose
#define zipRemoveExtraInfoBlock FSMinizip_zipRemoveExtraInfoBlock

#include "ioapi.c"
#include "zip.c"
