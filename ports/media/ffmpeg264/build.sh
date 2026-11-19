#!/usr/bin/env bash
# FFMPEG 9 (GPL, WITH x264, LAME AND WebP): FFMPEG9.ZDL, FFPROBE.APP,
# FFMPEG.APP, FFPLAY.APP, the headers, and libav*.a, libsw*.a stubs.
#   build.sh [x86|x86_64|arm64]...   (none: all three)
# Sources: FFMPEG_SRC=... (its tag TAG exported) or a release tree,
# patched with ffmpeg-zdos.patch in build/ffmpeg/src.
echo "=== FFmpeg x264 ==="
source "$(dirname "$0")/../../common.sh"
PORT=$ZIGDOS/ports/media/ffmpeg264
FFMPEG_SRC=${FFMPEG_SRC:-$SRC_ROOT/FFmpeg}
X264_SRC=${X264_SRC:-$SRC_ROOT/x264}
MP3LAME_SRC=${MP3LAME_SRC:-$SRC_ROOT/mp3lame}
WEBP_SRC=${WEBP_SRC:-$SRC_ROOT/libwebp}
LIBASS_SRC=${LIBASS_SRC:-$SRC_ROOT/libass}
TAG=n9.0.2
BUILD=$ZIGDOS/build/ffmpeg
[ -f "$FFMPEG_SRC/libavcodec/avcodec.h" ] || die "no FFmpeg in $FFMPEG_SRC (FFMPEG_SRC=...)"

# The tag exported (or the release tree copied) into
# build/ffmpeg/src, with ffmpeg-zdos.patch: x86-64 assembly using the
# red zone, where ZDOS's interrupts write, gets stack space
SRC=$BUILD/src
stamp="$TAG $(cksum <"$PORT/ffmpeg-zdos.patch")"
if [ "$(cat "$SRC/.stamp" 2>/dev/null)" != "$stamp" ]; then
    rm -rf "$SRC"
    mkdir -p "$SRC"
    if [ -e "$FFMPEG_SRC/.git" ]; then
        git -C "$FFMPEG_SRC" archive "$TAG" | tar -x -C "$SRC"
    else
        cp -R "$FFMPEG_SRC"/. "$SRC"/
    fi
    patch -s -d "$SRC" -p1 <"$PORT/ffmpeg-zdos.patch" || die "ffmpeg-zdos.patch doesn't apply"
    echo "$stamp" >"$SRC/.stamp"
