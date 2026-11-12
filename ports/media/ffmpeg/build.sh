#!/usr/bin/env bash
# FFmpeg 9 (LGPL): as ffmpeg264/build.sh without the GPL libraries.
#   build.sh [x86|x86_64|arm64]...   (none: all three)

# DISABLED:
exit
echo "=== FFmpeg LGPL ==="

source "$(dirname "$0")/../../common.sh"
PORT=$ZIGDOS/ports/media/ffmpeg
FFMPEG_SRC=${FFMPEG_SRC:-$SRC_ROOT/FFmpeg}
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

COMPONENTS=(
    --enable-decoder=h264,hevc,mpeg4,mpeg1video,mpeg2video,vp8,vp9,av1,msmpeg4v1,msmpeg4v2,msmpeg4v3,h263,mjpeg,prores,dnxhd,ffv1,huffyuv,qtrle,rawvideo,v210,v210x
    --enable-decoder=aac,mp2,mp3,flac,vorbis,opus,ac3,eac3,dca,alac,wavpack,wmav1,wmav2,adpcm_ms,adpcm_ima_wav,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_u8,pcm_s16be,pcm_alaw,pcm_mulaw,pcm_dvd
    --enable-decoder=gif,png,bmp,tiff,webp,ppm,pgm,pbm,pcx,sgi,targa
    --enable-decoder=subrip,srt,ass,ssa,webvtt,movtext,dvdsub,pgssub
    --enable-parser=h264,hevc,mpeg4video,vp9,av1,aac,mpegaudio,flac,vorbis,opus,ac3,dca,mpegvideo,vp8,mjpeg,dvdsub,gif,png,bmp,webp,pnm,h263,ffv1,prores,dnxhd
    --enable-demuxer=mov,matroska,avi,flv,asf,mpegts,mpegps,mp3,ogg,flac,wav,aiff,caf,aac,ac3,h264,hevc,ivf,gif,dv,mxf,nut,rawvideo,yuv4mpegpipe,pcm_s16le
    --enable-demuxer=image2,image2pipe,concat,webvtt,srt,ass,ffmetadata
    --enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,extract_extradata,dump_extradata,setts,vp9_superframe,vp9_superframe_split,av1_metadata,trace_headers,mjpeg2jpeg,mpeg4_unpack_bframes
    --enable-encoder=mpeg4,mpeg1video,mpeg2video,mjpeg,prores,dnxhd,ffv1,huffyuv,qtrle,rawvideo,wrapped_avframe #,libx264,libx265,libvpx_vp8,libvpx_vp9
    --enable-encoder=aac,mp2,ac3,eac3,flac,vorbis,opus,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_u8,pcm_s16be,pcm_alaw,pcm_mulaw #,libmp3lame,libopus,libvorbis
    --enable-encoder=gif,png,bmp,tiff #,libwebp,libwebp_anim
    --enable-encoder=subrip,srt,movtext,ass,ssa,webvtt
    --enable-muxer=wav,aiff,caf,null,rawvideo,pcm_s16le,framemd5,mp4,mov,matroska,webm,avi,flv,asf,mxf,nut,dv,mpegts,adts,mp3,flac,ogg,ac3,gif,h264
    --enable-muxer=srt,webvtt,ass,segment,ffmetadata,image2,image2pipe,yuv4mpegpipe
    --enable-filter=crop,scale,scale2ref,pad,format,colorspace,hflip,vflip,transpose,rotate,setsar,setdar,settb,setpts,trim,fps,framerate,select,split,concat,overlay,blend,fade,xfade,drawbox,drawgrid,lut,lutrgb,lutyuv,colorbalance,hue,curves,unsharp,yadif,bwdif,thumbnail,tile,palettegen,paletteuse,tpad,loop,reverse,null,color,xstack
    --enable-filter=aformat,anull,aresample,atrim,asetpts,asettb,asplit,amix,amerge,pan,atempo,volume,loudnorm,afade,acrossfade,adelay,apad,silenceremove,highpass,lowpass,equalizer,alimiter,areverse
    #--enable-filter=drawtext,subtitles,ass
    --enable-protocol=file,pipe
    # --enable-gpl --enable-libx264 --enable-libx265 --enable-libvpx
    # --enable-libmp3lame
    # --enable-libopus --enable-libvorbis --enable-libwebp
    # --enable-libfreetype --enable-libass
)

