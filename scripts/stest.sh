#!/C:/APPS/ASH.APP
# File system stress test

mkdir -p bulk
cd bulk || exit 1

i=1
while [ $i -le 1000 ]; do
    echo 8 > "file$i.txt"
    if [ $((i % 10)) -eq 0 ]; then
        echo "$i files written"
    fi
    i=$((i + 1))
done

cd ..