fi
red=$(cd "$SRC" && grep -rlE '\[(rsp|rstk) *- *[0-9]' --include='*.asm' libav* libsw* || true)
[ -z "$red" ] || die "assembly using the red zone, to patch: $red"
# The version, from RELEASE:
IFS=. read -r v1 v2 v3 _ <"$SRC/RELEASE" || die "no version in $SRC/RELEASE"
v1=$((10#$v1)) v2=$((10#${v2:-0})) v3=$((10#${v3:-0}))
# ffmpeg_zdl.c's, and the tools' (cmdutils.c, patched):
VERSION_FLAGS="-DZDOS_FFMPEG_MAJOR=$v1 -DZDOS_FFMPEG_MINOR=$v2 -DZDOS_FFMPEG_PATCH=$v3"
printf '#define ZDOS_FFMPEG_MAJOR %d\n#define ZDOS_FFMPEG_MINOR %d\n#define ZDOS_FFMPEG_PATCH %d\n' \
    "$v1" "$v2" "$v3" >"$BUILD/version-zdos.h"
cmp -s "$BUILD/version-zdos.h" "$SRC/fftools/version-zdos.h" || cp "$BUILD/version-zdos.h" "$SRC/fftools/version-zdos.h"

COMPONENTS=(
    --enable-decoder=h264,hevc,mpeg4,mpeg1video,mpeg2video,vp8,vp9,av1,msmpeg4v1,msmpeg4v2,msmpeg4v3,h263,mjpeg,prores,dnxhd,ffv1,huffyuv,qtrle,rawvideo,v210,v210x
    --enable-decoder=aac,mp2,mp3,flac,vorbis,opus,ac3,eac3,dca,alac,wavpack,wmav1,wmav2,adpcm_ms,adpcm_ima_wav,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_u8,pcm_s16be,pcm_alaw,pcm_mulaw,pcm_dvd
    --enable-decoder=gif,png,bmp,tiff,webp,ppm,pgm,pbm,pcx,sgi,targa
    --enable-decoder=subrip,srt,ass,ssa,webvtt,movtext,dvdsub,pgssub
    --enable-parser=h264,hevc,mpeg4video,vp9,av1,aac,mpegaudio,flac,vorbis,opus,ac3,dca,mpegvideo,vp8,mjpeg,dvdsub,gif,png,bmp,webp,pnm,h263,ffv1,prores,dnxhd
    --enable-demuxer=mov,matroska,avi,flv,asf,mpegts,mpegps,mp3,ogg,flac,wav,aiff,caf,aac,ac3,h264,hevc,ivf,gif,dv,mxf,nut,rawvideo,yuv4mpegpipe,pcm_s16le
    --enable-demuxer=image2,image2pipe,concat,webvtt,srt,ass,ffmetadata
    --enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,extract_extradata,dump_extradata,setts,vp9_superframe,vp9_superframe_split,av1_metadata,trace_headers,mjpeg2jpeg,mpeg4_unpack_bframes
    --enable-encoder=mpeg4,mpeg1video,mpeg2video,mjpeg,prores,dnxhd,ffv1,huffyuv,qtrle,rawvideo,wrapped_avframe,libx264 #,libx265,libvpx_vp8,libvpx_vp9
    --enable-encoder=aac,mp2,ac3,eac3,flac,vorbis,opus,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_u8,pcm_s16be,pcm_alaw,pcm_mulaw,libmp3lame #,libopus,libvorbis
    --enable-encoder=gif,png,bmp,tiff,libwebp,libwebp_anim
    --enable-encoder=subrip,srt,movtext,ass,ssa,webvtt
    --enable-muxer=wav,aiff,caf,null,rawvideo,pcm_s16le,framemd5,mp4,mov,matroska,webm,avi,flv,asf,mxf,nut,dv,mpegts,adts,mp3,flac,ogg,ac3,gif,h264
    --enable-muxer=srt,webvtt,ass,segment,ffmetadata,image2,image2pipe,webp,yuv4mpegpipe
    --enable-filter=crop,scale,scale2ref,pad,format,colorspace,hflip,vflip,transpose,rotate,setsar,setdar,settb,setpts,trim,fps,framerate,select,split,concat,overlay,blend,fade,xfade,drawbox,drawgrid,lut,lutrgb,lutyuv,colorbalance,hue,curves,unsharp,yadif,bwdif,thumbnail,tile,palettegen,paletteuse,tpad,loop,reverse,null,color,xstack
    --enable-filter=aformat,anull,aresample,atrim,asetpts,asettb,asplit,amix,amerge,pan,atempo,volume,loudnorm,afade,acrossfade,adelay,apad,silenceremove,highpass,lowpass,equalizer,alimiter,areverse
    --enable-filter=subtitles,ass # text subtitles drawn (libass)
    --enable-protocol=file,pipe
    # --enable-libopus --enable-libvorbis
)

LIBS="libavfilter/libavfilter.a libavformat/libavformat.a libavcodec/libavcodec.a libswresample/libswresample.a libswscale/libswscale.a libavutil/libavutil.a"
STUBNAMES="avcodec avformat avutil avfilter swscale swresample"
FUNCS=$BUILD/ffmpeg9.funcs
# zdos-cc puts sdk-ports/include before the sources' own -I: FFmpeg is
# built on a view of it without the FFmpeg headers installed there:
PORTS=$ZIGDOS/build/sdk-ports
VIEW=$BUILD/sdk-ports-view
[ -f "$MP3LAME_SRC/include/lame.h" ] ||
    die "no LAME sources in $MP3LAME_SRC (MP3LAME_SRC=...)"
[ -f "$WEBP_SRC/src/webp/encode.h" ] && [ -f "$WEBP_SRC/src/webp/mux.h" ] ||
    die "no libwebp sources in $WEBP_SRC (WEBP_SRC=...)"
mkdir -p "$VIEW/include" "$PORTS/lib"
ln -sfn "$PORTS/lib" "$VIEW/lib"
ln -sfn "$PORTS/bin" "$VIEW/bin"
ln -sfn "$PORTS/include/SDL2" "$VIEW/include/SDL2"
ln -sfn "$PORTS/include/zlib.h" "$VIEW/include/zlib.h" # PNG, APNG, compressed MOV ...
ln -sfn "$PORTS/include/zconf.h" "$VIEW/include/zconf.h"
ln -sfn "$PORTS/include/webp" "$VIEW/include/webp"
ln -sfn "$PORTS/include/ass" "$VIEW/include/ass"
mkdir -p "$VIEW/include/lame"
ln -sfn "$MP3LAME_SRC/include/lame.h" "$VIEW/include/lame/lame.h"
export ZDOS_SDK_PORTS=$VIEW
sed -n 's/^X(\(.*\))$/\1/p' "$PORT/exports.def" >"$FUNCS"

for arch in $(arches "$@"); do
    select_arch "$arch"
    # What it links, built first if missing:
    need_port media/mp3lame libmp3lame.a MP3LAME.ZDL
    need_port media/x264 libx264.a X264.ZDL
    need_port graphics/webp libwebpmux.a WEBP.ZDL
    need_port libs/libass libass.a LIBASS.ZDL
    need_port graphics/SDL libSDL2.a SDL2.ZDL # for FFPLAY
    need_port libs/zlib libz.a ZLIB.ZDL
    case $arch in
        # x86: the assembly addresses tables absolutely or by GOT: C there:
        x86) ffarch="--arch=x86_32 --cpu=i686 --disable-asm" ;;
        x86_64) ffarch="--arch=x86_64 --enable-pic" ;;
        arm64) ffarch="--arch=aarch64 --enable-pic" ;;
    esac
    X264_STUBS=$PORTS/lib/$arch/libx264.a
    X264_PC_SOURCE=$ZIGDOS/build/x264/$arch/x264.pc
    LAME_STUBS=$PORTS/lib/$arch/libmp3lame.a
    WEBP_STUBS=$PORTS/lib/$arch/libwebp.a
    WEBP_MUX_STUBS=$PORTS/lib/$arch/libwebpmux.a
    [ -f "$MP3LAME_SRC/configure.ac" ] && [ -f "$MP3LAME_SRC/include/lame.h" ] ||
        die "no LAME sources in $MP3LAME_SRC; build ports/media/mp3lame first"
    [ -f "$LAME_STUBS" ] || die "no LAME import stubs for $arch at $LAME_STUBS; build ports/media/mp3lame first"
    cmp -s "$MP3LAME_SRC/include/lame.h" "$PORTS/include/lame.h" ||
        die "LAME source/header mismatch; rebuild ports/media/mp3lame"
    LAME_VERSION=$(sed -n 's/^AC_INIT(\[lame\],\[\([^]]*\)\].*/\1/p' "$MP3LAME_SRC/configure.ac")
    [ -n "$LAME_VERSION" ] || die "could not read LAME version from $MP3LAME_SRC/configure.ac"
    for edition in $EDITIONS; do
        [ -f "$ZIGDOS/build/$edition/LIBS_3RD/MP3LAME.ZDL" ] ||
            die "no MP3LAME.ZDL for $arch in build/$edition/LIBS_3RD; build ports/media/mp3lame first"
    done
    [ -f "$WEBP_STUBS" ] && [ -f "$WEBP_MUX_STUBS" ] ||
        die "no libwebp import stubs for $arch at $WEBP_STUBS; build ports/graphics/webp first"
    cmp -s "$WEBP_SRC/src/webp/encode.h" "$PORTS/include/webp/encode.h" &&
        cmp -s "$WEBP_SRC/src/webp/mux.h" "$PORTS/include/webp/mux.h" ||
        die "libwebp source/header mismatch; rebuild ports/graphics/webp"
    WEBP_VERSION=$(sed -n 's/^AC_INIT(\[libwebp\], *\[\([^]]*\)\].*/\1/p' "$WEBP_SRC/configure.ac")
    [ -n "$WEBP_VERSION" ] || die "could not read libwebp version from $WEBP_SRC/configure.ac"
    for edition in $EDITIONS; do
        [ -f "$ZIGDOS/build/$edition/LIBS_3RD/WEBP.ZDL" ] ||
            die "no WEBP.ZDL for $arch in build/$edition/LIBS_3RD; build ports/graphics/webp first"
    done
    [ -f "$X264_SRC/x264.h" ] || die "no x264 header in $X264_SRC; build ports/media/x264 first"
    [ -f "$X264_STUBS" ] || die "no x264 import stubs for $arch at $X264_STUBS; build ports/media/x264 first"
    X264_BUILD=$(sed -n 's/^#define X264_BUILD \([0-9][0-9]*\)$/\1/p' "$X264_SRC/x264.h")
    SDK_X264_BUILD=$(sed -n 's/^#define X264_BUILD \([0-9][0-9]*\)$/\1/p' "$PORTS/include/x264.h")
    [ -n "$X264_BUILD" ] && [ "$X264_BUILD" = "$SDK_X264_BUILD" ] ||
        die "x264 source/header build mismatch (source: $X264_BUILD, SDK: $SDK_X264_BUILD); rebuild ports/media/x264"
    for edition in $EDITIONS; do
        [ -f "$ZIGDOS/build/$edition/LIBS_3RD/X264.ZDL" ] ||
            die "no X264.ZDL for $arch in build/$edition/LIBS_3RD; build ports/media/x264 first"
    done
    X264_VERSION=$(sed -n 's/^Version: *//p' "$X264_PC_SOURCE")
    [ -n "$X264_VERSION" ] || die "no x264 pkg-config metadata at $X264_PC_SOURCE"
    LIBASS_STUBS=$PORTS/lib/$arch/libass.a
    LIBASS_VERSION=$(cat "$LIBASS_SRC/RELEASEVERSION" 2>/dev/null)
    [ -n "$LIBASS_VERSION" ] || die "no libass version in $LIBASS_SRC/RELEASEVERSION"

    obj=$BUILD/$arch
    mkdir -p "$obj"
    PKGDIR=$obj/pkgconfig
    mkdir -p "$PKGDIR"
    cat >"$PKGDIR/x264.pc" <<EOF