LIBS="libavfilter/libavfilter.a libavformat/libavformat.a libavcodec/libavcodec.a libswresample/libswresample.a libswscale/libswscale.a libavutil/libavutil.a"
STUBNAMES="avcodec avformat avutil avfilter swscale swresample"
FUNCS=$BUILD/ffmpeg9.funcs
# zdos-cc puts sdk-ports/include before the sources' own -I: FFmpeg is
# built on a view of it without the FFmpeg headers installed there:
PORTS=$ZIGDOS/build/sdk-ports
VIEW=$BUILD/sdk-ports-view
mkdir -p "$VIEW/include" "$PORTS/lib"
ln -sfn "$PORTS/lib" "$VIEW/lib"
ln -sfn "$PORTS/bin" "$VIEW/bin"
ln -sfn "$PORTS/include/SDL2" "$VIEW/include/SDL2"
ln -sfn "$PORTS/include/zlib.h" "$VIEW/include/zlib.h" # PNG, APNG, compressed MOV ...
ln -sfn "$PORTS/include/zconf.h" "$VIEW/include/zconf.h"
export ZDOS_SDK_PORTS=$VIEW
sed -n 's/^X(\(.*\))$/\1/p' "$PORT/exports.def" >"$FUNCS"

for arch in $(arches "$@"); do
    select_arch "$arch"
    need_port graphics/SDL libSDL2.a SDL2.ZDL # for FFPLAY, built first if missing
    need_port libs/zlib libz.a ZLIB.ZDL
    case $arch in
        # x86: the assembly addresses tables absolutely or by GOT: C there:
        x86) ffarch="--arch=x86_32 --cpu=i686 --disable-asm" ;;
        x86_64) ffarch="--arch=x86_64 --enable-pic" ;;
        arm64) ffarch="--arch=aarch64 --enable-pic" ;;
    esac
    obj=$BUILD/$arch
    mkdir -p "$obj"
    cd "$obj"
    flags="$ffarch --enable-zlib ${COMPONENTS[*]}"
    if [ ! -f ffbuild/config.mak ] || [ "$(cat .flags 2>/dev/null)" != "$flags" ]; then
        echo "=== configure for $arch ==="
        # sdl2-config for ffplay:
        PATH=$VIEW/bin:$PATH "$SRC/configure" --prefix=/usr --enable-cross-compile \
            $ffarch --target-os=none --cc="$CC" --cxx="$SDK/bin/zdos-c++ --arch=$arch" \
            --ar="$SDK/bin/zdos-ar" --ranlib="$SDK/bin/zdos-ranlib" --nm=nm --strip=true --pkg-config=false \
            --disable-doc --disable-debug --disable-network --disable-autodetect \
            --disable-everything --disable-avdevice --enable-static --disable-shared --enable-pthreads \
            --enable-sdl2 --enable-zlib "${COMPONENTS[@]}" >configure.log || die "configure failed: $obj/ffbuild/config.log"
        echo "$flags" >.flags
    fi
    # D:\FILM.MKV is a file, not protocol "d" (configure sets it only
    # for Windows, OS/2 and DOS):
    sed -i 's/^#define HAVE_DOS_PATHS 0$/#define HAVE_DOS_PATHS 1/' config.h
    grep -q '^#define HAVE_DOS_PATHS 1$' config.h || die "config.h: HAVE_DOS_PATHS not found"
    echo "=== FFmpeg for $arch ==="
    make -s -j"$(cpus)" >make.log 2>&1 || die "make failed: $obj/make.log"

    # The table only grows at its end: public functions not in exports.def:
    nm -g --defined-only $LIBS | awk 'NF == 3 && $2 == "T" { print $3 }' |
        grep -E '^(av|swr_|swresample_|sws_|swscale_)' | grep -v '^avpriv_' | sort -u >funcs.txt
    missing=$(grep -vxF -f "$FUNCS" funcs.txt || true)
    [ -z "$missing" ] || die "functions exports.def lacks (append them): $missing"

    echo "=== FFMPEG9.ZDL for $arch ==="
    mkdir -p zdl
    $CC -O2 -I"$PORT" -c "$PORT/ffmpeg_zdl.c" -o zdl/ffmpeg_zdl.o
    # --gc-sections: of the C library and runtime only what is used:
    $CC zdl/ffmpeg_zdl.o -Wl,--start-group $LIBS "$PORTS/lib/$arch/libz.a" -Wl,--end-group -Wl,--gc-sections -o FFMPEG9.ZDL
    # ZDOS relocates only relative (the assembly must not add others):
    other=$(readelf -r --wide FFMPEG9.elf | awk '/^[0-9a-f]+ / && $3 !~ /_RELATIVE$/ { print $3 }' | sort | uniq -c)
    [ -z "$other" ] || die "FFMPEG9.ZDL has relocations other than relative: $other"
    $STUBS FFMPEG9 "$FUNCS" zdl/libffmpeg9.a

    echo "=== FFPROBE, FFMPEG, FFPLAY for $arch ==="
    # The tools' objects as FFmpeg's Makefile links them, on the stubs:
    for t in ffprobe ffmpeg ffplay; do
        objs=$(make -n -W fftools/cmdutils.o "${t}_g" V=1 | sed -n "s/.* -o ${t}_g \(.*\) -lavfilter.*/\1/p")
        [ -n "$objs" ] || die "no link line for ${t}_g"
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
