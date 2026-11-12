#!/C:/APPS/ASH.APP
# archives.sh: ZIP and TAR (also -gz) round trips: a folder packed,
# unpacked elsewhere, its files compared; exit code 1 if any failed.
# Works in archives_tmp in the current folder and removes it.

PASSED=0
FAILED=0

# check NAME EXPECTED ACTUAL
check() {
    if [ "$2" = "$3" ]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        echo "  [Fail] $1"
        echo "    expected: [$2]"
        echo "    got:      [$3]"
    fi
}

# same NAME FOLDER: FOLDER's files are src's (FOLDER or FOLDER/src)
same() {
    d=$2
    [ -d "$d/src" ] && d=$d/src
    check "$1: small file" "$(cat src/small.txt)" "$(cat "$d/small.txt" 2>&1)"
    check "$1: big file" "$(cat src/big.txt)" "$(cat "$d/big.txt" 2>&1)"
    check "$1: empty file" "" "$(cat "$d/empty.txt" 2>&1)"
    check "$1: file in a subfolder" "$(cat src/sub/deep/inner.txt)" "$(cat "$d/sub/deep/inner.txt" 2>&1)"
}

T=archives_tmp
rm -r "$T" 2> /dev/null
mkdir "$T" || exit 1
cd "$T" || exit 1

# The folder: a big file (more than deflate's 32 KB window, in many
# blocks), a small one, an empty one, one two folders down
mkdir -p src/sub/deep
echo "hello archives" > src/small.txt
: > src/empty.txt
echo "deep inside" > src/sub/deep/inner.txt
i=0
while [ $i -lt 6000 ]; do
    echo "line $i of the big file, $((i * 7919 % 1000)) varied" >> src/big.txt
    i=$((i + 1))
done

ZIP C src > zip.log 2>&1
check "ZIP C: exit code" "0" "$?"
mkdir zipout
cd zipout
ZIP X ../src.zip > ../unzip.log 2>&1
check "ZIP X: exit code" "0" "$?"
cd ..
same "ZIP" zipout

TAR C src > tar.log 2>&1
check "TAR C: exit code" "0" "$?"
mkdir tarout
cd tarout
TAR X ../src.tar > ../untar.log 2>&1
check "TAR X: exit code" "0" "$?"
cd ..
same "TAR" tarout

TAR C -gz src > tgz.log 2>&1
check "TAR C -gz: exit code" "0" "$?"
mkdir tgzout
cd tgzout
TAR X ../src.tgz > ../untgz.log 2>&1
check "TAR X (.tgz): exit code" "0" "$?"
cd ..
same "TAR -gz" tgzout

cd ..
rm -r "$T"
if [ -e "$T" ]; then
    echo "  [Fail] cleanup: $T is still there"
    FAILED=$((FAILED + 1))
fi
echo
if [ "$FAILED" -eq 0 ]; then
    echo "All $PASSED tests passed"
    exit 0
fi
echo "$PASSED passed, $FAILED failed"
exit 1