prefix=$PORTS
libdir=\${prefix}/lib/$arch
includedir=\${prefix}/include

Name: x264
Description: H.264 (MPEG-4 AVC) encoder library for ZDOS
Version: $X264_VERSION
Libs: -L\${libdir} -lx264 -lpthread -lm
Cflags: -I\${includedir}
EOF
    cat >"$PKGDIR/libwebp.pc" <<EOF
prefix=$PORTS
libdir=\${prefix}/lib/$arch
includedir=\${prefix}/include

Name: libwebp
Description: WebP encoder library for ZDOS
Version: $WEBP_VERSION
Libs: -L\${libdir} -lwebp
Cflags: -I\${includedir}
EOF
    cat >"$PKGDIR/libwebpmux.pc" <<EOF
prefix=$PORTS
libdir=\${prefix}/lib/$arch
includedir=\${prefix}/include

Name: libwebpmux
Description: WebP mux and animation library for ZDOS
Version: $WEBP_VERSION
Libs: -L\${libdir} -lwebpmux -lwebp
Cflags: -I\${includedir}
EOF
    # Its headers are in the view (ZDOS_SDK_PORTS); FREETYPE.ZDL,
    # HARFBUZZ.ZDL and SHNBIDI.ZDL are LIBASS.ZDL's own imports:
    cat >"$PKGDIR/libass.pc" <<EOF
