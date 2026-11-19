/* FreeType's portable ftsystem.c, with font files through ZDOS's
   handles, not the C library's FILE streams: FREETYPE.ZDL is one copy
   for every program, and a handle is the calling program's (closed when
   it ends). A file is read into memory once when opened (as
   builds/unix's mmap does), not at every access: each of those was a
   read from the disk. Files over FT_ZDOS_WHOLE_MAX bytes, or without
   the memory, are read from the handle. */
#define FT_Stream_Open ft_stream_open_ansi
#include "ftsystem.c"
#undef FT_Stream_Open

#include "zdos.h"

#define FT_ZDOS_WHOLE_MAX (4L << 20)

FT_CALLBACK_DEF(void)
ft_zdos_stream_close(FT_Stream stream)
{
    ft_sfree(stream->base);
    stream->base = NULL;
    stream->size = 0;
    stream->descriptor.pointer = NULL;
}

FT_CALLBACK_DEF(void)
ft_zdos_handle_close(FT_Stream stream)
{
    zdos->files->close((int32_t)stream->descriptor.value);
    stream->descriptor.value = -1;
    stream->size = 0;
}

/* count 0: a seek, 0 if it worked */
FT_CALLBACK_DEF(unsigned long)
ft_zdos_handle_read(FT_Stream stream, unsigned long offset, unsigned char *buffer, unsigned long count)
{
    int32_t h = (int32_t)stream->descriptor.value;
    if (!zdos->files->seek(h, offset))
        return count ? 0 : 1;
    if (!count)
        return 0;
    int64_t n = zdos->files->read(h, buffer, count);
    return n > 0 ? (unsigned long)n : 0;
}

FT_BASE_DEF(FT_Error)
FT_Stream_Open(FT_Stream stream, const char *filepathname)
{
    if (!stream)
        return FT_THROW(Invalid_Stream_Handle);
    int32_t h = zdos->files->open(filepathname, ft_strlen(filepathname), ZDOS_READ);
    if (h < 0)
        return FT_THROW(Cannot_Open_Resource);
    int64_t size = zdos->files->size(h);
    if (size <= 0) {
        zdos->files->close(h);
        return FT_THROW(Cannot_Open_Stream);
    }
    stream->pathname.pointer = (char *)filepathname;
    stream->size = (unsigned long)size;
    stream->pos = 0;
    unsigned char *base = size <= FT_ZDOS_WHOLE_MAX ? (unsigned char *)ft_smalloc((size_t)size) : NULL;
    if (base && zdos->files->read(h, base, (size_t)size) == size) {
        zdos->files->close(h);
        stream->descriptor.pointer = NULL;
        stream->base = base;
        stream->read = NULL;
        stream->close = ft_zdos_stream_close;
        return FT_Err_Ok;
    }
    ft_sfree(base);
    stream->descriptor.value = h;
    stream->base = NULL;
    stream->read = ft_zdos_handle_read;
    stream->close = ft_zdos_handle_close;
    return FT_Err_Ok;
}