prefix=$PORTS
libdir=\${prefix}/lib/$arch

Name: libass
Description: ASS/SSA subtitle renderer for ZDOS
Version: $LIBASS_VERSION
Libs: -L\${libdir} -lass
Cflags:
EOF
    cd "$obj"
    flags="$ffarch x264-$X264_VERSION lame-$LAME_VERSION webp-$WEBP_VERSION libass-$LIBASS_VERSION --enable-gpl --enable-libx264 --enable-libmp3lame --enable-libwebp --enable-libass --enable-zlib ${COMPONENTS[*]}"
    if [ ! -f ffbuild/config.mak ] || [ "$(cat .flags 2>/dev/null)" != "$flags" ]; then
        echo "=== configure for $arch ==="
        # sdl2-config for ffplay:
        PATH=$VIEW/bin:$PATH PKG_CONFIG_PATH=$PKGDIR PKG_CONFIG_LIBDIR=$PKGDIR \
            "$SRC/configure" --prefix=/usr --enable-cross-compile \
            $ffarch --target-os=none --cc="$CC" --cxx="$SDK/bin/zdos-c++ --arch=$arch" \
            --ar="$SDK/bin/zdos-ar" --ranlib="$SDK/bin/zdos-ranlib" --nm=nm --strip=true --pkg-config=pkg-config \
            --disable-doc --disable-debug --disable-network --disable-autodetect \
            --disable-everything --disable-avdevice --enable-static --disable-shared --enable-pthreads \
            --enable-sdl2 --enable-gpl --enable-libx264 --enable-libmp3lame --enable-libwebp --enable-libass --enable-zlib "${COMPONENTS[@]}" >configure.log ||
            die "configure failed: $obj/ffbuild/config.log"
        echo "$flags" >.flags
    fi
    # D:\FILM.MKV is a file, not protocol "d" (configure sets it only
    # for Windows, OS/2 and DOS):
    sed -i 's/^#define HAVE_DOS_PATHS 0$/#define HAVE_DOS_PATHS 1/' config.h
    grep -q '^#define HAVE_DOS_PATHS 1$' config.h || die "config.h: HAVE_DOS_PATHS not found"
    echo "=== FFmpeg for $arch ==="
    # The libraries and the tools' objects, not FFmpeg's own ffmpeg_g
    # ...: linked on the stubs, they lack x264_levels (data):
    tool_objs=
    for t in ffprobe ffmpeg ffplay; do
        objs=$(make -n -W fftools/cmdutils.o "${t}_g" V=1 | sed -n "s/.* -o ${t}_g \(.*\) -lavfilter.*/\1/p")
        [ -n "$objs" ] || die "no link line for ${t}_g"
        eval "objs_$t=\$objs"
        tool_objs="$tool_objs $objs"
    done
    make -s -j"$(cpus)" $LIBS $tool_objs >make.log 2>&1 || die "make failed: $obj/make.log"

    # The table only grows at its end: public functions not in exports.def:
    nm -g --defined-only $LIBS | awk 'NF == 3 && $2 == "T" { print $3 }' |
        grep -E '^(av|swr_|swresample_|sws_|swscale_)' | grep -v '^avpriv_' | sort -u >funcs.txt
    missing=$(grep -vxF -f "$FUNCS" funcs.txt || true)
    [ -z "$missing" ] || die "functions exports.def lacks (append them): $missing"

    echo "=== FFMPEG9.ZDL for $arch ==="
    mkdir -p zdl
    echo '/* Extracted from x264/common/tables.c; GPL-2.0-or-later. */' >x264_levels.inc
    awk '/^const x264_level_t x264_levels\[\]/ { copying = 1 }
         copying { print }
         copying && /^};/ { exit }' "$X264_SRC/common/tables.c" >>x264_levels.inc
    grep -q '^const x264_level_t x264_levels\[\]' x264_levels.inc ||
        die "could not extract x264_levels from $X264_SRC/common/tables.c"
    $CC -O2 $VERSION_FLAGS -I. -I"$PORTS/include" -I"$ZIGDOS/build/x264/$arch" -I"$X264_SRC" \
        -I"$PORT" -c "$PORT/ffmpeg_zdl.c" -o zdl/ffmpeg_zdl.o
    # --gc-sections: of the C library and runtime only what is used:
    $CC zdl/ffmpeg_zdl.o -Wl,--start-group $LIBS "$X264_STUBS" "$LAME_STUBS" \
        "$WEBP_STUBS" "$WEBP_MUX_STUBS" "$LIBASS_STUBS" "$PORTS/lib/$arch/libz.a" \
        -Wl,--end-group -Wl,--gc-sections -o FFMPEG9.ZDL
    # ZDOS relocates only relative (the assembly must not add others):
    other=$(readelf -r --wide FFMPEG9.elf | awk '/^[0-9a-f]+ / && $3 !~ /_RELATIVE$/ { print $3 }' | sort | uniq -c)
    [ -z "$other" ] || die "FFMPEG9.ZDL has relocations other than relative: $other"
    $STUBS FFMPEG9 "$FUNCS" zdl/libffmpeg9.a

    echo "=== FFPROBE, FFMPEG, FFPLAY for $arch ==="
    # The tools' objects as FFmpeg's Makefile links them, on the stubs:
    for t in ffprobe ffmpeg ffplay; do
        eval "objs=\$objs_$t"
        extra=
        [ $t = ffplay ] && extra=-lSDL2
        $CC -o zdl/$t $objs zdl/libffmpeg9.a "$PORTS/lib/$arch/libz.a" $extra -Wl,--gc-sections
        $CC --app zdl/$t "$(echo $t | tr a-z A-Z).APP"
    done

    install_app FFMPEG9.ZDL LIBS_3RD
    for t in FFPROBE FFMPEG FFPLAY; do install_app $t.APP APPS_3RD; done
    for n in $STUBNAMES; do install_file zdl/libffmpeg9.a "sdk-ports/lib/$arch" lib$n.a; done
done

# The headers of the last CPU built: only avconfig.h differs
# (AV_HAVE_FAST_UNALIGNED 0 for i686: slower there, right everywhere)
make -s -C "$obj" install-headers DESTDIR="$BUILD/headers" >/dev/null
mkdir -p "$ZIGDOS/build/sdk-ports/include"
cp -R "$BUILD"/headers/usr/include/* "$ZIGDOS/build/sdk-ports/include/"
echo "Headers in build/sdk-ports/include/libav*, libsw*"
